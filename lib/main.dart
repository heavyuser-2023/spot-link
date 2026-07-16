import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app/bootstrap.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // foreground-service(headless mesh) isolate로부터 오는 메시지를 받는 포트 —
  // 어떤 ping/핸드오프라도 우리에게 도달하기 전에 존재해야 한다.
  FlutterForegroundTask.initCommunicationPort();
  // Flutter의 기본값(이미지 1000개 / 100MB)은 이미지가 많은 앱에 맞춰져 있다;
  // 채팅은 썸네일 몇 개만 보여준다. 작은 캐시는 서스펜드 상태의 점유량을 낮게
  // 유지한다 — 붙들고 있는 1MB 하나하나가 iOS에서 jetsam의 먹잇감이다.
  PaintingBinding.instance.imageCache.maximumSize = 50;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 << 20; // 32MB
  runApp(const SpotLinkApp());
}

class SpotLinkApp extends StatelessWidget {
  const SpotLinkApp({super.key});

  // 정제된 인디고: 이전과 같은 브랜드 계열이되, 강렬한 A200 톤에서 한 발 물러나
  // 더 깊고 차분한 강조색으로, 큰 면적(버튼, 칩, 말풍선)에서 "기본 원색"보다는
  // 프리미엄하게 읽힌다.
  static const _seed = Color(0xFF4457D6);

  /// 플랫폼 기본값 위에 의도적으로 얹은 타입 스케일: display/headline은 더 촘촘한
  /// 자간과 행간으로 정교하고 자신감 있는 느낌을 주고; 본문은 한국어 가독성을 위해
  /// 넉넉한 1.4 행간을 갖는다.
  TextTheme _text(TextTheme base) => base.copyWith(
        headlineLarge: base.headlineLarge
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5, height: 1.12),
        headlineMedium: base.headlineMedium
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4, height: 1.15),
        headlineSmall: base.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3, height: 1.2),
        titleLarge: base.titleLarge
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        bodyLarge: base.bodyLarge?.copyWith(height: 1.4),
        bodyMedium: base.bodyMedium?.copyWith(height: 1.4),
        labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      );

  /// 앱 전체의 룩을 한곳에 모은다: 둥근 표면, 채워진 입력 필드, 평평한 그림자 —
  /// 모든 화면과 두 밝기 모드에 걸쳐 일관된다.
  ThemeData _theme(Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    return base.copyWith(
      textTheme: _text(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        backgroundColor: scheme.surface,
        showDragHandle: true,
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme:
          const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SpotLink',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      // 텍스트 필드 바깥 아무 곳이나 탭하면 키보드가 닫힌다. 이것이 없으면, 닫힌
      // 다이얼로그/라우트를 넘어 살아남은 포커스가 탭 바를 가리는 고아 키보드를
      // 남기고 — 그 화면을 빠져나갈 방법이 전혀 없게 된다.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
      home: const Bootstrap(),
    );
  }
}
