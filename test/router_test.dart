import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/model/frame.dart';
import 'package:spot_link/core/model/peer_id.dart';
import 'package:spot_link/core/router/router.dart';
import 'package:spot_link/core/router/seen_cache.dart';

PeerId pid(int b) =>
    PeerId(Uint8List.fromList([b, 0, 0, 0, 0, 0, 0, 0]));

void main() {
  late int clock;
  SeenCache makeCache() => SeenCache(nowMs: () => clock);

  setUp(() => clock = 1000);

  Frame makeFrame({
    required PeerId src,
    required PeerId dst,
    int ttl = 7,
    FrameType type = FrameType.text,
  }) =>
      Frame.create(
        type: type,
        ttl: ttl,
        src: src,
        dst: dst,
        payload: Uint8List.fromList([1, 2, 3]),
      );

  test('delivers frame addressed to me, no relay', () {
    final me = pid(1);
    final router = Router(myId: me, seen: makeCache());
    final f = makeFrame(src: pid(2), dst: me);

    final d = router.handleIncoming(f);
    expect(d.deliverLocal, isTrue);
    expect(d.relay, isNull);
    expect(d.duplicate, isFalse);
  });

  test('relays frame not addressed to me with ttl-1', () {
    final me = pid(1);
    final router = Router(myId: me, seen: makeCache());
    final f = makeFrame(src: pid(2), dst: pid(3), ttl: 7);

    final d = router.handleIncoming(f);
    expect(d.deliverLocal, isFalse);
    expect(d.relay, isNotNull);
    expect(d.relay!.ttl, 6);
    expect(d.relay!.msgIdHex, f.msgIdHex);
  });

  test('does not relay when ttl would reach 0', () {
    final me = pid(1);
    final router = Router(myId: me, seen: makeCache());
    final f = makeFrame(src: pid(2), dst: pid(3), ttl: 1);

    final d = router.handleIncoming(f);
    expect(d.relay, isNull);
    expect(d.deliverLocal, isFalse);
  });

  test('broadcast is delivered AND relayed', () {
    final me = pid(1);
    final router = Router(myId: me, seen: makeCache());
    final f = makeFrame(src: pid(2), dst: PeerId.broadcast, ttl: 5);

    final d = router.handleIncoming(f);
    expect(d.deliverLocal, isTrue);
    expect(d.relay, isNotNull);
    expect(d.relay!.ttl, 4);
  });

  test('duplicate frame is dropped', () {
    final me = pid(1);
    final router = Router(myId: me, seen: makeCache());
    final f = makeFrame(src: pid(2), dst: pid(3));

    final first = router.handleIncoming(f);
    expect(first.duplicate, isFalse);

    // Same msgId arriving again (e.g. via another neighbour).
    final second = router.handleIncoming(f);
    expect(second.duplicate, isTrue);
    expect(second.relay, isNull);
    expect(second.deliverLocal, isFalse);
  });

  test('originated frame is pre-marked seen (no echo re-relay)', () {
    final me = pid(1);
    final router = Router(myId: me, seen: makeCache());
    final f = router.originate(
      type: FrameType.text,
      dst: pid(9),
      payload: [1, 2, 3],
    );
    expect(f.ttl, router.defaultTtl);
    expect(f.src, me);

    // If it echoes back, it is a duplicate.
    final d = router.handleIncoming(f);
    expect(d.duplicate, isTrue);
  });

  test('seen cache entries expire after ttl', () {
    final cache = SeenCache(nowMs: () => clock, ttlMs: 1000);
    expect(cache.checkAndMark('a'), isFalse);
    expect(cache.checkAndMark('a'), isTrue);
    clock += 1001;
    expect(cache.checkAndMark('a'), isFalse); // expired -> fresh
  });

  test('seen cache enforces max entries', () {
    final cache = SeenCache(nowMs: () => clock, maxEntries: 3);
    cache.checkAndMark('a');
    cache.checkAndMark('b');
    cache.checkAndMark('c');
    cache.checkAndMark('d'); // evicts 'a'
    expect(cache.length, 3);
    expect(cache.contains('a'), isFalse);
    expect(cache.contains('d'), isTrue);
  });
}
