import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as classic;

/// 디스크에 있는 파일의 스트리밍 SHA-256 — 한 번에 64KB 읽기 버퍼 하나보다
/// 많이 들고 있지 않으므로, 500MB 동영상을 해시해도 메모리를 거의 쓰지 않는다.
Future<Uint8List> sha256OfFile(String path) async {
  final digest = await classic.sha256.bind(File(path).openRead()).first;
  return Uint8List.fromList(digest.bytes);
}

/// (암호화된) 프레임 안에 실려 전달되는 파일 전송 애플리케이션 페이로드.
///
/// 하나의 전송은 무작위 16바이트 transferId로 식별된다. 발신자는 FILE_META
/// 하나를 보낸 뒤 N개의 FILE_CHUNK 페이로드를 이어서 보낸다. 수신자는 seq
/// 순서로 재조립하고, SHA-256을 검증하며, 누락된 청크를 ACK로 알려 발신자가
/// 빠진 부분만 재전송하도록 한다. docs/ARCHITECTURE.md §8 참고.

/// 파일 전송을 설명하는 메타데이터.
class FileMeta {
  final Uint8List transferId; // 16바이트
  final int fileSize;
  final int chunkSize;
  final int totalChunks;
  final Uint8List sha256; // 32바이트
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

/// 단일 파일 청크 페이로드: transferId(16) | seq(u32) | data.
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

/// 파일 전송 진행 상황에 대한 확인 응답(ACK).
/// 레이아웃: transferId(16) | complete(u8) | missingCount(u16) | seqs(각 u32).
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

/// ACK를 기반으로 (재)전송할 파일 청크를 공급한다.
///
/// 두 가지 백킹을 지원한다: 인메모리 바이트(테스트, 아주 작은 페이로드)와
/// 디스크의 파일 — 디스크 백킹은 큰 파일을 여러 분에 걸쳐 BLE로 전송하는 동안
/// 파일 전체를 RAM에 붙들어 두지 않게 한다(iOS에서 jetsam의 주요 표적).
class FileSender {
  final Uint8List? _bytes;
  final RandomAccessFile? _raf;

  /// 디스크 백킹의 경로(있는 경우) — 실패 후 다시 복사하지 않고도 앱이 재전송할
  /// 수 있게 한다.
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

  /// 디스크 백킹 발신자: 먼저 해시를 스트리밍으로 계산한 뒤, 각 청크를 필요할 때
  /// 파일에서 읽는다. RAM 비용은 파일 전체가 아니라 청크 하나(~4KB)뿐이다.
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

  /// ACK가 주어지면, 아직 (재)전송해야 하는 청크들.
  List<FileChunk> chunksToResend(FileAck ack) =>
      ack.missing.map(chunk).toList();

  /// 페이로드 전체 — 패스트레인에서만 사용되며, 파일 전체 GCM이 이를 한 덩어리로
  /// (일시적으로) 필요로 한다.
  Future<Uint8List> readAll() async =>
      _bytes ?? await File(path!).readAsBytes();

  /// 디스크 백킹을 해제한다(전송 완료 또는 취소됨).
  void close() {
    try {
      _raf?.closeSync();
    } catch (_) {}
  }
}

/// 들어오는 하나의 전송에 대한 청크를 모으고 무결성을 검증한다.
///
/// 청크는 디스크의 부분 파일(partial file)에 자신의 seq 오프셋 위치로 바로
/// 기록되며, 메모리에는 수신한 seq 집합만 담긴다. 예전의 인메모리 맵은 파일
/// 전체를 들고 있다가 assemble()이 두 번째 전체 복사본을 만들었다 — 큰 전송이
/// 막 완료되는 바로 그 순간에 fileSize의 2배에 달하는 RAM 급증이 생겼고, 그때가
/// 바로 iOS jetsam이 사냥에 나서는 시점이었다.
class FileReceiver {
  final FileMeta meta;

  /// 부분 파일이 기록되는 위치. 최종 목적지의 이름 지정/정리는 호출자가 책임지며,
  /// [finalize]는 성공 시 이 경로를 반환한다.
  final String partPath;

  final Set<int> _have = {};
  RandomAccessFile? _raf;

  FileReceiver(this.meta, this.partPath) {
    final f = File(partPath);
    f.parent.createSync(recursive: true);
    _raf = f.openSync(mode: FileMode.write);
    // 순서가 뒤섞인 청크 기록이 파일 안쪽에 안착하도록 미리 공간을 할당한다.
    _raf!.truncateSync(meta.fileSize);
  }

  /// 이 청크가 새것(중복이 아님)이면 true를 반환한다.
  bool offer(FileChunk chunk) {
    final raf = _raf;
    if (raf == null) return false; // 완료됨/폐기됨
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

  /// [maxMissing]는 아주 큰 전송에서 ACK 프레임 크기를 제한한다: 발신자가 먼저
  /// 보고된 빈 곳을 채우고, 이후의 ACK들이 나머지를 다룬다.
  FileAck buildAck({int? maxMissing}) {
    if (isComplete) return FileAck(meta.transferId, true, const []);
    var missing = missingSeqs();
    if (maxMissing != null && missing.length > maxMissing) {
      missing = missing.sublist(0, maxMissing);
    }
    return FileAck(meta.transferId, false, missing);
  }

  /// 패스트레인 경로: 평문 전체를 한 번에 받는다(대역 외로 도착했고, 이미
  /// 복호화됨). 수신자 상태를 건드리기 전에 매니페스트 해시를 먼저 검증한다 —
  /// 불일치 시 청크 맵을 비워 두어야 BLE 복구가 파일을 다시 당겨올 수 있다 —
  /// 그런 다음 부분 파일에 기록하고 모든 청크를 존재하는 것으로 표시하여
  /// [buildAck]가 진짜 완료를 보고하게 한다.
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

  /// 전송을 완료한다: 부분 파일을 닫고, 스트리밍으로 해시를 검증한 뒤,
  /// 그 경로를 반환한다. 미완성이거나 불일치면 예외를 던진다(손상된 부분
  /// 파일은 삭제된다).
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

  /// 중단: 부분 파일을 닫고 삭제한다.
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
