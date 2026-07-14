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
}
