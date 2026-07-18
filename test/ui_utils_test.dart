import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:spot_link/features/ui_utils.dart';
import 'package:spot_link/l10n/l10n.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ko', null);
  });

  /// 로케일 의존 헬퍼(dayLabel/relativeTime)에 한국어 컨텍스트를 공급한다.
  Future<BuildContext> koContext(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ko'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    return ctx;
  }

  test('avatarColor is deterministic and within palette', () {
    final a = avatarColor('deadbeef01020304');
    final b = avatarColor('deadbeef01020304');
    expect(a, b);
    // Different keys generally differ (not guaranteed, but these do).
    expect(avatarColor('aaaa'), isNot(equals(avatarColor('bbbbcccc'))));
  });

  test('initialsOf handles ascii, hangul, empty', () {
    expect(initialsOf('kim'), 'K');
    expect(initialsOf('정훈'), '정');
    expect(initialsOf(''), '?');
    expect(initialsOf('   '), '?');
  });

  test('humanSize formats bytes/KB/MB', () {
    expect(humanSize(500), '500 B');
    expect(humanSize(2048), '2.0 KB');
    expect(humanSize(5 * 1024 * 1024), '5.0 MB');
  });

  test('sameDay distinguishes calendar days', () {
    final base = DateTime(2026, 7, 2, 10).millisecondsSinceEpoch;
    final sameDayLater = DateTime(2026, 7, 2, 23).millisecondsSinceEpoch;
    final nextDay = DateTime(2026, 7, 3, 1).millisecondsSinceEpoch;
    expect(sameDay(base, sameDayLater), isTrue);
    expect(sameDay(base, nextDay), isFalse);
  });

  testWidgets('dayLabel returns 오늘 for now (ko locale)', (tester) async {
    final ctx = await koContext(tester);
    expect(dayLabel(ctx, DateTime.now().millisecondsSinceEpoch), '오늘');
  });

  testWidgets('relativeTime returns 지금 for now (ko locale)', (tester) async {
    final ctx = await koContext(tester);
    expect(relativeTime(ctx, DateTime.now().millisecondsSinceEpoch), '지금');
  });

  test('proximityBucket maps RSSI and hops to honest buckets', () {
    expect(proximityBucket(-40, 1), (level: Proximity.veryNear, ring: 0));
    expect(proximityBucket(-55, 1), (level: Proximity.veryNear, ring: 0));
    expect(proximityBucket(-60, 1), (level: Proximity.near, ring: 1));
    expect(proximityBucket(-75, 1), (level: Proximity.nearby, ring: 2));
    expect(proximityBucket(-95, 1), (level: Proximity.far, ring: 3));
    // No reading yet: honest middle bucket.
    expect(proximityBucket(null, 1), (level: Proximity.unknown, ring: 2));
    // Multihop always sits on the outer ring, even with a strong reading
    // from some stale direct encounter.
    expect(proximityBucket(-40, 2), (level: Proximity.relayed, ring: 3));
    expect(proximityBucket(null, 3), (level: Proximity.relayed, ring: 3));
  });

  testWidgets('Proximity labels resolve in ko locale', (tester) async {
    final ctx = await koContext(tester);
    expect(Proximity.veryNear.label(ctx), '바로 옆');
    expect(Proximity.relayed.label(ctx, hops: 2), '2홉 건너');
  });
}
