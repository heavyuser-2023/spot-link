import 'dart:async';

import 'fast_lane.dart';

/// Combines several fast lanes (e.g. LAN socket + a native P2P transport) into
/// one. Capabilities are the union; each request is routed to the sub-lane
/// that owns the chosen [FastLaneKind]. If a sub-lane can't serve a request it
/// returns null and [MeshNode] falls back (ultimately to BLE).
class CompositeFastLane implements FastLaneInterface {
  final List<FastLaneInterface> lanes;
  const CompositeFastLane(this.lanes);

  @override
  Set<FastLaneKind> get capabilities =>
      {for (final l in lanes) ...l.capabilities};

  FastLaneInterface? _laneFor(FastLaneKind kind) {
    for (final l in lanes) {
      if (l.capabilities.contains(kind)) return l;
    }
    return null;
  }

  @override
  Future<FastLaneInbound?> prepareInbound(
      String transferIdHex, FastLaneKind kind) async {
    return _laneFor(kind)?.prepareInbound(transferIdHex, kind);
  }

  @override
  Future<FastLaneSession?> connect(
      String transferIdHex, FastLaneOffer offer) async {
    return _laneFor(offer.kind)?.connect(transferIdHex, offer);
  }
}
