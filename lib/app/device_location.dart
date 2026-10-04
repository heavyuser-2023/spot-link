import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 위치 한 점.
class LocationFix {
  final double lat;
  final double lng;

  /// 정확도(미터). 플랫폼이 알려주지 않으면 null.
  final double? accuracy;
  const LocationFix(this.lat, this.lng, [this.accuracy]);
}

/// 네이티브 `spotlink/location` 채널(iOS BeaconPlugin.swift / Android
/// LocationPlugin.kt)로의 다리. 스쳐간 친구가 **어디서** 지나갔는지를 남기는
/// 데만 쓴다. 좌표는 이 기기에만 저장된다 — 단 [reverseGeocode]는 장소 이름을
/// 얻으려고 좌표를 OS 지도 서비스(iOS는 Apple, Android는 대개 Google)에 보낸다.
/// 사용자 문구·개인정보처리방침도 이 사실을 그대로 밝힌다.
///
/// 모든 호출은 실패를 null로 돌려준다: 권한 없음·위치 서비스 꺼짐·오프라인·
/// 핸들러 없는 플랫폼(테스트, 데스크톱) 어디서든 만남 기록 자체는 위치 없이
/// 계속돼야 한다.
class DeviceLocation {
  static const _channel = MethodChannel('spotlink/location');

  static Future<LocationFix?> current({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>(
        'currentLocation',
        {'timeoutMs': timeout.inMilliseconds},
      );
      if (m == null) return null;
      final lat = (m['lat'] as num?)?.toDouble();
      final lng = (m['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      return LocationFix(lat, lng, (m['accuracy'] as num?)?.toDouble());
    } catch (_) {
      return null;
    }
  }

  /// 좌표를 사람이 읽는 장소 이름으로. 네트워크가 필요해서 오프라인이면 null —
  /// 그 경우 좌표만 보여주고, 다음에 온라인일 때 다시 시도한다.
  static Future<String?> reverseGeocode(double lat, double lng) async {
    try {
      final s = await _channel.invokeMethod<String>('reverseGeocode', {
        'lat': lat,
        'lng': lng,
      });
      return (s == null || s.trim().isEmpty) ? null : s.trim();
    } catch (_) {
      return null;
    }
  }
}

/// 만남 기록의 사용자 설정. 앱 데이터 폴더의 플래그 파일이라 Android의 두
/// isolate(서비스=기록 주체, UI=설정 화면)가 브리지 없이 같은 값을 읽는다.
///
/// 위치 기록은 **기본 켜짐**이다(사용자 결정, 2026-10-04) — 그래서 "꺼짐"
/// 표식이 있을 때만 끈다.
class EncounterSettings {
  static const _offFlag = 'encounter_location_off';

  static Future<File> _file() async =>
      File(p.join((await AppPaths.dataDir()).path, _offFlag));

  static Future<bool> locationEnabled() async {
    try {
      return !(await _file()).existsSync();
    } catch (_) {
      return true; // 저장소 문제 — 기본값을 따른다
    }
  }

  static Future<void> setLocationEnabled(bool on) async {
    try {
      final f = await _file();
      if (on) {
        if (f.existsSync()) f.deleteSync();
      } else {
        f.writeAsStringSync('1');
      }
    } catch (_) {}
  }
}
