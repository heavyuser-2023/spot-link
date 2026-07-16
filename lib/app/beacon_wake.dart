import 'package:flutter/services.dart';

/// 네이티브 SpotLink 웨이크 비콘으로의 브리지(ios/Runner/BeaconPlugin.swift
/// 및 android/.../BeaconPlugin.kt 참고).
///
/// - TX: 고정된 SpotLink iBeacon을 브로드캐스트하여, 스와이프킬됐거나(또는
///   재부팅 이후 한 번도 실행되지 않은) 근처의 iPhone이 CoreLocation에 의해
///   다시 실행되도록 한다. Android는 백그라운드에서 송신하고, iOS는
///   포그라운드일 때만 송신한다.
/// - RX (iOS 전용): 해당 비콘 영역을 모니터링한다 — 사용자가 한 번 부여하는
///   "always" 위치 권한이 필요하다.
///
/// 모든 호출은 방어적이다: 네이티브 핸들러가 없는 플랫폼(테스트, 데스크톱)에서는
/// 그냥 아무 동작도 하지 않는다(no-op).
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

  /// 진단용: 네이티브에서 기록한 최근 웨이크 원인 이벤트(iBeacon 영역 진입 대
  /// BLE 상태 복원), 각 항목은 `"<reason> <ISO8601>"` 형식. 네이티브 쪽에서
  /// 최근 12개로 제한된다. iOS 전용이며, 그 외에서는 빈 값이다.
  static Future<List<String>> wakeEvents() async {
    try {
      final list = await _channel.invokeMethod<List<Object?>>('wakeEvents');
      return list?.cast<String>() ?? const [];
    } catch (_) {
      return const [];
    }
  }
}
