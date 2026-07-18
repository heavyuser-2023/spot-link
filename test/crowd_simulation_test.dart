import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spot_link/app/mesh_controller.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/core/model/announce.dart';
import 'package:spot_link/core/model/frame.dart';
import 'package:spot_link/core/model/peer_id.dart';
import 'package:spot_link/data/app_database.dart';
import 'package:spot_link/data/identity_store.dart';

import 'fake_transport.dart';

/// 다중 노드(군중) 시뮬레이션: 실기기 100대 없이 가상 피어 100명의
/// ANNOUNCE를 주입해, 100명 밀집 환경에서 코드 계층이 올바르고 빠르게
/// 동작하는지 검증한다.
///
/// 사용법:
///   flutter test test/crowd_simulation_test.dart          ← 단독 실행
///   flutter test                                           ← 전체 회귀(배포 전)
///   PEERS 상수를 500 등으로 바꿔 파라미터 실험도 가능.
///
/// 무엇을 지키는가:
///  1) 정확성: 100명 전원이 연락처·프레즌스로 잡힌다(중복 없이).
///  2) notify 코얼레싱: announce 폭주가 UI 리빌드 폭주가 되지 않는다
///     (200ms 코얼레싱 — 이 가드가 없으면 100명 현장에서 초당 수십 회
///     전체 리빌드가 발생한다).
///  3) 처리량: 100건 announce 버스트 처리가 시간 예산 안에 끝난다.
///  4) 중복 억제: 같은 프레임 재주입이 이벤트를 다시 만들지 않는다.
///
/// 시뮬의 한계(의도된 것): 실제 BLE 공기시간·전파 혼잡은 물리라 여기서
/// 검증할 수 없다 — 그것은 실기기 현장 테스트의 몫이고, 이 테스트는
/// "우리 코드"의 회귀를 막는다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const peers = 100;
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('spotlink_crowd');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('$peers명 군중: 정확성 + notify 코얼레싱 + 처리량', () async {
    final id = await Identity.generate();
    final radio = FakeRadio();
    final transport = radio.create(id.peerId);
    final node = MeshNode(identity: id, displayName: 'Me', transport: transport);
    final c = MeshController(
      identity: id,
      displayName: 'Me',
      db: AppDatabase(overridePath: p.join(tmp.path, 'crowd.db')),
      identityStore: IdentityStore(),
      node: node,
    );
    await c.init();

    // 가상 피어 100명: 실제 crypto 신원으로 유효한 ANNOUNCE 프레임을 만든다
    // (파싱·키 학습 경로까지 실제 코드로 태우기 위해 위조가 아닌 진짜 번들).
    final frames = <Frame>[];
    for (var i = 0; i < peers; i++) {
      final pid = await Identity.generate();
      frames.add(Frame.create(
        type: FrameType.announce,
        ttl: MeshNode.announceTtl,
        src: pid.peerId,
        dst: PeerId.broadcast,
        payload: Announce(
          publicBundle: pid.publicBundle,
          displayName: '피어$i',
          avatar: 'FM1:${List.filled(13, i % 5).join(',')}',
        ).encode(),
      ));
    }

    // notify 폭주 감시: 버스트 주입 동안의 리빌드 횟수를 센다.
    var notifies = 0;
    c.addListener(() => notifies++);

    final sw = Stopwatch()..start();
    for (final f in frames) {
      transport.injectRaw(f.encode(), linkId: 'sim-${f.src.hex}');
    }
    // 코얼레싱 창(200ms)이 소화할 시간을 준다.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    sw.stop();

    // 1) 정확성: 전원 연락처 + 프레즌스.
    expect(c.contacts.length, peers, reason: '100명 전원이 연락처로 잡혀야 한다');
    expect(c.nearbyCount, peers, reason: '100명 전원이 주변으로 보여야 한다');
    // 아바타 레시피도 학습됐는지 표본 확인.
    expect(c.contacts.first.avatar, startsWith('FM1:'));

    // 2) notify 코얼레싱: 100건 주입이 100번의 리빌드가 되면 안 된다.
    //    1.2초 / 200ms = 최대 ~6회 + 여유. (가드가 없으면 100+회가 된다.)
    expect(notifies, lessThanOrEqualTo(12),
        reason: 'announce 폭주는 200ms 코얼레싱으로 묶여야 한다 '
            '(실측 $notifies회)');

    // 3) 처리량: 100건 파싱+키 학습+DB upsert가 예산 안에.
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
        reason: '100명 버스트 처리 ${sw.elapsedMilliseconds}ms');

    // 4) 중복 억제: 같은 프레임 재주입 → seen-cache가 버려야 한다.
    final before = c.contacts.length;
    for (final f in frames) {
      transport.injectRaw(f.encode(), linkId: 'sim-${f.src.hex}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.contacts.length, before, reason: '재주입은 중복을 만들지 않는다');

    c.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}
