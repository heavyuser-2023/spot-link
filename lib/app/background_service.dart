import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../l10n/l10n.dart';
import 'headless_mesh.dart';

/// 유일무이한 메시 노드를 소유(OWN)하는 Android 포그라운드 서비스.
///
/// 단일 소유자 아키텍처(v1.4.0): 메시(BLE 스택, 영속화, 알림)는 UI가 열려
/// 있든 아니든 항상(ALWAYS) 서비스의 task isolate에서 실행된다. UI isolate는
/// task 메시지 포트([RemoteMeshController])를 통해 얇은 클라이언트로 붙을 뿐,
/// 자신이 직접 BLE를 건드리지 않는다. 이것이 스와이프킬 생존을 안전하게
/// 만드는 요소다: 메시의 isolate는 액티비티와 함께 죽는 일이 없으므로, 소유권
/// 이양도 없고 두 BLE 스택(→ 중복 GATT 서버)이 공존할 수 있는 틈도 없다.
/// 이전의 모든 두-메시 조율 방식(ping/pong, 파일/prefs 하트비트, 자가 양보)은
/// 결국 경쟁 상태를 일으켰다 — headless_mesh.dart의 이력 참고.
///
/// iOS에는 이에 상응하는 서비스가 없다: UI isolate가 로컬 [MeshController]를
/// 실행하고, OS의 bluetooth 백그라운드 모드가 최선을 다해(best-effort) 이를
/// 살려 둔다. 사용자가 종료한 앱은 되살릴 수 없다(플랫폼 정책).
class BackgroundService {
  static bool get _supported => Platform.isAndroid;

  static Future<void> init() async {
    if (!_supported) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'spotlink_mesh',
        channelName: 'SpotLink Mesh',
        channelDescription:
            'Keeps you reachable and relays messages for others nearby.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        // 재부팅/앱 업데이트/스와이프킬 후에도 서비스가 스스로 떠서 메시를
        // 돌린다 — 화면을 한 번도 안 열어도 이 기기는 릴레이 노드로 산다.
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  static Future<void> start() async {
    if (!_supported) return;
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: systemS.fgsTitle,
      notificationText: systemS.fgsSearching,
      callback: headlessMeshMain,
    );
  }

  static Future<void> stop() async {
    if (!_supported) return;
    await FlutterForegroundTask.stopService();
  }

  /// 서비스 task isolate를 **무조건 새로 태어나게** 한다.
  ///
  /// [start]는 `isRunningService`면 no-op이다 — 그런데 그 "실행 중"은 Java
  /// 서비스 껍데기 기준이라, Dart isolate가 죽은 좀비 서비스도 실행 중으로
  /// 보인다. 그 상태에서는 앱(UI)을 아무리 다시 열어도 메시가 살아나지
  /// 않았다(2026-07-30 확진: 사용자가 기기 옆에서 앱을 열었는데도 SpotLink
  /// 광고 0건 — start는 no-op, hello는 죽은 isolate로 발사). 이것이 그
  /// 회생 경로다: 실행 중이면 restart(기존 isolate 파기 + 새 isolate),
  /// 아니면 start.
  static Future<void> restart() async {
    if (!_supported) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await start();
    }
  }

  /// UI → 서비스 명령(JSON 문자열). 발사 후 망각(fire-and-forget): 결과는 역방향
  /// 포트에서 상태 스냅샷으로 돌아온다.
  static void sendToService(String json) {
    if (!_supported) return;
    try {
      FlutterForegroundTask.sendDataToTask(json);
    } catch (_) {}
  }

  /// 링크 수를 상시 알림(persistent notification)에 반영하기 위해 서비스(SERVICE)
  /// isolate에서 호출된다.
  static Future<void> updateStatus(int linkCount) async {
    if (!_supported) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: systemS.fgsTitle,
      notificationText: linkCount > 0
          ? systemS.fgsConnected(linkCount)
          : systemS.fgsSearching,
    );
  }

  // ---- 배터리 최적화 (Samsung 등 OEM 킬러 대응) ----

  /// Android가 배터리를 이유로 서비스를 죽이지 않을 때(또는 플랫폼에 그러한
  /// 개념 자체가 없을 때, 예: iOS) true.
  static Future<bool> get isIgnoringBatteryOptimizations async {
    if (!_supported) return true;
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      return true;
    }
  }

  /// SpotLink를 배터리 최적화에서 제외해 달라고 사용자에게 요청하는 시스템
  /// 다이얼로그를 띄운다 — 이것이 없으면 OEM들이 얼마 뒤 릴레이를 조용히 죽인다.
  static Future<void> requestIgnoreBatteryOptimization() async {
    if (!_supported) return;
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {}
  }
}
