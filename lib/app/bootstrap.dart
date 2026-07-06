import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../core/ble/mesh_transport.dart' show bleLogSink;
import '../data/app_database.dart';
import '../data/identity_store.dart';
import '../features/home_screen.dart';
import '../features/onboarding_screen.dart';
import 'background_service.dart';
import 'mesh_controller.dart';
import 'notification_service.dart';
import 'permissions.dart';

/// Runs one-time async startup behind a branded splash so the app never shows
/// a blank launch screen, then routes to onboarding (first run) or home.
class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

enum _Stage { loading, onboarding, ready }

class _BootstrapState extends State<Bootstrap> {
  _Stage _stage = _Stage.loading;
  MeshController? _controller;
  final _identityStore = IdentityStore();

  /// Last boot failure, rendered on the splash — turns an opaque endless
  /// spinner into a readable diagnosis on any phone.
  String? _bootError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await initializeDateFormatting('ko', null);
    await _wireBleFileLog();

    // First run (no name yet): show onboarding BEFORE requesting OS
    // permissions. Otherwise the permission dialogs stack over the splash,
    // hide the onboarding screen, and the app looks frozen on "로딩 중" —
    // and since the mesh only starts after a name is set, the phone never
    // advertises or scans (appears online but undiscoverable). Permissions
    // are requested from [_onNameChosen] instead.
    final stored = await _identityStore.storedName();
    if (stored == null || stored.trim().isEmpty) {
      if (mounted) setState(() => _stage = _Stage.onboarding);
      return;
    }

    // Returning user: bring services + permissions up, then launch.
    await _step('알림 준비', () async {
      await BackgroundService.init();
      await NotificationService.init();
    });
    await _step(
        '권한 요청',
        () => Permissions.request()
            .timeout(const Duration(seconds: 45), onTimeout: () => false));
    await _startMesh(stored);
  }

  /// Run one boot step, surfacing failures on the splash instead of dying
  /// silently — a frozen "로딩 중" screen with no reason is undebuggable on
  /// someone else's phone.
  Future<void> _step(String label, Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      bleLogSink?.call('bootstrap step "$label" failed: $e');
      if (mounted) setState(() => _bootError = '$label 실패: $e');
    }
  }

  /// Boot the mesh, retrying on failure. A background relaunch (BLE state
  /// restoration / beacon wake) on a locked phone can't read the Keychain
  /// (errSecInteractionNotAllowed) — retrying means the node comes up on its
  /// own the moment the user unlocks, instead of dying silently.
  Future<void> _startMesh(String name) async {
    for (var attempt = 0;; attempt++) {
      try {
        await _launch(name);
        if (mounted && _bootError != null) {
          setState(() => _bootError = null);
        }
        return;
      } catch (e) {
        bleLogSink?.call('bootstrap failed (attempt $attempt): $e');
        if (!mounted) return;
        // Show what's wrong right on the splash so a stuck phone can be
        // diagnosed by reading the screen.
        setState(() => _bootError = '시작 실패 (${attempt + 1}회): $e');
        await Future<void>.delayed(Duration(seconds: attempt < 6 ? 10 : 60));
        if (!mounted) return;
      }
    }
  }

  Future<void> _onNameChosen(String name) async {
    await _identityStore.setDisplayName(name);
    if (mounted) setState(() => _stage = _Stage.loading);
    // Now that the user has a name, bring up services + ask for the OS
    // permissions the mesh needs, then start.
    await _step('알림 준비', () async {
      await BackgroundService.init();
      await NotificationService.init();
    });
    await _step(
        '권한 요청',
        () => Permissions.request()
            .timeout(const Duration(seconds: 45), onTimeout: () => false));
    await _startMesh(name);
  }

  Future<void> _launch(String name) async {
    final identity = await _identityStore.loadOrCreate();
    final db = AppDatabase();
    final controller = MeshController(
      identity: identity,
      displayName: name,
      db: db,
      identityStore: _identityStore,
    );
    await controller.init();
    if (!mounted) {
      // Unmounted mid-launch: don't leak the controller's timers/subscriptions.
      controller.dispose();
      return;
    }
    if (controller.started) {
      await BackgroundService.start();
    }
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _stage = _Stage.ready;
    });
  }

  /// Mirror BLE diagnostics into Documents/ble.log so release builds can be
  /// diagnosed on-device (pull the file with `devicectl device copy from
  /// --domain-type appDataContainer`). Console output is dropped in release.
  Future<void> _wireBleFileLog() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'ble.log'));
      // Keep it bounded across launches.
      if (file.existsSync() && file.lengthSync() > 256 * 1024) {
        file.deleteSync();
      }
      final sink = file.openWrite(mode: FileMode.append);
      sink.writeln('=== app start ${DateTime.now().toIso8601String()} ===');
      bleLogSink = (line) =>
          sink.writeln('${DateTime.now().toIso8601String()} $line');

      // Route uncaught errors into the same file: a widget build exception in
      // release mode renders as a silent blank screen, so this is the only
      // trace of it on a real device.
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        bleLogSink?.call('FLUTTER ERROR: ${details.exception}\n${details.stack}');
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        bleLogSink?.call('UNCAUGHT: $error\n$stack');
        return true;
      };
    } catch (_) {
      // Diagnostics only — never block startup on logging.
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return _Splash(error: _bootError);
      case _Stage.onboarding:
        return OnboardingScreen(onSubmit: _onNameChosen);
      case _Stage.ready:
        return ChangeNotifierProvider.value(
          value: _controller!,
          child: const HomeScreen(),
        );
    }
  }
}

class _Splash extends StatelessWidget {
  final String? error;
  const _Splash({this.error});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.primary,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hub, size: 72, color: scheme.onPrimary),
              const SizedBox(height: 16),
              Text('SpotLink',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: scheme.onPrimary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: scheme.onPrimary),
              ),
              if (error != null) ...[
                const SizedBox(height: 24),
                Text(
                  '$error\n자동으로 다시 시도합니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: scheme.onPrimary.withValues(alpha: 0.9),
                      fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
