import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry point the Android foreground service runs in ITS OWN isolate.
///
/// STRUCTURAL NOTE (v1.3.6): this isolate no longer runs a mesh node.
///
/// Previously it ran a full headless MeshNode so the device kept relaying
/// after a swipe-kill/reboot. But that meant the mesh existed in TWO isolates
/// at once (this one + the UI's), each opening its own BLE GATT server. Two
/// (or, with a coordination bug, up to seven) servers advertising the same
/// service make iOS centrals fail to connect — the single most persistent
/// connectivity bug in this app. Every attempt to *coordinate* the two
/// isolates (ping/pong, file heartbeat, shared-prefs heartbeat, self-yield
/// timer) proved fragile and one of them actively made it worse by spawning
/// meshes in a race.
///
/// The robust fix is architectural: run the mesh in EXACTLY ONE place — the
/// UI isolate. The foreground service still runs (its persistent notification
/// keeps the process, and therefore the UI isolate's mesh, alive while the app
/// is merely backgrounded), but it no longer creates a second BLE stack.
///
/// Tradeoff: after a full swipe-kill the OS may relaunch this service alone
/// (no UI isolate); with no headless mesh, the device won't relay until the
/// user opens the app again — same behaviour as iOS. Reliable connectivity
/// while running beats flaky "always-on" that couldn't actually connect. If
/// headless survival is wanted back, it must be a single-owner design (UI as a
/// thin client of the service's mesh), not two coordinated meshes.
@pragma('vm:entry-point')
void headlessMeshMain() {
  FlutterForegroundTask.setTaskHandler(_HeadlessMeshHandler());
}

class _HeadlessMeshHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Ensure the plugin bindings exist, then stay dormant: the UI isolate owns
    // the one and only mesh. We exist solely to keep the process alive.
    WidgetsFlutterBinding.ensureInitialized();
  }

  @override
  void onReceiveData(Object data) {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
