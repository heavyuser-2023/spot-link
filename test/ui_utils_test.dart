import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:spot_link/features/ui_utils.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ko', null);
  });

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

  test('dayLabel returns 오늘 for now', () {
    expect(dayLabel(DateTime.now().millisecondsSinceEpoch), '오늘');
  });

  test('relativeTime returns 지금 for now', () {
    expect(relativeTime(DateTime.now().millisecondsSinceEpoch), '지금');
  });
}
