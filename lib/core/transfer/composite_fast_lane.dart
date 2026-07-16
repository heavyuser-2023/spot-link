import 'dart:async';

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
