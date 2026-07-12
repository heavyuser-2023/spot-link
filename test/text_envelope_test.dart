import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/model/text_envelope.dart';

void main() {
  test('round-trips text and send time', () {
    final at = DateTime.fromMillisecondsSinceEpoch(1767950123456);
    final bytes = TextEnvelope.encode('안녕 mesh 👋', sentAt: at);
    final e = TextEnvelope.decode(bytes);
    expect(e.text, '안녕 mesh 👋');
    expect(e.sentAt, at);
  });

  test('legacy plain-utf8 payload decodes with null sentAt', () {
    final legacy = Uint8List.fromList(utf8.encode('옛날 형식 메시지'));
    final e = TextEnvelope.decode(legacy);
    expect(e.text, '옛날 형식 메시지');
    expect(e.sentAt, isNull);
  });

  test('no valid utf8 text can collide with the magic', () {
    // 0x01 followed by 0xA7 (bare continuation byte) is malformed utf8, so a
    // legacy sender can never produce it — but even if malformed bytes arrive,
    // decode must not throw.
    final weird = Uint8List.fromList([0x01, 0xA7]); // too short for envelope
    final e = TextEnvelope.decode(weird);
    expect(e.sentAt, isNull);
  });

  test('absurd clock values are rejected but text still decodes', () {
    final bytes = TextEnvelope.encode('clock?',
        sentAt: DateTime.fromMillisecondsSinceEpoch(0));
    // encode stamps 0 → decoder treats as unknown.
    final e = TextEnvelope.decode(bytes);
    expect(e.text, 'clock?');
    expect(e.sentAt, isNull);
  });
}
