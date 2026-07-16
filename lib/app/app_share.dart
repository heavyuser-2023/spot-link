import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 오프라인 자가 배포(Android 전용): 설치된 자체 APK를 가져와, 앱 스토어도
/// 인터넷도 없이 다음 사람에게 건넬 수 있게 한다 — 시스템 공유 시트
/// (Quick Share/Bluetooth/…) 또는 SpotLink 파일 전송을 통해. iOS는 사이드로드가
/// 불가능하므로 여기서는 null을 반환한다.
class AppShare {
  static const _channel = MethodChannel('spotlink/app');

  static const apkMime = 'application/vnd.android.package-archive';
  static const apkName = 'SpotLink.apk';

  /// 설치된 APK를 알아보기 쉬운 이름으로 캐시에 복사한다.
  /// 지원되지 않거나(iOS/데스크톱) 실패한 경우 null을 반환한다.
  static Future<File?> apkFile() async {
    if (!Platform.isAndroid) return null;
    try {
      final src = await _channel.invokeMethod<String>('apkPath');
      if (src == null) return null;
      final dir = await getTemporaryDirectory();
      final out = File('${dir.path}/$apkName');
      await File(src).copy(out.path);
      return out;
    } catch (_) {
      return null;
    }
  }
}
