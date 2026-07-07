import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../data/app_database.dart';
import '../data/identity_store.dart';
import 'background_service.dart';
import 'mesh_controller.dart';
import 'notification_service.dart';

/// Entry point the Android foreground service runs in ITS OWN isolate when
/// the system (re)starts it without the app UI — after a reboot, an app
/// update, a swipe-kill, or an OEM battery-manager kill. Runs the full mesh
/// node headlessly (receive → notify → relay → store-and-forward), so the
/// device stays a live mesh participant even though no screen ever opened.
@pragma('vm:entry-point')
void headlessMeshMain() {
  FlutterForegroundTask.setTaskHandler(_HeadlessMeshHandler());
}

class _HeadlessMeshHandler extends TaskHandler {
  MeshController? _controller;
  bool _uiAlive = false;
  bool _stopping = false;

  /// Continuously yields the radio to the UI mesh. Message-passing takeover
  /// (msgUiTakeover) proved unreliable across isolates — both meshes ended up
  /// running, each with its own GATT server (→ iOS connects fail). This timer
  /// is the timing-independent guarantee: while the UI's heartbeat file is
  /// fresh, the headless mesh stays stopped; when the UI dies, it resumes.
  Timer? _yieldTimer;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _yieldTimer ??= Timer.periodic(
        const Duration(seconds: 5), (_) => _yieldToUiIfAlive());

    // The UI started the service: the main isolate owns the mesh; we stay
    // dormant and only exist to keep the process alive.
    if (starter == TaskStarter.developer) return;

    // System restart (boot / kill recovery). The process may have survived a
    // swipe-kill with the UI mesh still running in the main isolate — ping it
    // and only go headless when nobody answers.
    _uiAlive = false;
    FlutterForegroundTask.sendDataToMain(BackgroundService.msgPing);
    await Future<void>.delayed(const Duration(seconds: 3));
    if (_uiAlive) return;
    // Timing-independent backstop: if the UI mesh touched its heartbeat file
    // recently, it is alive even though the pong missed — do NOT start a
    // second mesh (that would open a duplicate GATT server and break iOS
    // connects). See BackgroundService.uiMeshHeartbeatFresh.
    if (await BackgroundService.uiMeshHeartbeatFresh()) return;
    await _startMesh();
  }

  /// Runs every 5s: if the UI mesh is alive, make sure ours is stopped; if the
  /// UI is gone and we have no mesh, resume (background survival).
  Future<void> _yieldToUiIfAlive() async {
    if (_stopping) return;
    final uiAlive = await BackgroundService.uiMeshHeartbeatFresh();
    if (uiAlive && _controller != null) {
      await _stopMesh();
    } else if (!uiAlive && _controller == null) {
      await _startMesh();
    }
  }

  Future<void> _startMesh() async {
    if (_controller != null) return;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      // The foreground-service background engine does NOT auto-register
      // plugins. Without this, every plugin channel (BLE, sqflite, secure
      // storage, notifications) throws MissingPluginException and the mesh
      // can't even load its identity. This registers the Dart-side plugin
      // implementations for this isolate.
      DartPluginRegistrant.ensureInitialized();
      await NotificationService.init();
      final store = IdentityStore();
      final name = await store.storedName();
      // Onboarding never completed on this device: no identity to run.
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
      await BackgroundService.updateStatus(controller.linkCount);
    } catch (_) {
      // Best-effort: a failed headless start must never crash the service —
      // the next system restart tries again.
    }
  }

  Future<void> _stopMesh() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      await controller.node.dispose();
      controller.dispose();
    } catch (_) {}
  }

  @override
  void onReceiveData(Object data) {
    if (data == BackgroundService.msgPong) {
      _uiAlive = true;
    } else if (data == BackgroundService.msgUiTakeover) {
      // The user opened the app: hand the radio over to the UI mesh.
      if (_stopping) return;
      _stopping = true;
      _stopMesh().whenComplete(() {
        _stopping = false;
        FlutterForegroundTask.sendDataToMain(
            BackgroundService.msgHeadlessStopped);
      });
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _yieldTimer?.cancel();
    _yieldTimer = null;
    await _stopMesh();
  }
}
