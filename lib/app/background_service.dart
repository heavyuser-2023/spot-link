import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the SpotLink mesh node alive while the app is backgrounded (Android).
///
/// On Android a foreground service with a persistent notification is required
/// for continuous BLE scanning/advertising once the app leaves the foreground.
/// On iOS the OS manages `bluetooth-central`/`bluetooth-peripheral` background
/// modes itself (declared in Info.plist) — there is no equivalent user-visible
/// service, and reachability is best-effort while backgrounded. See
/// docs/ARCHITECTURE.md §11.
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
        autoRunOnBoot: false,
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
}
