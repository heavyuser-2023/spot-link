import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../core/ble/mesh_transport.dart' show bleLogSink;
import 'bridge_protocol.dart';
import 'mesh_controller.dart';

/// Service-isolate side of the UI bridge: exposes the one true
/// [MeshController] to the (optional) UI isolate as JSON messages over the
/// foreground-task port.
///
/// Protocol:
///  UI → service: `{"c": command, ...args}`  (see [handle])
///  service → UI: `{"t":"snap", ...state}`   throttled full snapshot
///                `{"t":"err","m":...}`      transient error → snackbar
///
/// Chat history itself never crosses the port — both isolates share the
/// SQLite file (WAL), so the UI reloads its open conversation whenever the
/// snapshot's `rev` counter moves.
class MeshHost {
  final MeshController controller;

  Timer? _throttle;
  Timer? _uiStaleTimer;
  StreamSubscription? _errSub;

  /// Last signal from the UI isolate. When it goes silent (swipe-kill — no
  /// 'bye' arrives), flip back to background-notification behaviour.
  DateTime _lastUiSignal = DateTime.fromMillisecondsSinceEpoch(0);
  bool _uiForeground = false;

  MeshHost(this.controller) {
    controller.addListener(_scheduleSnapshot);
    _errSub = controller.errorEvents.listen(
        (m) => _send({'t': Bridge.typeError, 'm': m}));
    // The UI keepalive ticks every ~10s while it exists; 35s of silence
    // means the UI isolate is gone (or frozen) — resume notifying.
    _uiStaleTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_uiForeground) return;
      if (DateTime.now().difference(_lastUiSignal) >
          const Duration(seconds: 35)) {
        _uiForeground = false;
        controller.setRemoteForeground(false);
        controller.closeConversation();
      }
    });
    _scheduleSnapshot();
  }

  /// Push a fresh snapshot soon, coalescing bursts (RSSI samples arrive every
  /// few seconds per peer; serializing on every notifyListeners would be
  /// wasteful).
  void _scheduleSnapshot() {
    _throttle ??= Timer(const Duration(milliseconds: 250), () {
      _throttle = null;
      _send({'t': Bridge.typeSnapshot, ...controller.snapshotForRemote()});
    });
  }

  void _send(Map<String, Object?> m) {
    try {
      FlutterForegroundTask.sendDataToMain(jsonEncode(m));
    } catch (_) {} // no UI attached — fine
  }

  Future<void> handle(Object data) async {
    if (data is! String) return;
    Map<String, Object?> m;
    try {
      m = (jsonDecode(data) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    _lastUiSignal = DateTime.now();
    final c = controller;
    try {
      switch (m['c']) {
        case Bridge.cmdHello:
          _scheduleSnapshot();
        case Bridge.cmdForeground:
          _uiForeground = m['v'] == true;
          c.setRemoteForeground(_uiForeground);
        case Bridge.cmdBye:
          _uiForeground = false;
          c.setRemoteForeground(false);
          c.closeConversation();
        case Bridge.cmdOpen:
          await c.openConversation(m['p'] as String);
        case Bridge.cmdClose:
          c.closeConversation();
        case Bridge.cmdSendText:
          await c.sendText(m['p'] as String, m['x'] as String);
        case Bridge.cmdRetryText:
          await c.retryTextById(m['p'] as String, m['id'] as String);
        case Bridge.cmdSendFile:
          await _sendFile(m);
        case Bridge.cmdRetryFile:
          await c.retryFileById(m['p'] as String, m['id'] as String);
        case Bridge.cmdCancelFile:
          await c.cancelFileById(m['id'] as String);
        case Bridge.cmdDeleteMessage:
          await c.deleteMessageById(m['p'] as String, m['id'] as String);
        case Bridge.cmdAddContact:
          await c.addContactFromBundle(
            base64Decode(m['b'] as String),
            name: m['name'] as String?,
            verified: m['v'] != false,
          );
        case Bridge.cmdDeleteContact:
          await c.deleteContact(m['p'] as String);
        case Bridge.cmdRenameContact:
          await c.renameContact(m['p'] as String, m['name'] as String);
        case Bridge.cmdSetName:
          await c.setDisplayName(m['v'] as String);
        case Bridge.cmdSetSaver:
          c.setPowerSaver(m['v'] == true);
        case Bridge.cmdClearRelay:
          await c.clearRelayStore();
      }
    } catch (e) {
      bleLogSink?.call('MeshHost command ${m['c']} failed: $e');
      _send({'t': 'err', 'm': '$e'});
    }
  }

  /// The UI hands over a path (bytes never cross the port, and the payload
  /// never enters RAM here either — the controller copies it with a native
  /// File.copy and streams chunks from disk). Outbox temp files are ours to
  /// delete; picker paths belong to the OS cache and are left alone.
  Future<void> _sendFile(Map<String, Object?> m) async {
    final path = m['path'] as String;
    try {
      await controller.sendFilePath(
        m['p'] as String,
        path: path,
        name: m['name'] as String,
        mime: m['mime'] as String,
      );
    } finally {
      if (path.contains(
          '${Platform.pathSeparator}outbox${Platform.pathSeparator}')) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }

  void dispose() {
    controller.removeListener(_scheduleSnapshot);
    _errSub?.cancel();
    _throttle?.cancel();
    _throttle = null;
    _uiStaleTimer?.cancel();
  }
}
