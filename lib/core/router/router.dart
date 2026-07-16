import 'dart:typed_data';

import '../model/frame.dart';
import '../model/peer_id.dart';
import 'seen_cache.dart';

/// 들어온 프레임 하나를 라우팅한 결과. [MeshNode]가 이를 실행한다:
/// 로컬로 전달하거나 / 이웃에게 릴레이한다.
class RouteDecision {
  /// 프레임이 중복이라 완전히 무시해야 하면 true.
  final bool duplicate;

  /// 이 프레임이 우리 앞으로(또는 브로드캐스트) 온 것이라 로컬 애플리케이션에
  /// 전달해야 하면 true.
  final bool deliverLocal;

  /// 프레임을 계속 릴레이해야 하면 non-null (TTL은 이미 감소됨).
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

/// 거의 무상태에 가까운 라우팅 코어: TTL 기반 플러딩과 중복 억제.
/// docs/ARCHITECTURE.md §7 참고.
///
/// 이 클래스는 철저하게 단위 테스트할 수 있도록 의도적으로 BLE/IO 의존성을
/// 전혀 두지 않았다. [MeshNode]가 프레임을 먹여 주고 반환된 [RouteDecision]에
/// 따라 동작한다.
class Router {
  final PeerId myId;
  final SeenCache seen;

  /// 이 노드가 발신하는 프레임의 기본 시작 TTL.
  final int defaultTtl;

  Router({
    required this.myId,
    required this.seen,
    this.defaultTtl = 7,
  });

  /// 들어온 라우팅 가능 프레임을 어떻게 처리할지 결정한다.
  ///
  /// 링크-로컬 프레임(ANNOUNCE/HAVE/WANT)은 이곳에 넘기면 안 된다 — 이들은
  /// 이웃 사이에서 노드가 직접 처리한다.
  RouteDecision handleIncoming(Frame frame) {
    assert(!frame.type.isLinkLocal,
        'link-local frames must not be routed: ${frame.type}');

    // 1. 중복 억제 (원자적 check-and-mark).
    if (seen.checkAndMark(frame.msgIdHex)) {
      return RouteDecision.drop;
    }

    final forMe = frame.dst == myId;
    final broadcast = frame.dst.isBroadcast;
    final deliverLocal = forMe || broadcast;

    // 2. 릴레이 결정. 오직 우리 앞으로만 온 프레임은 절대 릴레이하지 않는다.
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

  /// 로컬에서 발신하는 프레임을 준비한다: 우리에게 되돌아 울려도 다시 처리되지
  /// 않도록 id를 seen으로 표시하고, 기본 TTL을 찍는다.
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
