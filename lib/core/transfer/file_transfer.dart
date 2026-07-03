import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as classic;

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

/// Splits file bytes into chunks and drives (re)transmission based on ACKs.
class FileSender {
  final Uint8List bytes;
  final FileMeta meta;

  FileSender._(this.bytes, this.meta);

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
    return FileSender._(bytes, meta);
  }

  FileChunk chunk(int seq) {
    final start = seq * meta.chunkSize;
    final end = min(start + meta.chunkSize, bytes.length);
    return FileChunk(
        meta.transferId, seq, Uint8List.fromList(bytes.sublist(start, end)));
  }

  Iterable<FileChunk> allChunks() sync* {
    for (var i = 0; i < meta.totalChunks; i++) {
      yield chunk(i);
    }
  }

  /// Given an ACK, the chunks that still need to be (re)sent.
  List<FileChunk> chunksToResend(FileAck ack) =>
      ack.missing.map(chunk).toList();
}

/// Accumulates chunks for one incoming transfer and verifies integrity.
class FileReceiver {
  final FileMeta meta;
  final Map<int, Uint8List> _chunks = {};

  FileReceiver(this.meta);

  /// Returns true if this chunk was new (not a duplicate).
  bool offer(FileChunk chunk) {
    if (chunk.seq >= meta.totalChunks) return false;
    if (_chunks.containsKey(chunk.seq)) return false;
    _chunks[chunk.seq] = chunk.data;
    return true;
  }

  int get receivedCount => _chunks.length;
  double get progress =>
      meta.totalChunks == 0 ? 1 : receivedCount / meta.totalChunks;
  bool get isComplete => _chunks.length == meta.totalChunks;

  List<int> missingSeqs() {
    final missing = <int>[];
    for (var i = 0; i < meta.totalChunks; i++) {
      if (!_chunks.containsKey(i)) missing.add(i);
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

  /// Assemble the full file. Throws if incomplete or the hash mismatches.
  Uint8List assemble() {
    if (!isComplete) {
      throw StateError('transfer incomplete: $receivedCount/${meta.totalChunks}');
    }
    final builder = BytesBuilder();
    for (var i = 0; i < meta.totalChunks; i++) {
      builder.add(_chunks[i]!);
    }
    final out = builder.toBytes();
    final actual = classic.sha256.convert(out).bytes;
    if (!_bytesEqual(actual, meta.sha256)) {
      throw StateError('sha256 mismatch on assembled file');
    }
    return out;
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
