import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'gen/s.dart';

export 'gen/s.dart';

/// 위젯 어디서나 `context.s.키이름` 한 줄로 현재 로케일 문자열에 접근한다.
extension SX on BuildContext {
  S get s => S.of(this);
}

/// 위젯 컨텍스트가 없는 곳(로컬 알림, 서비스 isolate의 컨트롤러)용:
/// 시스템 로케일을 지원 목록과 대조해 최적 매치를 고르고, 없으면 영어로
/// 폴백한다(en이 목록의 첫 항목이자 템플릿).
S get systemS {
  final locale = basicLocaleListResolution(
    PlatformDispatcher.instance.locales,
    S.supportedLocales,
  );
  return lookupS(locale);
}
