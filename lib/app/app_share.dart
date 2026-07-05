import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Offline self-distribution (Android only): grab our own installed APK so it
/// can be handed to the next person with no app store and no internet —
/// via the system share sheet (Quick Share/Bluetooth/…) or as a SpotLink
/// file transfer. iOS cannot sideload, so this returns null there.
class AppShare {
  static const _channel = MethodChannel('spotlink/app');

  static const apkMime = 'application/vnd.android.package-archive';
  static const apkName = 'SpotLink.apk';

  /// Copy the installed APK into our cache under a friendly name.
  /// Returns null when unsupported (iOS/desktop) or on any failure.
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
