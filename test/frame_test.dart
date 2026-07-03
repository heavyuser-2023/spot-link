import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/model/frame.dart';
import 'package:spot_link/core/model/peer_id.dart';

void main() {
  group('PeerId', () {
    test('truncates and pads to wire length', () {
      final long = PeerId(Uint8List.fromList(List.generate(32, (i) => i)));
      expect(long.bytes.length, PeerId.wireLength);
      expect(long.bytes[0], 0);
      expect(long.bytes[7], 7);

      final short = PeerId(Uint8List.fromList([1, 2, 3]));
      expect(short.bytes.length, PeerId.wireLength);
      expect(short.bytes[0], 1);
      expect(short.bytes[7], 0);
    });

    test('broadcast is all zero', () {
      expect(PeerId.broadcast.isBroadcast, isTrue);
      expect(PeerId(Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0])).isBroadcast,
          isFalse);
    });

    test('hex round-trips', () {
      final id = PeerId(Uint8List.fromList([0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4]));
      expect(id.hex, 'deadbeef01020304');
      expect(PeerId.fromHex(id.hex), id);
    });

    test('equality and hashCode', () {
      final a = PeerId(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      final b = PeerId(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('compareTo orders lexicographically', () {
      final a = PeerId(Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 0]));
      final b = PeerId(Uint8List.fromList([2, 0, 0, 0, 0, 0, 0, 0]));
      expect(a.compareTo(b) < 0, isTrue);
      expect(b.compareTo(a) > 0, isTrue);
      expect(a.compareTo(a), 0);
    });
  });

  group('Frame codec', () {
    test('encode/decode round-trips', () {
      final src = PeerId(Uint8List.fromList([1, 1, 1, 1, 1, 1, 1, 1]));
      final dst = PeerId(Uint8List.fromList([2, 2, 2, 2, 2, 2, 2, 2]));
      final payload = Uint8List.fromList(
          List.generate(300, (i) => i % 256)); // > single chunk
      final frame = Frame.create(
        type: FrameType.text,
        ttl: 7,
        src: src,
        dst: dst,
        payload: payload,
        flags: FrameFlags.encrypted | FrameFlags.ackRequested,
      );

      final decoded = Frame.decode(frame.encode());
      expect(decoded.type, FrameType.text);
      expect(decoded.ttl, 7);
      expect(decoded.src, src);
      expect(decoded.dst, dst);
      expect(decoded.msgIdHex, frame.msgIdHex);
      expect(decoded.payload, payload);
      expect(decoded.isEncrypted, isTrue);
      expect(decoded.ackRequested, isTrue);
    });

    test('empty payload round-trips', () {
      final frame = Frame.create(
        type: FrameType.ack,
        ttl: 5,
        src: PeerId(Uint8List(8)),
        dst: PeerId(Uint8List(8)),
        payload: Uint8List(0),
      );
      final decoded = Frame.decode(frame.encode());
      expect(decoded.payload.length, 0);
      expect(decoded.type, FrameType.ack);
    });

    test('decode rejects truncated header', () {
      expect(() => Frame.decode(Uint8List(10)), throwsFormatException);
    });

    test('copyWith changes ttl only', () {
      final frame = Frame.create(
        type: FrameType.text,
        ttl: 7,
        src: PeerId(Uint8List(8)),
        dst: PeerId(Uint8List(8)),
        payload: Uint8List.fromList([9, 9]),
      );
      final c = frame.copyWith(ttl: 6);
      expect(c.ttl, 6);
      expect(c.msgIdHex, frame.msgIdHex);
      expect(c.payload, frame.payload);
    });

    test('link-local classification', () {
      expect(FrameType.announce.isLinkLocal, isTrue);
      expect(FrameType.have.isLinkLocal, isTrue);
      expect(FrameType.want.isLinkLocal, isTrue);
      expect(FrameType.text.isLinkLocal, isFalse);
      expect(FrameType.fileChunk.isLinkLocal, isFalse);
    });
  });
}
