import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'headless_mesh.dart';

/// The Android foreground service that OWNS the one and only mesh node.
///
/// Single-owner architecture (v1.4.0): the mesh (BLE stacks, persistence,
/// notifications) runs in the service's task isolate — ALWAYS, whether or not
/// the UI is open. The UI isolate attaches as a thin client over the task
/// message port ([RemoteMeshController]) and never touches BLE itself. This
/// is what makes swipe-kill survival safe: the mesh's isolate never dies with
/// the activity, so there is no ownership handoff and no window where two
/// BLE stacks (→ duplicate GATT servers) can coexist. Every previous
/// two-mesh coordination scheme (ping/pong, file/prefs heartbeats,
/// self-yield) raced eventually — see headless_mesh.dart history.
///
/// On iOS there is no equivalent service: the UI isolate runs a local
/// [MeshController] and the OS's bluetooth background modes keep it alive
/// best-effort. A user-terminated app cannot be revived (platform policy).
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
      notificationTitle: 'SpotLink is active',
      notificationText: 'Discovering people and relaying messages nearby.',
      callback: headlessMeshMain,
    );
  }

  static Future<void> stop() async {
    if (!_supported) return;
    await FlutterForegroundTask.stopService();
  }

  /// UI → service command (JSON string). Fire-and-forget: results come back
  /// as state snapshots on the reverse port.
  static void sendToService(String json) {
    if (!_supported) return;
    try {
      FlutterForegroundTask.sendDataToTask(json);
    } catch (_) {}
  }

  /// Called from the SERVICE isolate to reflect link count on the persistent
  /// notification.
  static Future<void> updateStatus(int linkCount) async {
    if (!_supported) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'SpotLink is active',
      notificationText: linkCount > 0
          ? 'Connected to $linkCount nearby device(s).'
          : 'Searching for people nearby…',
    );
  }

  // ---- battery optimization (Samsung 등 OEM 킬러 대응) ----

  /// True when Android won't kill our service for battery reasons (or when
  /// the platform has no such concept, e.g. iOS).
  static Future<bool> get isIgnoringBatteryOptimizations async {
    if (!_supported) return true;
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      return true;
    }
  }

  /// Shows the system dialog asking the user to exempt SpotLink from battery
  /// optimization — without this, OEMs silently kill the relay after a while.
  static Future<void> requestIgnoreBatteryOptimization() async {
    if (!_supported) return;
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {}
  }
}
