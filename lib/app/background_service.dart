import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'headless_mesh.dart';

/// Keeps the SpotLink mesh node alive while the app is backgrounded (Android).
///
/// On Android a foreground service with a persistent notification is required
/// for continuous BLE scanning/advertising once the app leaves the foreground.
/// The service also survives the user swiping the app away and — with
/// [headlessMeshMain] as its entry point — restarts the mesh HEADLESSLY after
/// a reboot, an app update, or an OEM battery-manager kill, so this device
/// keeps receiving and relaying messages with no UI at all.
///
/// On iOS the OS manages `bluetooth-central`/`bluetooth-peripheral` background
/// modes itself (declared in Info.plist) — there is no equivalent service, a
/// user-terminated app cannot be revived (platform policy), and reachability
/// is best-effort while backgrounded. See docs/ARCHITECTURE.md §11.
class BackgroundService {
  static bool get _supported => Platform.isAndroid;

  // ---- messages exchanged with the headless isolate (headless_mesh.dart) --
  static const msgPing = 'spotlink.ping';
  static const msgPong = 'spotlink.pong';
  static const msgUiTakeover = 'spotlink.uiTakeover';
  static const msgHeadlessStopped = 'spotlink.headlessStopped';

  static bool _uiMeshActive = false;
  static bool _portWired = false;
  static Completer<void>? _headlessStopped;

  static Future<void> init() async {
    if (!_supported) return;
    _wirePort();
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
        // 재부팅/앱 업데이트 후에도 서비스가 스스로 떠서 헤드리스 메시를
        // 돌린다 — 화면을 한 번도 안 열어도 이 기기는 릴레이 노드로 산다.
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        // 스와이프 종료(onTaskRemoved) 후 서비스 자동 재시작.
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Listen for messages from the headless isolate (main-isolate side).
  static void _wirePort() {
    if (_portWired) return;
    _portWired = true;
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  static void _onTaskData(Object data) {
    if (data == msgPing) {
      // The headless isolate asks "is a UI mesh alive?" before starting its
      // own — answer only when ours is actually running.
      if (_uiMeshActive) FlutterForegroundTask.sendDataToTask(msgPong);
    } else if (data == msgHeadlessStopped) {
      final c = _headlessStopped;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  /// Whether the UI-side mesh node is running (drives the pong above).
  static void setUiMeshActive(bool active) {
    if (_supported) _uiMeshActive = active;
  }

  // ---- UI-alive heartbeat (cross-isolate) ---------------------------------
  // The 1-second ping/pong can miss (isolate port timing) and a plain file is
  // unreliable across isolates (the background FlutterEngine can resolve a
  // different support dir), which let the headless service run a SECOND mesh
  // while the UI mesh was already up — two BLE stacks → two GATT servers →
  // iOS connects fail. flutter_foreground_task's saveData/getData is
  // SharedPreferences-backed and GUARANTEED shared between the main and task
  // isolates, so it is the correct substrate for this handshake.
  static const _hbKey = 'spotlink.ui_mesh_hb_ms';

  /// UI writes this periodically while its mesh runs.
  static Future<void> markUiMeshHeartbeat() async {
    if (!_supported) return;
    try {
      await FlutterForegroundTask.saveData(
          key: _hbKey, value: DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<void> clearUiMeshHeartbeat() async {
    if (!_supported) return;
    try {
      await FlutterForegroundTask.saveData(key: _hbKey, value: 0);
    } catch (_) {}
  }

  /// Headless side: true if the UI mesh touched the heartbeat within [within].
  static Future<bool> uiMeshHeartbeatFresh(
      {Duration within = const Duration(seconds: 25)}) async {
    if (!_supported) return false;
    try {
      final ts = await FlutterForegroundTask.getData<int>(key: _hbKey) ?? 0;
      return DateTime.now().millisecondsSinceEpoch - ts < within.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  /// Called by the UI before starting its own mesh: if a headless mesh is
  /// running in the service isolate, stop it and wait for the hand-off —
  /// two BLE stacks announcing the same identity would collide.
  static Future<void> claimMeshOwnership() async {
    // No-op since v1.3.6: the headless isolate no longer runs a mesh (see
    // headless_mesh.dart), so there is nothing to take over. Kept as a stub
    // so callers don't change; avoids the old 2s handshake timeout on every
    // UI start.
  }

  static Future<void> start() async {
    if (!_supported) return;
    _wirePort();
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'SpotLink is active',
      notificationText: 'Discovering people and relaying messages nearby.',
      // System restarts (boot / swipe-kill / OEM kill) enter here and run
      // the mesh headlessly; when the UI started us it stays dormant.
      callback: headlessMeshMain,
    );
  }

  static Future<void> stop() async {
    if (!_supported) return;
    await FlutterForegroundTask.stopService();
  }

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
