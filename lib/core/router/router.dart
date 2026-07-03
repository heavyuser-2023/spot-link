import 'dart:typed_data';

import '../model/frame.dart';
import '../model/peer_id.dart';
import 'seen_cache.dart';

/// The outcome of routing a single incoming frame. The [MeshNode] executes it:
/// delivering locally and/or relaying to neighbours.
class RouteDecision {
  /// True if the frame was a duplicate and should be ignored entirely.
  final bool duplicate;

  /// True if this frame is addressed to us (or broadcast) and should be
  /// delivered to the local application.
  final bool deliverLocal;

  /// Non-null if the frame should be relayed onward (TTL already decremented).
  final Frame? relay;

  const RouteDecision({
    required this.duplicate,
    required this.deliverLocal,
    required this.relay,
  });

  static const RouteDecision drop =
      RouteDecision(duplicate: true, deliverLocal: false, relay: null);

  @override
  String toString() =>
      'RouteDecision(dup=$duplicate, local=$deliverLocal, relay=${relay != null})';
}

/// Stateless-ish routing core: flooding with TTL and duplicate suppression.
/// See docs/ARCHITECTURE.md §7.
///
/// This class is deliberately free of any BLE/IO dependency so it can be unit
/// tested exhaustively. The [MeshNode] feeds it frames and acts on the returned
/// [RouteDecision].
class Router {
  final PeerId myId;
  final SeenCache seen;

  /// Default starting TTL for frames originated by this node.
  final int defaultTtl;

  Router({
    required this.myId,
    required this.seen,
    this.defaultTtl = 7,
  });

  /// Decide what to do with an incoming routable frame.
  ///
  /// Link-local frames (ANNOUNCE/HAVE/WANT) must not be passed here — they are
  /// handled directly by the node between neighbours.
  RouteDecision handleIncoming(Frame frame) {
    assert(!frame.type.isLinkLocal,
        'link-local frames must not be routed: ${frame.type}');

    // 1. Duplicate suppression (atomic check-and-mark).
    if (seen.checkAndMark(frame.msgIdHex)) {
      return RouteDecision.drop;
    }

    final forMe = frame.dst == myId;
    final broadcast = frame.dst.isBroadcast;
    final deliverLocal = forMe || broadcast;

    // 2. Relay decision. We never relay frames addressed solely to us.
    Frame? relay;
    if (!forMe) {
      final nextTtl = frame.ttl - 1;
      if (nextTtl > 0) {
        relay = frame.copyWith(ttl: nextTtl);
      }
    }

    return RouteDecision(
      duplicate: false,
      deliverLocal: deliverLocal,
      relay: relay,
    );
  }

  /// Prepare a locally originated frame: mark its id as seen so it is never
  /// re-processed if it echoes back to us, and stamp the default TTL.
  Frame originate({
    required FrameType type,
    required PeerId dst,
    required List<int> payload,
    int flags = 0,
    int? ttl,
  }) {
    final frame = Frame.create(
      type: type,
      ttl: ttl ?? defaultTtl,
      src: myId,
      dst: dst,
      payload: payload is Uint8List ? payload : Uint8List.fromList(payload),
      flags: flags,
    );
    seen.checkAndMark(frame.msgIdHex);
    return frame;
  }
}
