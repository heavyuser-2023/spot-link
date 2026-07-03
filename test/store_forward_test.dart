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

Frame chunkFrame(int destByte) => Frame.create(
      type: FrameType.fileChunk,
      ttl: 7,
      src: pid(1),
      dst: pid(destByte),
      payload: Uint8List.fromList([1, 2, 3, 4]),
    );

void main() {
  late int clock;
  StoreForward makeStore(
          {int max = 512, int ttl = 1000000, int durableMax = 4096}) =>
      StoreForward(
          nowMs: () => clock,
          maxEntries: max,
          ttlMs: ttl,
          durableMaxEntries: durableMax);

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

  test('does not store link-local or presence frames', () {
    final s = makeStore();
    for (final type in [
      FrameType.announce, // routed but ephemeral: never store presence
      FrameType.have,
      FrameType.want,
    ]) {
      final f = Frame.create(
        type: type,
        ttl: 1,
        src: pid(1),
        dst: pid(2),
        payload: Uint8List(0),
      );
      s.add(f);
    }
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

  test('file frames expire; text frames are durable and never expire', () {
    final s = makeStore(ttl: 1000);
    final text = textFrame(9);
    final chunk = chunkFrame(9);
    s.add(text);
    s.add(chunk);
    clock += 1001;
    expect(s.contains(chunk.msgIdHex), isFalse); // expiring tier pruned
    expect(s.contains(text.msgIdHex), isTrue); // durable: rides forever
    expect(s.inventory().length, 1);
  });

  test('expiring tier enforces max entries by evicting soonest-to-expire', () {
    final s = makeStore(max: 2, ttl: 100000);
    final f1 = chunkFrame(1);
    s.add(f1);
    clock += 10;
    final f2 = chunkFrame(2);
    s.add(f2);
    clock += 10;
    final f3 = chunkFrame(3);
    s.add(f3); // should evict f1 (soonest expiry)
    expect(s.length, 2);
    expect(s.contains(f1.msgIdHex), isFalse);
    expect(s.contains(f3.msgIdHex), isTrue);
  });

  test('durable tier: persistence callbacks, FIFO cap, clear', () {
    final s = makeStore(durableMax: 2);
    final changes = <(String, bool)>[]; // (msgId, stored?)
    s.onDurableChanged = (id, frame) => changes.add((id, frame != null));

    final f1 = textFrame(1);
    s.add(f1);
    clock += 10;
    final f2 = textFrame(2);
    s.add(f2);
    clock += 10;
    final f3 = textFrame(3);
    s.add(f3); // cap 2: evicts the OLDEST stored (f1)

    expect(s.durableCount, 2);
    expect(s.contains(f1.msgIdHex), isFalse);
    expect(
        changes,
        containsAllInOrder([
          (f1.msgIdHex, true),
          (f2.msgIdHex, true),
          (f1.msgIdHex, false), // evicted
          (f3.msgIdHex, true),
        ]));

    // Delivered (RECEIPT) → removed + persistence notified.
    s.remove(f2.msgIdHex);
    expect(changes.last, (f2.msgIdHex, false));

    // User purge: durable gone, no callbacks (caller clears its own db).
    final before = changes.length;
    s.clearDurable();
    expect(s.durableCount, 0);
    expect(changes.length, before);
  });

  test('seed restores durable frames without firing callbacks', () {
    final s = makeStore();
    final changes = <String>[];
    s.onDurableChanged = (id, _) => changes.add(id);
    final f = textFrame(4);
    s.seed([f]);
    expect(s.contains(f.msgIdHex), isTrue);
    expect(s.durableCount, 1);
    expect(changes, isEmpty);
    // Seeded frames serve WANT requests like any stored frame.
    expect(s.framesForWanted([f.msgId]).single.msgIdHex, f.msgIdHex);
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
