import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 앱이 포그라운드에 있지 않을 때(예: 화면 꺼짐 / 백그라운드) 수신 메시지/파일에
/// 대한 로컬 알림을 표시한다. Android 포그라운드 서비스가 프로세스를 살려 두어
/// 이 알림들이 발생할 수 있게 하고, iOS에서는 백그라운드 BLE 모드가 같은 역할을
/// 한다.
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

    // 첫 알림이 조용히 버려지지 않도록 Android 채널을 미리 생성한다.
    final android2 = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android2?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.high,
    ));
    // Android 13+에서 POST_NOTIFICATIONS를 요청한다(이전 버전에서는 no-op).
    // 최선의 노력(best-effort): 포그라운드 서비스 isolate에는 Activity가 없어
    // 플러그인이 NPE를 낸다 — UI isolate가 이미 요청했고, 알림을 표시하는 데는
    // 요청이 아니라 권한만 있으면 된다.
    try {
      await android2?.requestNotificationsPermission();
    } catch (_) {}
    _ready = true;
  }

  /// 같은 피어의 메시지가 끝없이 쌓이는 대신 하나의 항목으로 합쳐지도록, 대화
  /// 키에서 파생한 알림 id.
  static int _idFor(String key) => key.hashCode & 0x7fffffff;

  static Future<void> showMessage({
    required String conversationKey,
    required String title,
    required String body,
  }) async {
    if (!_ready) {
      // 알림 실패가 수신 경로를 크래시시키는 일은 절대 없게 한다.
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
      // 무시: 알림은 최선의 노력(best-effort)일 뿐이며, 특히 데스크톱/테스트에서 그렇다.
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
