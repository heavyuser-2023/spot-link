import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spot_link/app/device_location.dart';
import 'package:spot_link/app/encounter_tracker.dart';
import 'package:spot_link/data/app_database.dart';
import 'package:spot_link/data/models.dart';

/// "스쳐간 친구" 기록과 친구별 자동 메시지의 규칙(2026-10-04 요청).
///
/// 핵심 제약: 웨이크 비콘에는 신원이 없어 **연결돼야만 누구인지 안다**. 그래서
/// 비콘으로만 잡힌 만남은 미확인으로 남고, 곧이어 연결되면 그 친구로 승격돼야
/// 한다. 자동 메시지는 같은 친구에게 쿨다운당 한 번만 나가야 한다 — 같은
/// 동네에서 하루 수십 번 스치는 사이에 인사가 쏟아지면 안 된다.
void main() {
  late Directory tmp;
  var counter = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('spotlink_enc');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Contact friend(String hex, {String? auto}) => Contact(
        peerHex: hex,
        signingPublicB64: 'sig',
        kexPublicB64: 'kex',
        displayName: 'Friend $hex',
        verified: true,
        autoMessage: auto,
      );

  /// 시계·전송·위치·포그라운드를 조작할 수 있는 추적기 하네스.
  ({
    EncounterTracker tracker,
    AppDatabase db,
    List<(String, String)> sent,
    void Function(Duration) advance,
    void Function(bool) setForeground,
    void Function(bool) setLocationOn,
  }) build({AppDatabase? db, LocationFix? fix}) {
    final database =
        db ?? AppDatabase(overridePath: p.join(tmp.path, 'e${counter++}.db'));
    var now = DateTime(2026, 10, 4, 14, 0);
    var fg = false;
    var locOn = true;
    final sent = <(String, String)>[];
    final tracker = EncounterTracker(
      db: database,
      locate: () async => fix,
      sendAuto: (peer, text) async => sent.add((peer, text)),
      isForeground: () => fg,
      locationEnabled: () async => locOn,
      now: () => now,
    );
    return (
      tracker: tracker,
      db: database,
      sent: sent,
      advance: (d) => now = now.add(d),
      setForeground: (v) => fg = v,
      setLocationOn: (v) => locOn = v,
    );
  }

  /// 비동기로 붙는 위치 기록이 끝나도록 이벤트 루프를 돌린다.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('첫 관측은 만남 하나를 만들고, 앱을 안 보고 있었으면 놓침으로 남는다',
      () async {
    final h = build();
    await h.tracker.onPeerSeen(friend('aa'), hops: 1);
    final list = await h.db.encounters();
    expect(list, hasLength(1));
    expect(list.single.peerHex, 'aa');
    expect(list.single.source, EncounterSource.link);
    expect(list.single.missed, isTrue,
        reason: '보지 못한 사이 스쳐 간 것을 나중에 알 수 있어야 한다');
  });

  test('간격 안의 반복 ANNOUNCE는 같은 만남을 늘리고, 간격 뒤엔 새 만남', () async {
    final h = build();
    await h.tracker.onPeerSeen(friend('aa'), hops: 1);
    h.advance(const Duration(minutes: 2));
    await h.tracker.onPeerSeen(friend('aa'), hops: 1);
    var list = await h.db.encounters();
    expect(list, hasLength(1), reason: 'ANNOUNCE는 15초마다 온다 — 매번 새 기록이면 안 된다');
    expect(list.single.duration, const Duration(minutes: 2));

    h.advance(EncounterTracker.gap + const Duration(minutes: 1));
    await h.tracker.onPeerSeen(friend('aa'), hops: 1);
    list = await h.db.encounters();
    expect(list, hasLength(2));
  });

  test('만남 도중 앱을 보면 놓침이 해제된다', () async {
    final h = build();
    await h.tracker.onPeerSeen(friend('aa'), hops: 1);
    h.setForeground(true);
    h.advance(const Duration(seconds: 15));
    await h.tracker.onPeerSeen(friend('aa'), hops: 1);
    expect((await h.db.encounters()).single.missed, isFalse);
  });

  test('가장 가까웠던 거리(홉)를 남긴다', () async {
    final h = build();
    await h.tracker.onPeerSeen(friend('aa'), hops: 3);
    h.advance(const Duration(seconds: 15));
    await h.tracker.onPeerSeen(friend('aa'), hops: 1);
    expect((await h.db.encounters()).single.hops, 1);
  });

  test('비콘으로만 잡힌 미확인 만남은 곧이어 연결되면 그 친구로 승격된다', () async {
    final h = build();
    await h.tracker.onUnidentifiedNearby();
    var list = await h.db.encounters();
    expect(list.single.peerHex, isNull);
    expect(list.single.source, EncounterSource.beacon);

    h.advance(const Duration(minutes: 1));
    await h.tracker.onPeerSeen(friend('bb'), hops: 1);
    list = await h.db.encounters();
    expect(list, hasLength(1), reason: '같은 만남이다 — 미확인 + 확인 두 줄이 되면 안 된다');
    expect(list.single.peerHex, 'bb');
    expect(list.single.source, EncounterSource.link);
  });

  test('이미 누군가와 연결돼 있으면 비콘 감지는 따로 기록하지 않는다', () async {
    final h = build();
    await h.tracker.onPeerSeen(friend('aa'), hops: 1);
    h.advance(const Duration(seconds: 20));
    await h.tracker.onUnidentifiedNearby();
    expect(await h.db.encounters(), hasLength(1));
  });

  group('자동 메시지', () {
    test('새 만남에서 한 번 보내고, 같은 만남의 반복 ANNOUNCE로는 다시 안 보낸다',
        () async {
      final h = build();
      final f = friend('aa', auto: '근처에 있었네!');
      await h.tracker.onPeerSeen(f, hops: 1);
      h.advance(const Duration(seconds: 15));
      await h.tracker.onPeerSeen(f, hops: 1);
      expect(h.sent, [('aa', '근처에 있었네!')]);
      expect((await h.db.encounters()).single.autoSent, isTrue);
    });

    test('쿨다운 안의 다음 만남에서는 보내지 않고, 쿨다운 뒤엔 다시 보낸다', () async {
      final h = build();
      final f = friend('aa', auto: 'hi');
      await h.tracker.onPeerSeen(f, hops: 1);
      h.advance(EncounterTracker.gap + const Duration(minutes: 1));
      await h.tracker.onPeerSeen(f, hops: 1); // 새 만남, 쿨다운 안
      expect(h.sent, hasLength(1));

      h.advance(EncounterTracker.autoCooldown);
      await h.tracker.onPeerSeen(f, hops: 1); // 쿨다운 지남
      expect(h.sent, hasLength(2));
    });

    test('자동 메시지를 정하지 않은 친구에게는 보내지 않는다', () async {
      final h = build();
      await h.tracker.onPeerSeen(friend('aa'), hops: 1);
      expect(h.sent, isEmpty);
    });

    test('친구마다 따로 센다', () async {
      final h = build();
      await h.tracker.onPeerSeen(friend('aa', auto: 'A'), hops: 1);
      await h.tracker.onPeerSeen(friend('bb', auto: 'B'), hops: 1);
      expect(h.sent, [('aa', 'A'), ('bb', 'B')]);
    });
  });

  group('위치', () {
    test('켜져 있으면 만남에 위치를 붙인다', () async {
      final h = build(fix: const LocationFix(37.5, 127.03, 20));
      await h.tracker.onPeerSeen(friend('aa'), hops: 1);
      await settle();
      final e = (await h.db.encounters()).single;
      expect(e.lat, 37.5);
      expect(e.lng, 127.03);
      expect(e.accuracy, 20);
    });

    test('꺼져 있으면 위치 없이 기록한다', () async {
      final h = build(fix: const LocationFix(37.5, 127.03));
      h.setLocationOn(false);
      await h.tracker.onPeerSeen(friend('aa'), hops: 1);
      await settle();
      expect((await h.db.encounters()).single.hasLocation, isFalse);
    });

    test('위치를 못 받아도 만남은 기록된다', () async {
      final h = build(); // fix == null
      await h.tracker.onPeerSeen(friend('aa'), hops: 1);
      await settle();
      final e = (await h.db.encounters()).single;
      expect(e.hasLocation, isFalse);
      expect(e.peerHex, 'aa');
    });
  });

  test('기존 사용자(v8 DB) 업데이트: 연락처를 보존하며 자동 메시지 열과 만남 표가 생긴다',
      () async {
    final path = p.join(tmp.path, 'v8_${counter++}.db');
    // v8 스키마의 연락처 표만 있으면 8→9 단계를 재현하기에 충분하다.
    final old = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 8,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE contacts (
                peer_hex TEXT PRIMARY KEY, signing_pub TEXT NOT NULL,
                kex_pub TEXT NOT NULL, display_name TEXT NOT NULL,
                verified INTEGER NOT NULL,
                name_locked INTEGER NOT NULL DEFAULT 0,
                last_seen INTEGER NOT NULL, avatar TEXT)''');
            await db.insert('contacts', {
              'peer_hex': 'aa', 'signing_pub': 's', 'kex_pub': 'k',
              'display_name': 'Old friend', 'verified': 1, 'last_seen': 0,
            });
          },
        ));
    await old.close();

    final db = AppDatabase(overridePath: path);
    final contacts = await db.allContacts();
    expect(contacts.single.displayName, 'Old friend');
    expect(contacts.single.autoMessage, isNull);

    await db.upsertContact(contacts.single.withAutoMessage('hi'));
    expect((await db.allContacts()).single.autoMessage, 'hi');
    expect(await db.encounters(), isEmpty, reason: '만남 표가 만들어져 있어야 한다');
  });

  test('재시작 뒤에도 진행 중이던 만남을 이어 붙이고 자동 메시지를 다시 보내지 않는다',
      () async {
    final first = build();
    final f = friend('aa', auto: 'hi');
    await first.tracker.onPeerSeen(f, hops: 1);
    expect(first.sent, hasLength(1));

    // 같은 DB로 새 추적기(앱 재시작) — 메모리 상태는 비어 있다.
    final second = build(db: first.db);
    second.advance(const Duration(minutes: 1));
    await second.tracker.onPeerSeen(f, hops: 1);
    expect(await first.db.encounters(), hasLength(1));
    expect(second.sent, isEmpty);
  });
}
