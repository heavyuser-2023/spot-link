import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/ble/radio_health.dart';

/// 판정 로직을 못질한다. 각 케이스는 **실제로 일어난 사건**에 대응한다 —
/// 이번 주에 사람이 ble.log를 손으로 읽어 구분했던 것들이다.
void main() {
  const grace = Duration(seconds: 45);
  const aged = Duration(minutes: 4);

  RadioHealth classify({
    bool started = true,
    bool poweredOff = false,
    bool unauthorized = false,
    int linkCount = 0,
    Duration sinceProgress = Duration.zero,
    bool flapping = false,
  }) =>
      RadioHealth.classify(
        started: started,
        poweredOff: poweredOff,
        unauthorized: unauthorized,
        linkCount: linkCount,
        sinceProgress: sinceProgress,
        flapping: flapping,
        searchingGrace: grace,
        agedAfter: aged,
      );

  group('사용자만 해결할 수 있는 상태가 최우선', () {
    test('블루투스 꺼짐은 다른 모든 신호를 압도한다', () {
      expect(
          classify(poweredOff: true, linkCount: 3, sinceProgress: Duration.zero),
          RadioHealth.radioOff);
      expect(classify(poweredOff: true).needsUserAction, isTrue);
    });

    test('권한 없음도 마찬가지', () {
      expect(classify(unauthorized: true, linkCount: 3), RadioHealth.unauthorized);
      expect(classify(unauthorized: true).needsUserAction, isTrue);
    });

    test('시작 전에는 stopped', () {
      expect(classify(started: false), RadioHealth.stopped);
    });
  });

  group('정상 및 탐색 중', () {
    test('링크가 있으면 linked', () {
      expect(classify(linkCount: 1, sinceProgress: const Duration(hours: 2)),
          RadioHealth.linked);
    });

    test('유예 안에 진전이 있었으면 searching', () {
      expect(classify(sinceProgress: const Duration(seconds: 10)),
          RadioHealth.searching);
      expect(classify(sinceProgress: grace), RadioHealth.searching);
    });
  });

  group('quiet: 주변에 아무도 없음 (오탐 알림의 근원)', () {
    test('유예를 넘겼지만 노화 전이면 quiet', () {
      expect(classify(sinceProgress: const Duration(minutes: 2)),
          RadioHealth.quiet);
    });

    test('quiet에는 친구 근거가 없다 — 이 상태로 알림을 보내면 오탐', () {
      // 2026-07-24 09:07 사건: 주변에 아무 기기도 없는데 iOS 프리워밍이 앱을
      // 깨웠고, '백그라운드 재기동 + 링크 0'만 보고 "주변에 친구가 있어요"를
      // 3연발로 보냈다.
      expect(RadioHealth.quiet.hasPeerEvidence, isFalse);
      expect(RadioHealth.stackAged.hasPeerEvidence, isFalse);
      // 반대로 아래 상태들은 실제로 상대 신호를 본 것이다.
      expect(RadioHealth.linked.hasPeerEvidence, isTrue);
      expect(RadioHealth.searching.hasPeerEvidence, isTrue);
      expect(RadioHealth.linkFlapping.hasPeerEvidence, isTrue);
    });
  });

  group('linkFlapping: 상대 스택 문제 (삼성 사건)', () {
    test('플랩은 searching보다 우선한다 — 조치가 다르기 때문', () {
      // 2026-07-24 12:38~ 삼성 최신폰: link up→10초 write 타임아웃→절단→
      // 재연결을 39회 반복. 진전 시계는 계속 갱신되므로 searching으로 보이지만,
      // 옳은 조치는 '더 세게 두드리기'가 아니라 '재연결 억제'다.
      expect(classify(sinceProgress: const Duration(seconds: 3), flapping: true),
          RadioHealth.linkFlapping);
    });

    test('링크가 실제로 붙어 있으면 플랩보다 linked가 우선', () {
      expect(classify(linkCount: 1, flapping: true), RadioHealth.linked);
    });

    test('플랩은 사용자 조치나 자체 복구 대상이 아니다', () {
      expect(RadioHealth.linkFlapping.needsUserAction, isFalse);
      expect(RadioHealth.linkFlapping.needsSelfRepair, isFalse);
    });
  });

  group('stackAged: 우리 스택이 죽음 (CoreBluetooth 세션 노화 사건)', () {
    test('진전이 노화 임계를 넘기면 stackAged', () {
      // 2026-07-25: heavy의 19.5시간 세션에서 발견 0건 + 본딩 식별자 pending이
      // 90초마다 만료 반복. 앱 재시작 4초 만에 링크 → 우리 스택이 죽은 것.
      expect(classify(sinceProgress: aged), RadioHealth.stackAged);
      expect(classify(sinceProgress: const Duration(hours: 19)),
          RadioHealth.stackAged);
    });

    test('자체 복구(하드리셋) 대상으로 표시된다', () {
      expect(RadioHealth.stackAged.needsSelfRepair, isTrue);
      // 사용자에게 시킬 일이 아니다 — 예전에는 사용자가 매번 강제 종료했다.
      expect(RadioHealth.stackAged.needsUserAction, isFalse);
    });

    test('노화 상태여도 링크가 붙으면 즉시 linked로 돌아온다', () {
      expect(classify(linkCount: 1, sinceProgress: const Duration(hours: 19)),
          RadioHealth.linked);
    });
  });

  group('상태 집합 불변식', () {
    test('needsUserAction과 needsSelfRepair는 겹치지 않는다', () {
      for (final h in RadioHealth.values) {
        expect(h.needsUserAction && h.needsSelfRepair, isFalse, reason: h.name);
      }
    });

    test('사용자 조치·자체 복구 상태에는 친구 근거가 없다', () {
      for (final h in RadioHealth.values) {
        if (h.needsUserAction || h.needsSelfRepair) {
          expect(h.hasPeerEvidence, isFalse, reason: h.name);
        }
      }
    });
  });
}
