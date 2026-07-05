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

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await initializeDateFormatting('ko', null);
    await _wireBleFileLog();
    await BackgroundService.init();
    await NotificationService.init();
    await Permissions.request(); // best-effort; UI surfaces failures later
    await _startMesh();
  }

  /// Boot the mesh, retrying on failure. A background relaunch (BLE state
  /// restoration / beacon wake) on a locked phone can't read the Keychain
  /// (errSecInteractionNotAllowed) — retrying means the node comes up on its
  /// own the moment the user unlocks, instead of dying silently.
  Future<void> _startMesh() async {
    for (var attempt = 0;; attempt++) {
      try {
        final stored = await _identityStore.storedName();
        if (stored == null || stored.trim().isEmpty) {
          if (mounted) setState(() => _stage = _Stage.onboarding);
          return;
        }
        await _launch(stored);
        return;
      } catch (e) {
        bleLogSink?.call('bootstrap failed (attempt $attempt): $e');
        if (!mounted) return;
        await Future<void>.delayed(Duration(seconds: attempt < 6 ? 10 : 60));
        if (!mounted) return;
      }
    }
  }

  Future<void> _onNameChosen(String name) async {
    await _identityStore.setDisplayName(name);
    setState(() => _stage = _Stage.loading);
    await _launch(name);
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
        return const _Splash();
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
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.primary,
      body: Center(
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
          ],
        ),
      ),
    );
  }
}
