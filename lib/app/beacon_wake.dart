import 'package:flutter/services.dart';

/// Bridge to the native SpotLink wake-beacon (see ios/Runner/BeaconPlugin.swift
/// and android/.../BeaconPlugin.kt).
///
/// - TX: broadcast the fixed SpotLink iBeacon so nearby iPhones that were
///   swipe-killed (or never ran since reboot) get relaunched by CoreLocation.
///   Android transmits in the background; iOS only while foregrounded.
/// - RX (iOS only): monitor that beacon region — requires the "always"
///   location permission the user grants once.
///
/// Every call is defensive: platforms without the native handler (tests,
/// desktop) just no-op.
class BeaconWake {
  static const _channel = MethodChannel('spotlink/beacon');

  static Future<void> startTx() async {
    try {
      await _channel.invokeMethod('startTx');
    } catch (_) {}
  }

  static Future<void> stopTx() async {
    try {
      await _channel.invokeMethod('stopTx');
    } catch (_) {}
  }

  static Future<void> requestAlways() async {
    try {
      await _channel.invokeMethod('requestAlways');
    } catch (_) {}
  }

  static Future<bool> enableMonitoring() async {
    try {
      return await _channel.invokeMethod<bool>('enableMonitoring') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> disableMonitoring() async {
    try {
      await _channel.invokeMethod('disableMonitoring');
    } catch (_) {}
  }

  /// {'auth': 'always'|'whenInUse'|'denied'|'notDetermined',
  ///  'monitoring': bool}
  static Future<Map<Object?, Object?>> status() async {
    try {
      return await _channel.invokeMethod<Map<Object?, Object?>>('status') ??
          const {};
    } catch (_) {
      return const {};
    }
  }
}
