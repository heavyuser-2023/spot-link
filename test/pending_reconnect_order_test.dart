import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/ble/mesh_transport.dart';

/// Regression guard for the pending-reconnect selection: the freshest known
/// peers must be the ones armed, never dropped in favour of stale old ids.
/// (iOS 27 can't rediscover a backgrounded peer by scan, so a stale pending
/// set = no reconnect at all.)
void main() {
  // saved is oldest -> newest.
  final saved = ['p1old', 'p2', 'p3', 'p4', 'p5', 'p6new'];

  test('arms the most-recent peers, newest first', () {
    final order = MeshTransport.pendingReconnectOrder(saved, 10);
    // Cap is 4 (_maxPendingReconnects); newest first.
    expect(order, ['p6new', 'p5', 'p4', 'p3']);
  });

  test('the freshest peer is always included (the bug it fixes)', () {
    final order = MeshTransport.pendingReconnectOrder(saved, 10);
    expect(order.first, 'p6new');
    expect(order.contains('p6new'), isTrue);
  });

  test('respects a tighter link budget', () {
    final order = MeshTransport.pendingReconnectOrder(saved, 2);
    expect(order, ['p6new', 'p5']);
  });

  test('zero / negative budget arms nothing', () {
    expect(MeshTransport.pendingReconnectOrder(saved, 0), isEmpty);
    expect(MeshTransport.pendingReconnectOrder(saved, -3), isEmpty);
  });

  test('fewer known peers than the cap arms them all, newest first', () {
    final order = MeshTransport.pendingReconnectOrder(['a', 'b'], 10);
    expect(order, ['b', 'a']);
  });

  test('empty saved list is safe', () {
    expect(MeshTransport.pendingReconnectOrder(const [], 10), isEmpty);
  });

  test('bonded identifiers jump the queue, newest first within groups', () {
    // saved는 오래된 것→최신 순. 본딩된 p1old(가장 오래됨)가 상한 경쟁에서
    // 최신 뜨내기 id들을 제치고 맨 앞에 서야 한다.
    final order = MeshTransport.pendingReconnectOrder(
      saved, 3,
      bonded: {'p1old'},
    );
    expect(order, ['p1old', 'p6new', 'p5']);
  });

  test('bonded set with no matches leaves order unchanged', () {
    final order = MeshTransport.pendingReconnectOrder(
      saved, 2,
      bonded: {'ghost'},
    );
    expect(order, ['p6new', 'p5']);
  });
}
