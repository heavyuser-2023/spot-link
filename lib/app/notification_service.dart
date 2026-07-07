import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Shows local notifications for incoming messages/files while the app is not
/// in the foreground (e.g. screen off / backgrounded). The Android foreground
/// service keeps the process alive so these can fire; on iOS the background BLE
/// modes do the same.
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _channelId = 'spotlink_messages';
  static const _channelName = '메시지';
  static const _channelDesc = '새 메시지와 파일 도착 알림';

  static Future<void> init() async {
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: darwin),
    );

    // Create the Android channel up front so the first notification isn't
    // silently dropped.
    final android2 = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android2?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.high,
    ));
    // Ask for POST_NOTIFICATIONS on Android 13+ (no-op on older). Best-effort:
    // in the foreground-service isolate there is no Activity and the plugin
    // NPEs — the UI isolate has already asked, and showing notifications only
    // needs the grant, not the request.
    try {
      await android2?.requestNotificationsPermission();
    } catch (_) {}
    _ready = true;
  }

  /// Notification id derived from a conversation key so messages from the same
  /// peer collapse onto one entry instead of stacking endlessly.
  static int _idFor(String key) => key.hashCode & 0x7fffffff;

  static Future<void> showMessage({
    required String conversationKey,
    required String title,
    required String body,
  }) async {
    if (!_ready) {
      // Never let a notification failure crash the receive path.
      try {
        await init();
      } catch (_) {
        return;
      }
    }
    const android = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
    );
    const darwin = DarwinNotificationDetails();
    try {
      await _plugin.show(
        id: _idFor(conversationKey),
        title: title,
        body: body,
        notificationDetails:
            const NotificationDetails(android: android, iOS: darwin),
      );
    } catch (_) {
      // Ignore: notifications are best-effort, especially on desktop/test.
    }
  }

  static Future<void> cancelFor(String conversationKey) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: _idFor(conversationKey));
    } catch (_) {}
  }

  static bool get supported => Platform.isAndroid || Platform.isIOS;
}
