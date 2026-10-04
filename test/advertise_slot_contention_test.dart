import 'package:flutter_test/flutter_test.dart';

import 'package:spot_link/core/ble/mesh_transport.dart';

/// 2026-10-04 신고: "iOS에서 안드로이드를 인식해 친구 알림은 오는데, 레이더엔
/// 안 보여 메시지를 못 보낸다 — 일부 삼성 폰에서만."
///
/// 근본 원인: 일부 Samsung은 레거시 BLE 광고 인스턴스를 **하나만** 지원한다.
/// 웨이크 비콘 토치가 메시보다 먼저 그 슬롯을 잡으면 메시 광고가
/// `ADVERTISE_FAILED_TOO_MANY_ADVERTISERS`(code 2)로 영영 실패해 그 폰이 BLE
/// 스캔에 보이지 않는다. 그런데 토치는 계속 돌아 iPhone을 깨운다 → 알림은 오고
/// 레이더는 빈다. 예전 코드는 code 3(already started)만 걸러내고 code 2는
/// 로그 한 줄로 삼켰다.
///
/// 이 테스트는 복구 분기를 결정하는 **error code 분류**를 고정한다. 분류가
/// 틀리면 슬롯 경합을 놓쳐 토치를 양보시키지 못하고, 증상이 그대로 남는다.
void main() {
  group('광고 실패 error code 분류', () {
    test('벤더 플러그인의 실패 문자열에서 code 2(슬롯 경합)를 되살린다', () {
      final e = StateError(
          'Bad state: Start advertising failed with error code: 2');
      expect(MeshTransport.advertiseErrorCode(e), 2,
          reason: 'code 2를 놓치면 토치를 양보시키지 못해 그 삼성 폰은 '
              '계속 보이지 않는다');
    });

    test('code 3(이미 광고 중)도 숫자로 읽힌다', () {
      final e = Exception('Start advertising failed with error code: 3');
      expect(MeshTransport.advertiseErrorCode(e), 3);
    });

    test('code 1(데이터 초과)·5(미지원)는 경합이 아니다', () {
      expect(
          MeshTransport.advertiseErrorCode(
              Exception('Start advertising failed with error code: 1')),
          1);
      expect(
          MeshTransport.advertiseErrorCode(
              Exception('Start advertising failed with error code: 5')),
          5);
    });

    test('숫자가 없는 실패는 null(경합으로 오판하지 않는다)', () {
      expect(MeshTransport.advertiseErrorCode(Exception('adapter off')), isNull);
      expect(MeshTransport.advertiseErrorCode('unknown failure'), isNull);
    });

    test('공백이 달라도 견딘다', () {
      expect(
          MeshTransport.advertiseErrorCode(
              Exception('Start advertising failed with error code:2')),
          2);
    });
  });
}
