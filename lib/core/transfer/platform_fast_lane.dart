import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'fast_lane.dart';

/// 플랫폼 채널을 통해 네이티브 P2P Wi-Fi 전송을 등에 업은 패스트레인:
/// **Android Wi-Fi Direct**와 **iOS MultipeerConnectivity**. 둘 다 AP 없는
/// 직접 링크를 수립하여 파일의 *바이트*를 옮긴다; 메시는 여전히 발견, 협상,
/// 암호화, 전달-ACK를 BLE로 처리한다.
///
/// 네이티브 계약 (android/.../FastLanePlugin.kt, ios/.../FastLane.swift 참고):
///
/// MethodChannel `spotlink/fastlane`:
///  - `capabilities` → 종류 이름들의 `List<String>` (예: `['wifiDirect']`)
///  - `prepareInbound` `{transferId, kind}` → 오퍼 blob `Uint8List?`
///     (null ⇒ 불가능; 네이티브가 광고/수신 대기를 시작)
///  - `connect` `{transferId, kind, blob}` → 시작 여부 `bool` (결과는 이벤트로)
///  - `send` `{transferId, data}` → void
///  - `finishSending` `{transferId}` → void
///  - `close` `{transferId}` → void
///
/// EventChannel `spotlink/fastlane/events`는 맵을 방출한다:
///   `{transferId, event: 'connected'|'data'|'eof'|'error', data?: Uint8List}`
///
/// 모든 호출은 방어적이다: 네이티브 핸들러가 없는 플랫폼
/// (MissingPluginException — 데스크톱, 테스트, 플러그인이 없는 백그라운드
/// isolate)에서는 capabilities가 비어 있고 메시는 그냥 LAN/BLE를 사용한다.
class PlatformFastLane implements FastLaneInterface {
  static const _method = MethodChannel('spotlink/fastlane');
  static const _events = EventChannel('spotlink/fastlane/events');

  /// 앱이 주입하는 공유 인스턴스; 첫 전송 전에 [capabilities]가 채워지도록
  /// 시작 시 [warmUp]을 한 번 호출한다.
  static final PlatformFastLane instance = PlatformFastLane._();
  PlatformFastLane._();

  Set<FastLaneKind> _caps = const {};
  bool _wired = false;

  /// 전송별 배관(plumbing).
  final Map<String, StreamController<Uint8List>> _incoming = {};
  final Map<String, Completer<bool>> _connected = {};

  @override
  Set<FastLaneKind> get capabilities => _caps;

  /// 네이티브 기능(capabilities)을 조회하고, 하나라도 있을 때만 이벤트 스트림을
  /// 구독한다. 반복 호출해도 안전하며, 절대 예외를 던지지 않는다. 네이티브
  /// 핸들러가 없는 플랫폼(데스크톱, 테스트, 백그라운드 isolate)에서는
  /// capabilities가 비어 있고 이벤트 채널을 전혀 건드리지 않는다.
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
      _caps = const {}; // 네이티브 핸들러 없음 → LAN/BLE 전용
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
          onError: (_) {}); // 스트림 오류는 치명적이지 않다
    } catch (_) {
      // 이벤트 채널 없음(미지원 플랫폼) — capabilities는 비어 있는 채로 유지.
    }
  }

  /// Optional sink for native `log` events (wired to ble.log in the app layer).
  static void Function(String msg)? logSink;

  void _completeConnected(String tid, bool ok) {
    final c = _connected[tid];
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    final tid = e['transferId'] as String?;
    final kind = e['event'] as String?;
    if (tid == null || kind == null) return;
    switch (kind) {
      case 'connected':
        _completeConnected(tid, true);
        break;
      case 'data':
        final d = e['data'];
        if (d is Uint8List) {
          final c = _incoming[tid];
          if (c != null && !c.isClosed) c.add(d);
        }
        break;
      case 'eof':
        final c = _incoming[tid];
        if (c != null && !c.isClosed) c.close();
        break;
      case 'error':
        _completeConnected(tid, false);
        final c = _incoming[tid];
        if (c != null && !c.isClosed) c.close();
        break;
      case 'log':
        final msg = e['message'] as String?;
        if (msg != null) {
          logSink?.call('FT native: $msg');
          if (kDebugMode) debugPrint('FastLane: $msg');
        }
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
    }).timeout(const Duration(seconds: 25), onTimeout: () {
      unawaited(_close(transferIdHex)); // 네이티브 광고도 중지
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
        .timeout(const Duration(seconds: 25), onTimeout: () => false);
    if (!ok) {
      await _close(transferIdHex); // 네이티브 브라우저도 중지
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

  /// 단일 플랫폼 채널 메시지가 거대해지지 않도록 큰 페이로드를 분할한다
  /// (20MB짜리 invokeMethod는 플랫폼 스레드를 버벅이게 하고 두 번 복사한다).
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
