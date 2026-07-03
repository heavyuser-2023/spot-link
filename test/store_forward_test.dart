import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/model/frame.dart';
import 'package:spot_link/core/model/peer_id.dart';
import 'package:spot_link/core/router/store_forward.dart';

PeerId pid(int b) => PeerId(Uint8List.fromList([b, 0, 0, 0, 0, 0, 0, 0]));

Frame textFrame(int destByte) => Frame.create(
      type: FrameType.text,
      ttl: 7,
      src: pid(1),
      dst: pid(destByte),
      payload: Uint8List.fromList([1, 2, 3]),
    );

void main() {
  late int clock;
  StoreForward makeStore({int max = 512, int ttl = 1000000}) =>
      StoreForward(nowMs: () => clock, maxEntries: max, ttlMs: ttl);

  setUp(() => clock = 1000);

  test('stores and reports inventory', () {
    final s = makeStore();
    final f = textFrame(9);
    s.add(f);
    expect(s.contains(f.msgIdHex), isTrue);
    final inv = s.inventory();
    expect(inv.length, 1);
    expect(MsgId.hex(inv.first), f.msgIdHex);
  });

  test('does not store link-local frames', () {
    final s = makeStore();
    final f = Frame.create(
      type: FrameType.announce,
      ttl: 1,
      src: pid(1),
      dst: pid(2),
      payload: Uint8List(0),
    );
    s.add(f);
    expect(s.length, 0);
  });

  test('selectWanted returns ids we do not hold', () {
    final holder = makeStore();
    final me = makeStore();

    final f1 = textFrame(5);
    final f2 = textFrame(6);
    holder.add(f1);
    holder.add(f2);

    // I already hold f1.
    me.add(f1);

    final wanted = me.selectWanted(holder.inventory());
    expect(wanted.length, 1);
    expect(MsgId.hex(wanted.first), f2.msgIdHex);
  });

  test('selectWanted excludes already-seen ids', () {
    final holder = makeStore();
    final me = makeStore();
    final f = textFrame(5);
    holder.add(f);

    final wanted = me.selectWanted(
      holder.inventory(),
      alreadySeen: (hex) => hex == f.msgIdHex,
    );
    expect(wanted, isEmpty);
  });

  test('framesForWanted returns the requested frames', () {
    final holder = makeStore();
    final f1 = textFrame(5);
    final f2 = textFrame(6);
    holder.add(f1);
    holder.add(f2);

    final frames = holder.framesForWanted([f2.msgId]);
    expect(frames.length, 1);
    expect(frames.first.msgIdHex, f2.msgIdHex);
  });

  test('expired entries are pruned', () {
    final s = makeStore(ttl: 1000);
    final f = textFrame(9);
    s.add(f);
    expect(s.contains(f.msgIdHex), isTrue);
    clock += 1001;
    expect(s.contains(f.msgIdHex), isFalse);
    expect(s.inventory(), isEmpty);
  });

  test('enforces max entries by evicting soonest-to-expire', () {
    final s = makeStore(max: 2, ttl: 100000);
    final f1 = textFrame(1);
    s.add(f1);
    clock += 10;
    final f2 = textFrame(2);
    s.add(f2);
    clock += 10;
    final f3 = textFrame(3);
    s.add(f3); // should evict f1 (soonest expiry)
    expect(s.length, 2);
    expect(s.contains(f1.msgIdHex), isFalse);
    expect(s.contains(f3.msgIdHex), isTrue);
  });

  test('remove deletes an entry (e.g. on receipt)', () {
    final s = makeStore();
    final f = textFrame(9);
    s.add(f);
    s.remove(f.msgIdHex);
    expect(s.contains(f.msgIdHex), isFalse);
  });

  group('MsgIdList codec', () {
    test('round-trips', () {
      final ids = [
        Uint8List.fromList(List.generate(16, (i) => i)),
        Uint8List.fromList(List.generate(16, (i) => 255 - i)),
      ];
      final decoded = MsgIdList.decode(MsgIdList.encode(ids));
      expect(decoded.length, 2);
      expect(decoded[0], ids[0]);
      expect(decoded[1], ids[1]);
    });

    test('empty list', () {
      expect(MsgIdList.decode(MsgIdList.encode([])), isEmpty);
    });
  });
}
