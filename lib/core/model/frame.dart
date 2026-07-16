import 'dart:math';
import 'dart:typed_data';

import 'peer_id.dart';

/// [Frame]에 실리는 메시지 타입들. docs/ARCHITECTURE.md §6 참고.
enum FrameType {
  announce(0x01), // 메시 플러딩되는 존재 알림 + 신원 (TTL 제한, node 참고)
  text(0x02), // e2e: 텍스트 메시지
  fileMeta(0x03), // e2e: 파일 전송의 시작
  fileChunk(0x04), // e2e: 파일 청크
  ack(0x05), // e2e: msgId에 대한 전달 확인
  have(0x06), // link-local: store-and-forward 인벤토리
  want(0x07), // link-local: 특정 msgId 요청
  receipt(0x08), // e2e: 종단 간 전달 영수증
  fileFastOffer(0x09), // e2e: 발신자가 이 전송에 Wi-Fi 패스트레인을 제안
  fileFastAccept(0x0a); // e2e: 수신자가 수락 + 자신의 연결 정보를 반환

  final int code;
  const FrameType(this.code);

  static FrameType fromCode(int code) {
    for (final t in FrameType.values) {
      if (t.code == code) return t;
    }
    throw FormatException('Unknown FrameType code: $code');
  }

  /// 링크-로컬 프레임은 직접 이웃 사이에서만 한 홉 이동하며, 릴레이되지도
  /// 종단 간 암호화되지도 않는다.
  bool get isLinkLocal => this == FrameType.have || this == FrameType.want;
}

/// 프레임 헤더의 비트 플래그.
class FrameFlags {
  static const int encrypted = 0x01;
  static const int compressed = 0x02;
  static const int ackRequested = 0x04;
}

/// msgId는 중복 제거 키로 사용되는 무작위 128비트 값이다.
class MsgId {
  static final Random _rng = Random.secure();

  static Uint8List generate() {
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  static String hex(Uint8List id) {
    final sb = StringBuffer();
    for (final b in id) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

/// 라우팅 가능한 메시 프레임. [Router]가 다루는 단위이다.
///
/// 와이어 레이아웃 (big-endian), 전체 헤더 = 40바이트:
/// ```
/// 0   version   u8
/// 1   type      u8
/// 2   ttl       u8
/// 3   flags     u8
/// 4   msgId     16바이트
/// 20  srcId     8바이트
/// 28  dstId     8바이트
/// 36  payloadLen u32
/// 40  payload   payloadLen 바이트
/// ```
class Frame {
  static const int version1 = 1;
  static const int headerLength = 40;

  final int version;
  final FrameType type;
  int ttl; // 가변: 프레임이 릴레이될 때마다 감소한다
  final int flags;
  final Uint8List msgId; // 16바이트
  final PeerId src;
  final PeerId dst;
  final Uint8List payload;

  Frame({
    this.version = version1,
    required this.type,
    required this.ttl,
    required this.flags,
    required this.msgId,
    required this.src,
    required this.dst,
    required this.payload,
  });

  /// 새 무작위 msgId를 할당하는 편의 생성자.
  factory Frame.create({
    required FrameType type,
    required int ttl,
    required PeerId src,
    required PeerId dst,
    required Uint8List payload,
    int flags = 0,
  }) {
    return Frame(
      type: type,
      ttl: ttl,
      flags: flags,
      msgId: MsgId.generate(),
      src: src,
      dst: dst,
      payload: payload,
    );
  }

  String get msgIdHex => MsgId.hex(msgId);

  bool get isEncrypted => flags & FrameFlags.encrypted != 0;
  bool get ackRequested => flags & FrameFlags.ackRequested != 0;

  Uint8List encode() {
    final out = Uint8List(headerLength + payload.length);
    final bd = ByteData.view(out.buffer);
    bd.setUint8(0, version);
    bd.setUint8(1, type.code);
    bd.setUint8(2, ttl);
    bd.setUint8(3, flags);
    out.setRange(4, 20, msgId);
    out.setRange(20, 28, src.bytes);
    out.setRange(28, 36, dst.bytes);
    bd.setUint32(36, payload.length, Endian.big);
    out.setRange(headerLength, out.length, payload);
    return out;
  }

  static Frame decode(Uint8List data) {
    if (data.length < headerLength) {
      throw const FormatException('Frame too short for header');
    }
    final bd = ByteData.view(data.buffer, data.offsetInBytes);
    final version = bd.getUint8(0);
    final type = FrameType.fromCode(bd.getUint8(1));
    final ttl = bd.getUint8(2);
    final flags = bd.getUint8(3);
    final msgId = Uint8List.fromList(data.sublist(4, 20));
    final src = PeerId(Uint8List.fromList(data.sublist(20, 28)));
    final dst = PeerId(Uint8List.fromList(data.sublist(28, 36)));
    final payloadLen = bd.getUint32(36, Endian.big);
    if (data.length < headerLength + payloadLen) {
      throw const FormatException('Frame payload truncated');
    }
    final payload = Uint8List.fromList(
        data.sublist(headerLength, headerLength + payloadLen));
    return Frame(
      version: version,
      type: type,
      ttl: ttl,
      flags: flags,
      msgId: msgId,
      src: src,
      dst: dst,
      payload: payload,
    );
  }

  Frame copyWith({int? ttl}) => Frame(
        version: version,
        type: type,
        ttl: ttl ?? this.ttl,
        flags: flags,
        msgId: msgId,
        src: src,
        dst: dst,
        payload: payload,
      );

  @override
  String toString() =>
      'Frame(${type.name} ttl=$ttl ${src.short}->${dst.short} '
      'id=${msgIdHex.substring(0, 8)} len=${payload.length})';
}
