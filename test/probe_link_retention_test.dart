import 'dart:typed_data';

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

  group('Apple probe 후보 필터링 (iBeacon 제외)', () {
    test('iBeacon 프레임(0x02, 0x15)은 non-connectable이므로 probe에서 제외한다', () {
      final iBeacon = Uint8List.fromList([
        0x02, 0x15, // iBeacon prefix
        ...List.filled(16, 0x7A), // UUID
        0x00, 0x00, // major
        0x00, 0x00, // minor
        0xC5, // txPower
      ]);
      expect(
        MeshTransport.isProbeableAppleData(iBeacon),
        isFalse,
        reason:
            'SpotLink 자체 웨이크 토치 및 주변 매장 iBeacon에 probe dial을 걸면 '
            'Android 스캔이 멈추고 8초간 허공에 connectGatt를 낭비한다',
      );
    });

    test('Apple Continuity 프레임(0x10 Nearby Info, 0x01 Overflow 등)은 probe 대상이다', () {
      final continuityNearby = Uint8List.fromList([0x10, 0x05, 0x01, 0x18, 0x00, 0x00, 0x00]);
      final continuityOverflow = Uint8List.fromList([0x01, ...List.filled(16, 0x00)]);
      expect(MeshTransport.isProbeableAppleData(continuityNearby), isTrue);
      expect(MeshTransport.isProbeableAppleData(continuityOverflow), isTrue);
    });
  });

  group('MeshLink GATT 작업 직렬화 (enqueueOp)', () {
    test('동시에 요청된 GATT 비동기 작업들이 겹치지 않고 순서대로 실행된다', () async {
      final link = MeshLink(id: 'C:test', role: LinkRole.central);
      final order = <int>[];
      var inFlight = 0;
      var maxConcurrent = 0;

      Future<int> runOp(int id, int delayMs) => link.enqueueOp(() async {
            inFlight++;
            if (inFlight > maxConcurrent) maxConcurrent = inFlight;
            await Future<void>.delayed(Duration(milliseconds: delayMs));
            order.add(id);
            inFlight--;
            return id;
          });

      final results = await Future.wait([
        runOp(1, 30),
        runOp(2, 10),
        runOp(3, 5),
      ]);

      expect(results, [1, 2, 3]);
      expect(order, [1, 2, 3]);
      expect(
        maxConcurrent,
        1,
        reason:
            'Android BluetoothGatt는 단일 busy 락을 쓰므로 동시 호출 시 '
            'IllegalStateException으로 링크가 절단된다',
      );
    });
  });
}
