import 'dart:async';
import 'dart:typed_data';

import 'package:spot_link/core/transfer/fast_lane.dart';

/// An in-memory fast lane connecting two [FakeFastLane]s through a shared
/// [FakeFastMedium] — the Wi-Fi analogue of [FakeRadio]. Lets tests exercise
/// the negotiate → connect → stream → fallback logic without real Wi-Fi.
class FakeFastMedium {
  /// transferId → the receiver waiting for a sender to dial in.
  final Map<String, Completer<_FakeSessionPair>> _listeners = {};

  /// Global switches for fallback tests.
  bool failConnect = false; // sender's connect() returns null
  bool failListen = false; // receiver's prepareInbound() returns null

  FakeFastLane endpoint(Set<FastLaneKind> caps) => FakeFastLane(this, caps);

  /// Receiver registers; returns the future the sender completes on connect.
  Future<_FakeSessionPair> _listen(String tid) {
    final c = _listeners[tid] = Completer<_FakeSessionPair>();
    return c.future;
  }

  _FakeSession? _dial(String tid) {
    final waiter = _listeners.remove(tid);
    if (waiter == null || waiter.isCompleted) return null;
    final a = _FakeSession(); // sender side
    final b = _FakeSession(); // receiver side
    a._peer = b;
    b._peer = a;
    waiter.complete(_FakeSessionPair(b));
    return a;
  }
}

class _FakeSessionPair {
  final _FakeSession receiver;
  _FakeSessionPair(this.receiver);
}

class FakeFastLane implements FastLaneInterface {
  final FakeFastMedium medium;
  @override
  final Set<FastLaneKind> capabilities;
  FakeFastLane(this.medium, this.capabilities);

  @override
  Future<FastLaneInbound?> prepareInbound(
    String transferIdHex,
    FastLaneKind kind,
  ) async {
    if (medium.failListen) return null;
    final sessionFut = medium
        ._listen(transferIdHex)
        .then<FastLaneSession?>((pair) => pair.receiver)
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    return FastLaneInbound(
      FastLaneOffer(kind, Uint8List.fromList([1, 2, 3])),
      sessionFut,
    );
  }

  @override
  Future<FastLaneSession?> connect(
    String transferIdHex,
    FastLaneOffer offer,
  ) async {
    if (medium.failConnect) return null;
    return medium._dial(transferIdHex);
  }
}

class _FakeSession implements FastLaneSession {
  final _incoming = StreamController<Uint8List>();
  _FakeSession? _peer;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  void add(Uint8List data) {
    final peer = _peer;
    if (peer != null && !peer._incoming.isClosed) {
      peer._incoming.add(Uint8List.fromList(data));
    }
  }

  @override
  Future<void> finishSending() async {
    // Signal EOF to the peer's reader after buffered bytes drain.
    final peer = _peer;
    if (peer != null && !peer._incoming.isClosed) {
      await peer._incoming.close();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }
}
