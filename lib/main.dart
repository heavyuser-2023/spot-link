import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app/bootstrap.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Receive port for messages from the foreground-service (headless mesh)
  // isolate — must exist before any ping/handoff can reach us.
  FlutterForegroundTask.initCommunicationPort();
  // Flutter's defaults (1000 images / 100MB) are sized for image-heavy apps;
  // a chat shows a handful of thumbnails. A small cache keeps our suspended
  // footprint low — every retained MB is jetsam bait on iOS.
  PaintingBinding.instance.imageCache.maximumSize = 50;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 << 20; // 32MB
  runApp(const SpotLinkApp());
}

class SpotLinkApp extends StatelessWidget {
  const SpotLinkApp({super.key});

  // Refined indigo: the same brand family as before, dialed back from the
  // electric A200 tone to a deeper, calmer accent that reads as premium
  // rather than "default vivid" across large fills (buttons, chips, bubbles).
  static const _seed = Color(0xFF4457D6);

  /// A deliberate type scale layered on the platform default: display/headline
  /// weights get tighter tracking and line-height for a crafted, confident
  /// feel; body copy gets a comfortable 1.4 line-height for Korean legibility.
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

  /// One place for the app-wide look: rounded surfaces, filled inputs,
  /// flat elevation — consistent across every screen and both brightnesses.
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
      // Tapping anywhere outside a text field dismisses the keyboard. Without
      // this, focus surviving a closed dialog/route leaves an orphaned
      // keyboard covering the tab bar — with no way to escape the screen.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
      home: const Bootstrap(),
    );
  }
}
