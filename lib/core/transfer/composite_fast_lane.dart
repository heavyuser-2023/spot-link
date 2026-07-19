import 'dart:async';
import 'dart:typed_data';

import 'fast_lane.dart';

/// 여러 패스트레인(예: LAN 소켓 + 네이티브 P2P 전송)을 하나로 합친다.
/// capabilities는 합집합이며, 각 요청은 선택된 [FastLaneKind]를 소유한 하위
/// 레인으로 라우팅된다. 하위 레인이 요청을 처리할 수 없으면 null을 반환하고
/// [MeshNode]가 폴백한다(궁극적으로 BLE로).
class CompositeFastLane implements FastLaneInterface {
  final List<FastLaneInterface> lanes;
  const CompositeFastLane(this.lanes);

  @override
  Set<FastLaneKind> get capabilities =>
      {for (final l in lanes) ...l.capabilities};

  @override
  Set<FastLaneKind> get inboundCapabilities =>
      {for (final l in lanes) ...l.inboundCapabilities};

  FastLaneInterface? _laneFor(FastLaneKind kind) {
    for (final l in lanes) {
      if (l.capabilities.contains(kind)) return l;
    }
    return null;
  }

  FastLaneInterface? _laneForInbound(FastLaneKind kind) {
    for (final l in lanes) {
      if (l.inboundCapabilities.contains(kind)) return l;
    }
    return null;
  }

  @override
  Future<FastLaneInbound?> prepareInbound(
      String transferIdHex, FastLaneKind kind,
      {bool tidPreamble = false}) async {
    return _laneForInbound(kind)
        ?.prepareInbound(transferIdHex, kind, tidPreamble: tidPreamble);
  }

  @override
  Future<FastLaneSession?> connect(
      String transferIdHex, FastLaneOffer offer) async {
    return _laneFor(offer.kind)?.connect(transferIdHex, offer);
  }

  @override
  Future<FastLaneInbound?> prepareOutboundHost(
      String transferIdHex, FastLaneKind kind) async {
    return _laneFor(kind)?.prepareOutboundHost(transferIdHex, kind);
  }

  @override
  Future<bool> connectToHost(
      String transferIdHex, FastLaneKind kind, Uint8List blob) async {
    return await _laneForInbound(kind)?.connectToHost(transferIdHex, kind, blob) ??
        false;
  }
}
