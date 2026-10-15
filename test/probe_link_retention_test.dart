import 'package:flutter_test/flutter_test.dart';

import 'package:spot_link/core/ble/mesh_transport.dart';

/// 2026-10-16 신고: "안드로이드 삼성 폰에서 iOS 친구가 안 나오고 메시지를
/// 주고받지 못한다."
///
/// heavy(iPhone) 로그(2026-10-06 사무실)에서 삼성이 매번 새 주소로 heavy의
/// GATT에 붙어 구독까지 마친 뒤 ~3초 만에 끊는 패턴이 15회 넘게 반복됐다
/// (`link up P:<새 id>` → `central not subscribed — dropping half-open link`).
/// 백그라운드 iPhone은 광고에 SpotLink 표식이 없어서, Android는 근처 Apple
/// 기기에 probe 연결을 걸어 GATT로 판정하는 길밖에 없다. 그런데 probe 정리가
/// 성공·실패를 가리지 않고 연결을 끊어, **SpotLink iPhone을 찾아 링크를 올린
/// 바로 그 순간 끊고 있었다**. 이 판단을 고정한다.
void main() {
  group('probe 연결 정리', () {
    test('링크가 성립한 probe는 끊지 않는다', () {
      expect(
        MeshTransport.releasesProbeConnection(linked: true),
        isFalse,
        reason:
            '끊으면 Android가 백그라운드 iPhone과 링크를 유지할 길이 '
            '사라진다 — 붙자마자 끊고 다시 probe하는 루프가 된다',
      );
    });

    test('실패·타임아웃한 probe는 GATT 클라이언트 슬롯을 회수한다', () {
      expect(
        MeshTransport.releasesProbeConnection(linked: false),
        isTrue,
        reason:
            '타임아웃한 connectGatt를 남기면 Android GATT 클라이언트 '
            '풀이 고갈된다(2026-07-07 v1.2.7)',
      );
    });
  });
}
