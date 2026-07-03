import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/ble/framing.dart';

void main() {
  group('L2Framing', () {
    Uint8List seq(int n) =>
        Uint8List.fromList(List.generate(n, (i) => (i * 7 + 3) % 256));

    test('single chunk when frame fits', () {
      final data = seq(50);
      final packets = L2Framing.split(data, 247);
      expect(packets.length, 1);

      final r = L2Reassembler();
      expect(r.offer(packets[0]), data);
    });

    test('multi chunk split and reassemble in order', () {
      final data = seq(1000);
      final packets = L2Framing.split(data, 247);
      expect(packets.length, greaterThan(1));

      final r = L2Reassembler();
      Uint8List? out;
      for (final p in packets) {
        out = r.offer(p) ?? out;
      }
      expect(out, data);
    });

    test('reassembles out of order', () {
      final data = seq(1000);
      final packets = L2Framing.split(data, 100);
      final r = L2Reassembler();

      final shuffled = [...packets]..shuffle();
      Uint8List? out;
      for (final p in shuffled) {
        final res = r.offer(p);
        if (res != null) out = res;
      }
      expect(out, data);
    });

    test('interleaved transfers on one link do not corrupt', () {
      final a = seq(600);
      final b = Uint8List.fromList(List.generate(600, (i) => (255 - i) % 256));
      final pa = L2Framing.split(a, 120);
      final pb = L2Framing.split(b, 120);

      final r = L2Reassembler();
      Uint8List? outA, outB;
      // interleave
      final maxLen = pa.length > pb.length ? pa.length : pb.length;
      for (var i = 0; i < maxLen; i++) {
        if (i < pa.length) outA = r.offer(pa[i]) ?? outA;
        if (i < pb.length) outB = r.offer(pb[i]) ?? outB;
      }
      expect(outA, a);
      expect(outB, b);
    });

    test('rejects packet size not larger than the header', () {
      // Header is 8 bytes; a packet size <= 8 leaves no room for data.
      expect(() => L2Framing.split(seq(10), 8), throwsArgumentError);
      expect(() => L2Framing.split(seq(10), 4), throwsArgumentError);
    });

    test('works at the minimum usable packet size (20)', () {
      // Regression: the default/minimum link packet size must always split.
      final data = seq(500);
      final packets = L2Framing.split(data, 20);
      expect(packets.every((p) => p.length <= 20), isTrue);
      final r = L2Reassembler();
      Uint8List? out;
      for (final p in packets) {
        out = r.offer(p) ?? out;
      }
      expect(out, data);
    });

    test('reassembler ignores malformed short packet', () {
      final r = L2Reassembler();
      expect(r.offer(Uint8List(5)), isNull);
    });
  });
}
