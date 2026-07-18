import 'dart:convert';
import 'dart:math';

import 'package:fluttermoji/fluttermoji_assets/fluttermojimodel.dart';

/// 파츠 아바타 레시피 코덱.
///
/// fluttermoji(Avataaars 파츠 세트)의 선택값은 13개 속성의 정수 맵인데,
/// JSON 그대로는 ~200바이트라 15초마다 나가는 ANNOUNCE에 싣기엔 낭비다.
/// 속성 순서를 고정해 `FM1:4,0,1,0,1,4,0,0,1,0,1,0,0` 형태(~30바이트)로
/// 압축한다. 전송되는 것은 이 레시피뿐이고, 렌더링은 각 기기에 내장된
/// 파츠 자산이 한다 — 이미지는 무선을 절대 타지 않는다.
///
/// 호환 규칙: 접두사(`FM1`)가 낯설거나 값이 파싱되지 않으면 null을 돌려
/// 이니셜 아바타로 우아하게 강등된다. 파츠 세트가 커지면 FM2로 버전을
/// 올린다(FM1 수신은 계속 지원).
abstract final class AvatarCodec {
  static const _prefix = 'FM1:';

  /// fluttermoji 속성의 고정 순서. 절대 순서를 바꾸거나 삭제하지 말 것 —
  /// 와이어 형식이다(추가만 허용).
  static const keys = [
    'topType',
    'accessoriesType',
    'hairColor',
    'facialHairType',
    'facialHairColor',
    'clotheType',
    'eyeType',
    'eyebrowType',
    'mouthType',
    'skinColor',
    'clotheColor',
    'style',
    'graphicType',
  ];

  /// fluttermoji JSON(속성 맵) → compact 레시피.
  static String? compactFromJson(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final map = (jsonDecode(json) as Map).cast<String, dynamic>();
      final values = [for (final k in keys) (map[k] as num?)?.toInt() ?? 0];
      return '$_prefix${values.join(',')}';
    } catch (_) {
      return null;
    }
  }

  /// 무작위 기본 아바타 레시피. 첫 부팅에 모두가 캐릭터를 갖고 시작하도록 —
  /// 이니셜 "김"보다 레이더가 첫날부터 생동감 있고, 커스텀 유도의 출발점이
  /// 된다. 스타일(원형 배경)은 고정하고 나머지 파츠를 굴린다.
  static String randomCompact({Random? rng}) {
    final r = rng ?? Random.secure();
    final map = <String, int>{};
    for (final k in keys) {
      if (k == 'style') {
        map[k] = 0;
        continue;
      }
      final count = fluttermojiProperties[k]?.property?.length ?? 1;
      map[k] = r.nextInt(count);
    }
    return compactFromJson(jsonEncode(map))!;
  }

  /// compact 레시피 → fluttermoji JSON. 형식이 낯설면 null(이니셜 강등).
  static String? jsonFromCompact(String? compact) {
    if (compact == null || !compact.startsWith(_prefix)) return null;
    try {
      final parts = compact.substring(_prefix.length).split(',');
      if (parts.length < keys.length) return null;
      final map = <String, int>{};
      for (var i = 0; i < keys.length; i++) {
        final v = int.parse(parts[i]);
        if (v < 0 || v > 200) return null; // 정신 나간 값 방어
        map[keys[i]] = v;
      }
      return jsonEncode(map);
    } catch (_) {
      return null;
    }
  }
}
