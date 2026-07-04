import 'dart:math';
import 'dart:typed_data';

import 'peer_id.dart';

/// Message types carried in a [Frame]. See docs/ARCHITECTURE.md §6.
enum FrameType {
  announce(0x01), // mesh-flooded presence + identity (TTL-bounded, see node)
  text(0x02), // e2e: text message
  fileMeta(0x03), // e2e: start of a file transfer
  fileChunk(0x04), // e2e: a file chunk
  ack(0x05), // e2e: delivery acknowledgement of a msgId
  have(0x06), // link-local: store-and-forward inventory
  want(0x07), // link-local: request specific msgIds
  receipt(0x08), // e2e: end-to-end delivery receipt
  fileFastOffer(0x09), // e2e: sender offers a Wi-Fi fast-lane for this transfer
  fileFastAccept(0x0a); // e2e: receiver accepts + returns its connection info

  final int code;
  const FrameType(this.code);

  static FrameType fromCode(int code) {
    for (final t in FrameType.values) {
      if (t.code == code) return t;
    }
    throw FormatException('Unknown FrameType code: $code');
  }

  /// Link-local frames hop between direct neighbours and are not relayed
  /// nor end-to-end encrypted.
  bool get isLinkLocal => this == FrameType.have || this == FrameType.want;
}

/// Bit flags in the frame header.
class FrameFlags {
  static const int encrypted = 0x01;
  static const int compressed = 0x02;
  static const int ackRequested = 0x04;
}

/// The msgId is a random 128-bit value used as the dedup key.
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

/// A routable mesh frame. This is the unit the [Router] operates on.
///
/// Wire layout (big-endian), total header = 40 bytes:
/// ```
/// 0   version   u8
/// 1   type      u8
/// 2   ttl       u8
/// 3   flags     u8
/// 4   msgId     16 bytes
/// 20  srcId     8 bytes
/// 28  dstId     8 bytes
/// 36  payloadLen u32
/// 40  payload   payloadLen bytes
/// ```
class Frame {
  static const int version1 = 1;
  static const int headerLength = 40;

  final int version;
  final FrameType type;
  int ttl; // mutable: decremented as the frame is relayed
  final int flags;
  final Uint8List msgId; // 16 bytes
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

  /// Convenience constructor that allocates a fresh random msgId.
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
