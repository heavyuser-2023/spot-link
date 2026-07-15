import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/ble/mesh_transport.dart';

/// The status chip must show DEVICES, not raw links: a peer linked both ways
/// holds a `C:<id>` and a `P:<id>` entry with the same id, and counting links
/// ("메시 2" for one friend) reads as two friends.
void main() {
  test('a peer linked both ways counts as one device', () {
    // gold reachable via both an outbound and an inbound link.
    expect(
      MeshTransport.distinctPeerCount(['C:gold', 'P:gold']),
      1,
    );
  });

  test('two distinct peers count as two', () {
    expect(
      MeshTransport.distinctPeerCount(['C:gold', 'P:gold', 'C:heavy']),
      2,
    );
  });

  test('single one-directional link counts as one', () {
    expect(MeshTransport.distinctPeerCount(['P:gold']), 1);
  });

  test('no links is zero', () {
    expect(MeshTransport.distinctPeerCount(const []), 0);
  });
}
