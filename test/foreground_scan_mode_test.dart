import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spot_link/app/mesh_controller.dart';
import 'package:spot_link/core/ble/radio_profile.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/data/app_database.dart';
import 'package:spot_link/data/identity_store.dart';

import 'fake_transport.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// 2026-07-30 heavy 사건의 회귀 방지: **"주변에 친구가 있다"는 알림은 옳았는데
/// 앱이 친구를 끝까지 발견하지 못한** 사건.
///
/// 근본 원인은 포그라운드 상태가 세 곳에서 서로 다른 규칙으로 판정되고, 그
/// 불일치를 아무도 교정하지 못한 것이었다:
///
///  * 컨트롤러: `lifecycleState == resumed || == null`
///  * 전송(부트 경로): `!= paused && != detached && != hidden`
///  * 부트 3초 재확인: `paused|detached|hidden`일 때만 백그라운드로 정정
///
/// 백그라운드 재기동의 **실제 시그니처는 `inactive`** 다. 그러면 컨트롤러는
/// false(정답), 전송은 true(오답)가 되고, 재조정 틱은 자기 캐시(`_foreground`)와
/// 관측값이 이미 일치하므로 매 10초 즉시 return한다 → 전송의 잘못된 모드는
/// 영구히 남는다. 실제 로그 3310행 전체에 'reconciled' 한 줄도 없었다.
///
/// 결과는 양방향으로 치명적이었다:
///  1. 백그라운드인데 무필터 스캔 → iOS가 광고를 하나도 전달하지 않는다
///     (12번의 비콘 웨이크 내내 발견 0건).
///  2. 사용자가 앱을 열어도 전송이 필터 스캔에 갇혀 있으면, iOS 27에서
///     포그라운드 iPhone을 볼 수 있는 유일한 모드를 못 쓴다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  var counter = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('spotlink_fg');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// iOS 정책을 주입한 컨트롤러 — 포그라운드 재조정은 iOS 전용 정책이다.
  Future<(MeshController, FakeTransport)> buildIos() async {
    final id = await Identity.generate();
    final radio = FakeRadio();
    final t = radio.create(id.peerId);
    final c = MeshController(
      identity: id,
      displayName: 'Me',
      db: AppDatabase(overridePath: p.join(tmp.path, 'fg${counter++}.db')),
      identityStore: IdentityStore(),
      node: MeshNode(identity: id, displayName: 'Me', transport: t),
      profile: RadioProfile.ios,
    );
    await c.init();
    return (c, t);
  }

  tearDown(() async {
    // 각 테스트가 생명주기 상태를 건드리므로 원상복구한다.
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test('포그라운드 진입은 컨트롤러 캐시와 무관하게 전송에 전달된다', () async {
    final (c, t) = await buildIos();

    // 사건 당시의 상태: 전송은 백그라운드 모드(필터 스캔)인데, 컨트롤러의 캐시는
    // 부트 낙관값 때문에 이미 true다.
    t.foregroundScan = false;
    c.setForegroundForTest(true);
    final appliedBefore = t.foregroundApplied;

    c.didChangeAppLifecycleState(AppLifecycleState.resumed);

    expect(t.foregroundScan, isTrue,
        reason: '사용자가 앱을 열었다 — 전송은 반드시 넓은(무필터) 스캔으로 올라와야 한다. '
            '예전에는 wasForeground가 이미 true라 이 호출이 통째로 삼켜졌고, '
            '앱을 쳐다보는 동안 친구를 영영 못 찾았다');
    expect(t.foregroundApplied, greaterThan(appliedBefore));

    await c.node.dispose();
  });

  test('재조정 틱은 자기 캐시가 관측값과 일치해도 전송을 바로잡는다', () async {
    final (c, t) = await buildIos();

    // 부트 desync 재현: 실제로는 백그라운드(`inactive`), 컨트롤러 캐시도 false
    // (그래서 재조정은 "변화 없음"으로 본다), 그러나 전송은 true에 머물러 있다.
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    c.setForegroundForTest(false);
    t.foregroundScan = true;

    c.reconcileForegroundModeForTest();

    expect(t.foregroundScan, isFalse,
        reason: '백그라운드에서 무필터 스캔은 iOS가 아무것도 전달하지 않는다 — '
            '재조정은 자기 캐시가 아니라 전송의 실제 모드를 바로잡아야 한다');

    await c.node.dispose();
  });

  test('resumed면 재조정이 전송을 포그라운드로 올린다', () async {
    final (c, t) = await buildIos();

    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    c.setForegroundForTest(true); // 캐시는 일치 → 예전엔 즉시 return
    t.foregroundScan = false; // 전송만 뒤처져 있다

    c.reconcileForegroundModeForTest();

    expect(t.foregroundScan, isTrue);

    await c.node.dispose();
  });

  group('스캔 필터 정책(무필터 창이 유일한 포그라운드 iPhone 발견 경로)', () {
    test('iOS: 포그라운드 wide 창만 무필터', () {
      const ios = RadioProfile.ios;
      // 포그라운드 + wide phase → 무필터(포그라운드 iPhone/Android 발견).
      expect(
          ios.useUnfilteredScan(foreground: true, overflowPhase: false), isTrue);
      // 포그라운드 + overflow phase → 필터(백그라운드 iPhone 발견).
      expect(ios.useUnfilteredScan(foreground: true, overflowPhase: true),
          isFalse);
      // 백그라운드는 어떤 phase여도 필터 — 무필터는 OS가 아무것도 전달하지 않는다.
      expect(ios.useUnfilteredScan(foreground: false, overflowPhase: false),
          isFalse);
      expect(
          ios.useUnfilteredScan(foreground: false, overflowPhase: true), isFalse);
    });

    test('Android: 항상 무필터(하드웨어 필터가 overflow 광고를 놓친다)', () {
      const a = RadioProfile.android;
      expect(a.useUnfilteredScan(foreground: false, overflowPhase: true), isTrue);
    });
  });
}
