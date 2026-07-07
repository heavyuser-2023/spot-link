import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as classic;

/// Streaming SHA-256 of a file on disk — never holds more than one 64KB
/// read buffer, so hashing a 500MB video costs no meaningful memory.
Future<Uint8List> sha256OfFile(String path) async {
  final digest = await classic.sha256.bind(File(path).openRead()).first;
  return Uint8List.fromList(digest.bytes);
}

/// File-transfer application payloads carried inside (encrypted) frames.
///
/// A transfer is identified by a random 16-byte transferId. The sender emits
/// one FILE_META followed by N FILE_CHUNK payloads. The receiver reassembles
/// by seq, verifies the SHA-256, and ACKs missing chunks so the sender can
/// retransmit only the gaps. See docs/ARCHITECTURE.md §8.

/// Metadata describing a file transfer.
class FileMeta {
  final Uint8List transferId; // 16 bytes
  final int fileSize;
  final int chunkSize;
  final int totalChunks;
  final Uint8List sha256; // 32 bytes
  final String name;
  final String mime;

  FileMeta({
    required this.transferId,
    required this.fileSize,
    required this.chunkSize,
    required this.totalChunks,
    required this.sha256,
    required this.name,
    required this.mime,
  });

  Uint8List encode() {
    final nameBytes = utf8.encode(name);
    final mimeBytes = utf8.encode(mime);
    final builder = BytesBuilder();
    builder.add(transferId);
    final head = ByteData(12);
    head.setUint32(0, fileSize, Endian.big);
    head.setUint32(4, chunkSize, Endian.big);
    head.setUint32(8, totalChunks, Endian.big);
    builder.add(head.buffer.asUint8List());
    builder.add(sha256);
    final lens = ByteData(4);
    lens.setUint16(0, nameBytes.length, Endian.big);
    lens.setUint16(2, mimeBytes.length, Endian.big);
    builder.add(lens.buffer.asUint8List());
    builder.add(nameBytes);
    builder.add(mimeBytes);
    return builder.toBytes();
  }

  static FileMeta decode(Uint8List data) {
    var off = 0;
    final transferId = Uint8List.fromList(data.sublist(0, 16));
    off = 16;
    final bd = ByteData.view(data.buffer, data.offsetInBytes);
    final fileSize = bd.getUint32(off, Endian.big);
    final chunkSize = bd.getUint32(off + 4, Endian.big);
    final totalChunks = bd.getUint32(off + 8, Endian.big);
    off += 12;
    final sha = Uint8List.fromList(data.sublist(off, off + 32));
    off += 32;
    final nameLen = bd.getUint16(off, Endian.big);
    final mimeLen = bd.getUint16(off + 2, Endian.big);
    off += 4;
    final name = utf8.decode(data.sublist(off, off + nameLen));
    off += nameLen;
    final mime = utf8.decode(data.sublist(off, off + mimeLen));
    return FileMeta(
      transferId: transferId,
      fileSize: fileSize,
      chunkSize: chunkSize,
      totalChunks: totalChunks,
      sha256: sha,
      name: name,
      mime: mime,
    );
  }

  String get transferIdHex => _hex(transferId);
}

/// A single file chunk payload: transferId(16) | seq(u32) | data.
class FileChunk {
  final Uint8List transferId;
  final int seq;
  final Uint8List data;

  FileChunk(this.transferId, this.seq, this.data);

  Uint8List encode() {
    final out = Uint8List(20 + data.length);
    out.setRange(0, 16, transferId);
    ByteData.view(out.buffer).setUint32(16, seq, Endian.big);
    out.setRange(20, out.length, data);
    return out;
  }

  static FileChunk decode(Uint8List data) {
    final transferId = Uint8List.fromList(data.sublist(0, 16));
    final seq = ByteData.view(data.buffer, data.offsetInBytes).getUint32(16, Endian.big);
    final body = Uint8List.fromList(data.sublist(20));
    return FileChunk(transferId, seq, body);
  }
}

/// An acknowledgement of a file transfer's progress.
/// Layout: transferId(16) | complete(u8) | missingCount(u16) | seqs(u32 each).
class FileAck {
  final Uint8List transferId;
  final bool complete;
  final List<int> missing;

  FileAck(this.transferId, this.complete, this.missing);

  Uint8List encode() {
    final out = Uint8List(16 + 1 + 2 + missing.length * 4);
    out.setRange(0, 16, transferId);
    final bd = ByteData.view(out.buffer);
    bd.setUint8(16, complete ? 1 : 0);
    bd.setUint16(17, missing.length, Endian.big);
    var off = 19;
    for (final s in missing) {
      bd.setUint32(off, s, Endian.big);
      off += 4;
    }
    return out;
  }

  static FileAck decode(Uint8List data) {
    final transferId = Uint8List.fromList(data.sublist(0, 16));
    final bd = ByteData.view(data.buffer, data.offsetInBytes);
    final complete = bd.getUint8(16) == 1;
    final count = bd.getUint16(17, Endian.big);
    final missing = <int>[];
    var off = 19;
    for (var i = 0; i < count; i++) {
      missing.add(bd.getUint32(off, Endian.big));
      off += 4;
    }
    return FileAck(transferId, complete, missing);
  }

  String get transferIdHex => _hex(transferId);
}

/// Serves file chunks for (re)transmission based on ACKs.
///
/// Two backings: in-memory bytes (tests, tiny payloads) or a file on disk —
/// the disk backing keeps a multi-minute BLE transfer of a large file from
/// pinning the whole file in RAM (a prime jetsam target on iOS).
class FileSender {
  final Uint8List? _bytes;
  final RandomAccessFile? _raf;

  /// Path of the disk backing, if any — lets the app resend after a failure
  /// without re-copying.
  final String? path;
  final FileMeta meta;

  FileSender._(this._bytes, this._raf, this.path, this.meta);

  static final _rng = Random.secure();

  static Uint8List newTransferId() {
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  factory FileSender.forFile({
    required Uint8List bytes,
    required String name,
    required String mime,
    int chunkSize = 4096,
  }) {
    final total = max(1, (bytes.length + chunkSize - 1) ~/ chunkSize);
    final sha = Uint8List.fromList(classic.sha256.convert(bytes).bytes);
    final meta = FileMeta(
      transferId: newTransferId(),
      fileSize: bytes.length,
      chunkSize: chunkSize,
      totalChunks: total,
      sha256: sha,
      name: name,
      mime: mime,
    );
    return FileSender._(bytes, null, null, meta);
  }

  /// Disk-backed sender: streams the hash up front, then reads each chunk
  /// from the file on demand. RAM cost is one chunk (~4KB), not the file.
  static Future<FileSender> forPath({
    required String path,
    required String name,
    required String mime,
    int chunkSize = 4096,
  }) async {
    final file = File(path);
    final size = await file.length();
    final sha = await sha256OfFile(path);
    final total = max(1, (size + chunkSize - 1) ~/ chunkSize);
    final meta = FileMeta(
      transferId: newTransferId(),
      fileSize: size,
      chunkSize: chunkSize,
      totalChunks: total,
      sha256: sha,
      name: name,
      mime: mime,
    );
    return FileSender._(null, file.openSync(), path, meta);
  }

  FileChunk chunk(int seq) {
    final start = seq * meta.chunkSize;
    final end = min(start + meta.chunkSize, meta.fileSize);
    final Uint8List data;
    if (_bytes != null) {
      data = Uint8List.fromList(_bytes.sublist(start, end));
    } else {
      final raf = _raf!;
      raf.setPositionSync(start);
      data = raf.readSync(end - start);
    }
    return FileChunk(meta.transferId, seq, data);
  }

  Iterable<FileChunk> allChunks() sync* {
    for (var i = 0; i < meta.totalChunks; i++) {
      yield chunk(i);
    }
  }

  /// Given an ACK, the chunks that still need to be (re)sent.
  List<FileChunk> chunksToResend(FileAck ack) =>
      ack.missing.map(chunk).toList();

  /// The whole payload — used only by the fast lane, whose whole-file GCM
  /// needs it in one piece (transiently).
  Future<Uint8List> readAll() async =>
      _bytes ?? await File(path!).readAsBytes();

  /// Release the disk backing (transfer finished or cancelled).
  void close() {
    try {
      _raf?.closeSync();
    } catch (_) {}
  }
}

/// Accumulates chunks for one incoming transfer and verifies integrity.
///
/// Chunks are written straight to a partial file on disk at their seq
/// offset; memory holds only the set of received seqs. The old in-memory
/// map held the ENTIRE file and then assemble() built a second full copy —
/// a 2× fileSize RAM spike right when a big transfer completed, which is
/// exactly when iOS jetsam went hunting.
class FileReceiver {
  final FileMeta meta;

  /// Where the partial file is written. The caller owns naming/cleanup of
  /// the final destination; [finalize] returns this path on success.
  final String partPath;

  final Set<int> _have = {};
  RandomAccessFile? _raf;

  FileReceiver(this.meta, this.partPath) {
    final f = File(partPath);
    f.parent.createSync(recursive: true);
    _raf = f.openSync(mode: FileMode.write);
    // Preallocate so out-of-order chunk writes land inside the file.
    _raf!.truncateSync(meta.fileSize);
  }

  /// Returns true if this chunk was new (not a duplicate).
  bool offer(FileChunk chunk) {
    final raf = _raf;
    if (raf == null) return false; // finalized/discarded
    if (chunk.seq >= meta.totalChunks) return false;
    if (_have.contains(chunk.seq)) return false;
    raf.setPositionSync(chunk.seq * meta.chunkSize);
    raf.writeFromSync(chunk.data);
    _have.add(chunk.seq);
    return true;
  }

  int get receivedCount => _have.length;
  double get progress =>
      meta.totalChunks == 0 ? 1 : receivedCount / meta.totalChunks;
  bool get isComplete => _have.length == meta.totalChunks;

  List<int> missingSeqs() {
    final missing = <int>[];
    for (var i = 0; i < meta.totalChunks; i++) {
      if (!_have.contains(i)) missing.add(i);
    }
    return missing;
  }

  /// [maxMissing] bounds the ACK frame size for huge transfers: the sender
  /// fills the reported gaps first and later ACKs cover the rest.
  FileAck buildAck({int? maxMissing}) {
    if (isComplete) return FileAck(meta.transferId, true, const []);
    var missing = missingSeqs();
    if (maxMissing != null && missing.length > maxMissing) {
      missing = missing.sublist(0, maxMissing);
    }
    return FileAck(meta.transferId, false, missing);
  }

  /// Fast-lane path: accept the whole plaintext at once (arrived out-of-band,
  /// already decrypted). Verifies the manifest hash BEFORE touching receiver
  /// state — a mismatch must leave the chunk map empty so BLE recovery can
  /// still re-pull the file — then writes it to the part file and marks every
  /// chunk present so [buildAck] reports a genuine complete.
  void seedAssembled(Uint8List bytes) {
    if (bytes.length != meta.fileSize) {
      throw StateError('size mismatch: ${bytes.length} != ${meta.fileSize}');
    }
    final actual = classic.sha256.convert(bytes).bytes;
    if (!_bytesEqual(actual, meta.sha256)) {
      throw StateError('sha256 mismatch on fast-lane file');
    }
    final raf = _raf;
    if (raf == null) throw StateError('receiver already closed');
    raf.setPositionSync(0);
    raf.writeFromSync(bytes);
    for (var i = 0; i < meta.totalChunks; i++) {
      _have.add(i);
    }
  }

  /// Complete the transfer: close the part file, verify its hash by
  /// streaming, and return its path. Throws if incomplete or on mismatch
  /// (the corrupt part file is deleted).
  Future<String> finalize() async {
    if (!isComplete) {
      throw StateError(
          'transfer incomplete: $receivedCount/${meta.totalChunks}');
    }
    _raf?.flushSync();
    _raf?.closeSync();
    _raf = null;
    final actual = await sha256OfFile(partPath);
    if (!_bytesEqual(actual, meta.sha256)) {
      try {
        File(partPath).deleteSync();
      } catch (_) {}
      throw StateError('sha256 mismatch on assembled file');
    }
    return partPath;
  }

  /// Abort: close and delete the partial file.
  void discard() {
    try {
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
    try {
      File(partPath).deleteSync();
    } catch (_) {}
  }
}

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
