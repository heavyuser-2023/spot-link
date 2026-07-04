import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'fast_lane.dart';

/// Fast lane backed by a native P2P Wi-Fi transport over platform channels:
/// **Android Wi-Fi Direct** and **iOS MultipeerConnectivity**. Both establish
/// an AP-less direct link and move the file's *bytes*; the mesh still does
/// discovery, negotiation, encryption and delivery-ACK over BLE.
///
/// Native contract (see android/.../FastLanePlugin.kt, ios/.../FastLane.swift):
///
/// MethodChannel `spotlink/fastlane`:
///  - `capabilities` → `List<String>` of kind names (e.g. `['wifiDirect']`)
///  - `prepareInbound` `{transferId, kind}` → offer blob `Uint8List?`
///     (null ⇒ can't; native begins advertising/listening)
///  - `connect` `{transferId, kind, blob}` → `bool` started (result via event)
///  - `send` `{transferId, data}` → void
///  - `finishSending` `{transferId}` → void
///  - `close` `{transferId}` → void
///
/// EventChannel `spotlink/fastlane/events` emits maps:
///   `{transferId, event: 'connected'|'data'|'eof'|'error', data?: Uint8List}`
///
/// Every call is defensive: on a platform with no native handler
/// (MissingPluginException — desktop, tests, background isolate without the
/// plugin) capabilities is empty and the mesh simply uses LAN/BLE.
class PlatformFastLane implements FastLaneInterface {
  static const _method = MethodChannel('spotlink/fastlane');
  static const _events = EventChannel('spotlink/fastlane/events');

  /// Shared instance the app injects; call [warmUp] once at startup so
  /// [capabilities] is populated before the first transfer.
  static final PlatformFastLane instance = PlatformFastLane._();
  PlatformFastLane._();

  Set<FastLaneKind> _caps = const {};
  bool _wired = false;

  /// Per-transfer plumbing.
  final Map<String, StreamController<Uint8List>> _incoming = {};
  final Map<String, Completer<bool>> _connected = {};

  @override
  Set<FastLaneKind> get capabilities => _caps;

  /// Query native capabilities and, only if any exist, subscribe to the event
  /// stream. Safe to call repeatedly; never throws. On a platform with no
  /// native handler (desktop, tests, background isolate) capabilities stays
  /// empty and we never touch the event channel.
  Future<void> warmUp() async {
    try {
      final list = await _method.invokeListMethod<String>('capabilities');
      final caps = <FastLaneKind>{};
      for (final name in list ?? const <String>[]) {
        final k = _kindByName(name);
        if (k != null) caps.add(k);
      }
      _caps = caps;
    } catch (_) {
      _caps = const {}; // no native handler → LAN/BLE only
    }
    if (_caps.isNotEmpty) _wireEvents();
  }

  static FastLaneKind? _kindByName(String n) => switch (n) {
        'wifiAware' => FastLaneKind.wifiAware,
        'wifiDirect' => FastLaneKind.wifiDirect,
        'multipeer' => FastLaneKind.multipeer,
        _ => null,
      };

  void _wireEvents() {
    if (_wired) return;
    _wired = true;
    try {
      _events.receiveBroadcastStream().listen(_onEvent,
          onError: (_) {}); // stream errors are non-fatal
    } catch (_) {
      // No event channel (unsupported platform) — capabilities stays empty.
    }
  }

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    final tid = e['transferId'] as String?;
    final kind = e['event'] as String?;
    if (tid == null || kind == null) return;
    switch (kind) {
      case 'connected':
        _connected[tid]?.complete(true);
        break;
      case 'data':
        final d = e['data'];
        if (d is Uint8List) _incoming[tid]?.add(d);
        break;
      case 'eof':
        _incoming[tid]?.close();
        break;
      case 'error':
        _connected[tid]?.complete(false);
        _incoming[tid]?.close();
        break;
    }
  }

  @override
  Future<FastLaneInbound?> prepareInbound(
      String transferIdHex, FastLaneKind kind) async {
    if (!_caps.contains(kind)) return null;
    _wireEvents();
    Uint8List? blob;
    try {
      blob = await _method.invokeMethod<Uint8List>('prepareInbound', {
        'transferId': transferIdHex,
        'kind': kind.name,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('FastLane prepareInbound failed: $e');
      return null;
    }
    if (blob == null) return null;
    final connected = _connected[transferIdHex] = Completer<bool>();
    _incoming[transferIdHex] = StreamController<Uint8List>();
    final session = connected.future.then<FastLaneSession?>((ok) {
      if (!ok) {
        _teardown(transferIdHex);
        return null;
      }
      return _PlatformSession(this, transferIdHex);
    }).timeout(const Duration(seconds: 10), onTimeout: () {
      _teardown(transferIdHex);
      return null;
    });
    return FastLaneInbound(FastLaneOffer(kind, blob), session);
  }

  @override
  Future<FastLaneSession?> connect(
      String transferIdHex, FastLaneOffer offer) async {
    if (!_caps.contains(offer.kind)) return null;
    _wireEvents();
    final connected = _connected[transferIdHex] = Completer<bool>();
    _incoming[transferIdHex] = StreamController<Uint8List>();
    try {
      final started = await _method.invokeMethod<bool>('connect', {
        'transferId': transferIdHex,
        'kind': offer.kind.name,
        'blob': offer.blob,
      });
      if (started != true) {
        _teardown(transferIdHex);
        return null;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('FastLane connect failed: $e');
      _teardown(transferIdHex);
      return null;
    }
    final ok = await connected.future
        .timeout(const Duration(seconds: 10), onTimeout: () => false);
    if (!ok) {
      _teardown(transferIdHex);
      return null;
    }
    return _PlatformSession(this, transferIdHex);
  }

  Future<void> _send(String tid, Uint8List data) async {
    try {
      await _method.invokeMethod('send', {'transferId': tid, 'data': data});
    } catch (_) {}
  }

  Future<void> _finish(String tid) async {
    try {
      await _method.invokeMethod('finishSending', {'transferId': tid});
    } catch (_) {}
  }

  Future<void> _close(String tid) async {
    try {
      await _method.invokeMethod('close', {'transferId': tid});
    } catch (_) {}
    _teardown(tid);
  }

  void _teardown(String tid) {
    _connected.remove(tid);
    final c = _incoming.remove(tid);
    if (c != null && !c.isClosed) c.close();
  }

  Stream<Uint8List> _incomingOf(String tid) =>
      (_incoming[tid] ??= StreamController<Uint8List>()).stream;
}

class _PlatformSession implements FastLaneSession {
  final PlatformFastLane _lane;
  final String _tid;
  _PlatformSession(this._lane, this._tid);

  /// Split large payloads so no single platform-channel message is huge
  /// (a 20 MB invokeMethod would jank the platform thread and copy twice).
  static const int _chunk = 64 * 1024;

  @override
  Stream<Uint8List> get incoming => _lane._incomingOf(_tid);

  @override
  void add(Uint8List data) {
    for (var off = 0; off < data.length; off += _chunk) {
      final end = (off + _chunk < data.length) ? off + _chunk : data.length;
      _lane._send(_tid, Uint8List.sublistView(data, off, end));
    }
  }

  @override
  Future<void> finishSending() => _lane._finish(_tid);

  @override
  Future<void> close() => _lane._close(_tid);
}
