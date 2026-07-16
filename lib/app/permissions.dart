import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// 메시 노드에 필요한 런타임 권한을 요청한다.
///
/// Android 12+에서는 BLE 스캔/광고/연결이 각각 전용 런타임 권한을 필요로 하고,
/// 포그라운드 서비스 알림은 Android 13+에서 POST_NOTIFICATIONS를 필요로 한다.
/// 이것들이 없으면 BLE는 조용히 아무 일도 하지 않는다 — 그래서 노드를 시작하기
/// 전에 반드시 요청해야 한다.
///
/// iOS에서는 BLE 사용 프롬프트가 첫 사용 시 CoreBluetooth에 의해, 카메라
/// 프롬프트가 스캐너에 의해 트리거되므로, 여기서 미리 요청할 것이 없다.
class Permissions {
  /// 필요한 모든 것을 요청한다. 필수 BLE 권한이 부여됐다면(또는 이 플랫폼에서
  /// 필요하지 않다면) true를 반환한다.
  static Future<bool> request() async {
    if (!Platform.isAndroid) return true;

    // BLE 3종 세트 + 알림을 함께 요청한다. locationWhenInUse는 Android 11
    // 이하에서 스캔에만 필요하며, 거기서 요청해도 해롭지 않다.
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.notification,
      Permission.locationWhenInUse,
    ].request();

    // 필수 = BLE 권한 3종. 알림/위치는 최선의 노력(best-effort)이다(구/신 OS
    // 버전에 따라 다름).
    bool ok(Permission p) {
      final s = results[p];
      return s == null || s.isGranted || s.isLimited;
    }

    return ok(Permission.bluetoothScan) &&
        ok(Permission.bluetoothAdvertise) &&
        ok(Permission.bluetoothConnect);
  }

  /// 프롬프트를 띄우지 않고, 필수 BLE 권한이 현재 부여돼 있는지 여부.
  static Future<bool> hasBleGranted() async {
    if (!Platform.isAndroid) return true;
    return await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted &&
        await Permission.bluetoothAdvertise.isGranted;
  }
}
