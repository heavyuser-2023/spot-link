import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/ble/radio_health.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';

import 'fake_transport.dart';

/// "복구 장치 자체가 조용히 죽는" 사건 계열의 회귀 방지.
///
/// 2026-07-26 heavy↔gold: heavy가 gold를 오프라인으로 표시하고 메시지가 가지
/// 않았다. 원인이 셋 겹쳤고, 셋 다 **겉보기엔 정상**이라는 공통점이 있었다
/// (스캔·광고는 계속 돌았다):
///  1. 유지보수(self-heal) 타이머가 죽어 자가복구 전체가 13시간 꺼져 있었다.
///  2. 대기 연결 슬롯이 누수돼 그 피어로의 재연결·다이얼이 전부 건너뛰어졌다.
///  3. 사용자가 보내도 무선 쪽에서 아무 복구도 시작되지 않았다.
void main() {
  group('결함 3: 링크 0에서 전송하면 능동 복구가 걸린다', () {
    test('links=0으로 보낼 때 전송 계층을 깨운다', () async {
      final radio = FakeRadio();
      final id = await Identity.generate();
      final peer = await Identity.generate();
      final transport = radio.create(id.peerId);
      final node = MeshNode(
          identity: id, displayName: 'A', transport: transport);
      await node.start();
      node.addContact(ContactIdentity.fromBundle(peer.publicBundle));

      // 아무와도 링크되지 않은 상태(상대를 radio.connect 하지 않음).
      expect(transport.linkCount, 0);
      final wakesBefore = transport.wakeCount;

      await node.sendText(peer.peerId, 'hello');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(transport.wakeCount, greaterThan(wakesBefore),
          reason: '링크가 없는데 보냈다 = 지금 찾으라는 가장 강한 신호다');
      await node.dispose();
    });

    test('연속 전송이 재탐색을 연쇄시키지 않는다(Android 주소 회전 방지)', () async {
      // 재탐색은 광고를 stop→start로 교체하고, Android는 그때마다 새 RPA를
      // 할당한다. 연달아 보내며 주소를 계속 갈아치우면 백그라운드 상대가
      // dial을 끝낼 시간을 얻지 못해 복구가 오히려 발견을 망친다.
      final radio = FakeRadio();
      final id = await Identity.generate();
      final peer = await Identity.generate();
      final transport = radio.create(id.peerId);
      final node =
          MeshNode(identity: id, displayName: 'A', transport: transport);
      await node.start();
      node.addContact(ContactIdentity.fromBundle(peer.publicBundle));

      final before = transport.wakeCount;
      for (var i = 0; i < 5; i++) {
        await node.sendText(peer.peerId, 'msg $i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(transport.wakeCount - before, 1,
          reason: '5회 연속 전송이라도 재탐색은 창당 한 번이어야 한다');
      await node.dispose();
    });

    test('링크가 있으면 불필요한 재탐색을 걸지 않는다', () async {
      final radio = FakeRadio();
      final ida = await Identity.generate();
      final idb = await Identity.generate();
      final ta = radio.create(ida.peerId);
      final tb = radio.create(idb.peerId);
      final a = MeshNode(identity: ida, displayName: 'A', transport: ta);
      final b = MeshNode(identity: idb, displayName: 'B', transport: tb);
      await a.start();
      await b.start();
      a.addContact(ContactIdentity.fromBundle(idb.publicBundle));
      b.addContact(ContactIdentity.fromBundle(ida.publicBundle));
      radio.connect(ida.peerId, idb.peerId);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final wakesBefore = ta.wakeCount;
      await a.sendText(idb.peerId, 'hi');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(ta.wakeCount, wakesBefore,
          reason: '정상 경로에서 매번 재탐색을 걸면 무선을 낭비한다');
      await a.dispose();
      await b.dispose();
    });
  });

  group('결함 1·2를 잡는 계약: 전송 계층은 복구 생존 신호를 노출한다', () {
    test('하트비트와 재기동 API가 인터페이스에 있다', () async {
      // 이 계약이 있어야 앱 계층 감시자가 '복구 장치가 죽었는지'를 알 수 있다.
      // (예전에는 알 방법이 없어 13시간 동안 아무도 몰랐다.)
      final t = FakeRadio().create((await Identity.generate()).peerId);
      expect(t.lastMaintenanceTick, isNotNull);
      t.restartMaintenance();
      expect(t.restartMaintenanceCalls, 1);
    });

    test('health가 자체 복구 대상과 사용자 조치 대상을 구분한다', () {
      // 감시자·하드리셋이 같은 근거를 쓰도록 강제하는 불변식.
      expect(RadioHealth.stackAged.needsSelfRepair, isTrue);
      expect(RadioHealth.quiet.needsSelfRepair, isFalse);
      expect(RadioHealth.radioOff.needsUserAction, isTrue);
    });
  });
}
