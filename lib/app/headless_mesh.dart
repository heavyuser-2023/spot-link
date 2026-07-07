import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/ble/mesh_transport.dart' show bleLogSink;
import '../data/app_database.dart';
import '../data/identity_store.dart';
import 'background_service.dart';
import 'mesh_controller.dart';
import 'mesh_host.dart';
import 'notification_service.dart';

/// Entry point of the Android foreground service's own isolate — the SINGLE
/// OWNER of the mesh (v1.4.0).
///
/// The mesh node lives here and ONLY here, whether the service was started by
/// the UI or by the system (boot / swipe-kill restart / app update / OEM kill
/// recovery). The UI isolate, when it exists, attaches as a thin client over
/// the task port (see [MeshHost] / RemoteMeshController) and never opens a
/// BLE stack of its own.
///
/// History: v1.3.2–1.3.5 ran a SECOND mesh here only while the UI was dead
/// and coordinated ownership via ping/pong, then file, then prefs heartbeats
/// — every scheme eventually raced and doubled the GATT server, which iOS
/// centrals cannot connect through. v1.3.6 removed the headless mesh
/// entirely (no relay after swipe-kill). Single ownership removes the
/// coordination problem instead of trying to win it.
@pragma('vm:entry-point')
void headlessMeshMain() {
  FlutterForegroundTask.setTaskHandler(_MeshOwnerHandler());
}

class _MeshOwnerHandler extends TaskHandler {
  MeshController? _controller;
  MeshHost? _host;
  bool _starting = false;
  Timer? _retryTimer;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _startMesh();
    // No identity yet (first run before onboarding finished) or a transient
    // boot failure: keep retrying so the mesh comes up on its own the moment
    // it can, without any signal from the UI.
    _retryTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _startMesh());
  }

  Future<void> _startMesh() async {
    if (_controller != null || _starting) return;
    _starting = true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      // The service's background engine does NOT auto-register Dart plugin
      // implementations. Without this every plugin channel (BLE, sqflite,
      // secure storage, notifications) throws MissingPluginException.
      DartPluginRegistrant.ensureInitialized();
      await _wireServiceLog();
      await NotificationService.init();
      final store = IdentityStore();
      final name = await store.storedName();
      // Onboarding never completed on this device: nothing to run yet.
      if (name == null || name.trim().isEmpty) return;
      final identity = await store.loadOrCreate();
      final controller = MeshController(
        identity: identity,
        displayName: name,
        db: AppDatabase(),
        identityStore: store,
        headless: true,
      );
      await controller.init();
      _controller = controller;
      _host = MeshHost(controller);
      await BackgroundService.updateStatus(controller.linkCount);
      bleLogSink?.call('MESH service owner up (started=${controller.started})');
    } catch (e) {
      // Best-effort: a failed start must never crash the service — the retry
      // timer (and the next system restart) tries again.
      bleLogSink?.call('MESH service start failed: $e');
    } finally {
      _starting = false;
    }
  }

  /// Mirror service-isolate diagnostics into Documents/ble-service.log —
  /// separate from the UI isolate's ble.log so concurrent appends from two
  /// isolates never interleave. Pull with `devicectl`/`adb` like ble.log.
  Future<void> _wireServiceLog() async {
    if (bleLogSink != null) return; // already wired in this isolate
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'ble-service.log'));
      if (file.existsSync() && file.lengthSync() > 256 * 1024) {
        file.deleteSync();
      }
      final sink = file.openWrite(mode: FileMode.append);
      sink.writeln(
          '=== mesh service start ${DateTime.now().toIso8601String()} ===');
      bleLogSink =
          (line) => sink.writeln('${DateTime.now().toIso8601String()} $line');
    } catch (_) {} // diagnostics only
  }

  @override
  void onReceiveData(Object data) {
    _host?.handle(data);
    // A command while we're down (e.g. right after onboarding): try booting.
    if (_controller == null) _startMesh();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _host?.dispose();
    _host = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      try {
        await controller.node.dispose();
        controller.dispose();
      } catch (_) {}
    }
  }
}
