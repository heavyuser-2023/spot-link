import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Requests the runtime permissions the mesh node needs.
///
/// On Android 12+ BLE scanning/advertising/connecting each require a dedicated
/// runtime permission, and the foreground-service notification needs
/// POST_NOTIFICATIONS on Android 13+. Without these, BLE silently does nothing
/// — so we must request them before starting the node.
///
/// On iOS the BLE usage prompt is triggered by CoreBluetooth on first use and
/// the camera prompt by the scanner, so there is nothing to pre-request here.
class Permissions {
  /// Requests everything needed. Returns true if the essential BLE permissions
  /// were granted (or aren't required on this platform).
  static Future<bool> request() async {
    if (!Platform.isAndroid) return true;

    // Request the BLE trio + notifications together. locationWhenInUse is only
    // needed for scanning on Android <= 11; requesting it there is harmless.
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.notification,
      Permission.locationWhenInUse,
    ].request();

    // Essential = the three BLE permissions. Notification/location are
    // best-effort (older/newer OS versions vary).
    bool ok(Permission p) {
      final s = results[p];
      return s == null || s.isGranted || s.isLimited;
    }

    return ok(Permission.bluetoothScan) &&
        ok(Permission.bluetoothAdvertise) &&
        ok(Permission.bluetoothConnect);
  }

  /// Whether the essential BLE permissions are currently granted, without
  /// prompting.
  static Future<bool> hasBleGranted() async {
    if (!Platform.isAndroid) return true;
    return await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted &&
        await Permission.bluetoothAdvertise.isGranted;
  }
}
