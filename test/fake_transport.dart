import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:spot_link/core/ble/framing.dart';
import 'package:spot_link/core/ble/mesh_transport.dart';
import 'package:spot_link/core/model/peer_id.dart';

/// An in-memory radio that connects several [FakeTransport]s in an arbitrary
/// topology so the full mesh stack (routing, crypto, store-and-forward, file
/// transfer) can be exercised without real BLE hardware.
///
/// When [mtu] is set, frames are pushed through the *real* [L2Framing] split /
/// [L2Reassembler] reassemble path at that packet size, and [dropRate] of
/// packets are randomly dropped — modelling a lossy BLE link with a small MTU.
class FakeRadio {
  final Map<String, FakeTransport> nodes = {};
  final int? mtu;
  final double dropRate;
  final Random _rng;

  FakeRadio({this.mtu, this.dropRate = 0.0, int seed = 1})
      : _rng = Random(seed);

  FakeTransport create(PeerId id) {
    final t = FakeTransport(id, this);
    nodes[id.hex] = t;
    return t;
  }

  bool shouldDrop() => dropRate > 0 && _rng.nextDouble() < dropRate;

  /// Bring a bidirectional link up between two already-started nodes.
  void connect(PeerId a, PeerId b) {
    final ta = nodes[a.hex]!;
    final tb = nodes[b.hex]!;
    ta._addNeighbor(b);
    tb._addNeighbor(a);
  }

  void disconnect(PeerId a, PeerId b) {
    nodes[a.hex]?._removeNeighbor(b);
    nodes[b.hex]?._removeNeighbor(a);
  }
}

class FakeTransport implements MeshTransportInterface {
  final PeerId me;
  final FakeRadio radio;

  final _inbound = StreamController<InboundPacket>.broadcast();
  final _linkEvents = StreamController<LinkEvent>.broadcast();
  final _availability = StreamController<bool>.broadcast();
  final _rssi = StreamController<RssiSample>.broadcast();

  // linkId (== neighbour hex) -> neighbour id
  final Map<String, PeerId> _neighbours = {};
  // Per-sender reassemblers for the lossy/framed mode.
  final Map<String, L2Reassembler> _rx = {};
  bool _online = false;

  /// Optional test hook: return true to drop an outgoing frame (whole-frame
  /// mode), letting a test simulate e.g. a lost ACK.
  bool Function(Uint8List frameBytes)? dropOutgoing;

  FakeTransport(this.me, this.radio);

  L2Reassembler _reassemblerFor(String senderHex) =>
      _rx.putIfAbsent(senderHex, () => L2Reassembler());

  /// Test hook: inject an arbitrary already-reassembled frame as if it arrived
  /// from a peer. Used to fuzz the node with malformed/hostile input.
  void injectRaw(Uint8List frameBytes, {String linkId = 'attacker'}) {
    _inbound.add(InboundPacket(
        MeshLink(id: linkId, role: LinkRole.central), frameBytes));
  }

  @override
  Stream<InboundPacket> get inbound => _inbound.stream;
  @override
  Stream<LinkEvent> get linkEvents => _linkEvents.stream;
  @override
  int get linkCount => _neighbours.length;

  @override
  Stream<bool> get availabilityChanged => _availability.stream;

  /// Test hook: simulate the radio becoming (un)usable.
  void setAvailability(bool ok) => _availability.add(ok);

  @override
  Stream<RssiSample> get rssiSamples => _rssi.stream;

  /// Test hook: simulate a signal-strength reading for [peer].
  void emitRssi(PeerId peer, int rssi) => _rssi.add(RssiSample(peer, rssi));

  /// Test hook: what [ensureReady] reports (e.g. false while the OS
  /// permission prompt is still open).
  bool ready = true;

  @override
  RadioStatus get radioStatus =>
      ready ? RadioStatus.ready : RadioStatus.unknown;

  @override
  Future<bool> ensureReady() async => ready;

  @override
  Future<void> start() async {
    _online = true;
  }

  @override
  Future<void> stop() async {
    _online = false;
    _neighbours.clear();
  }

  /// Test hook: counts wake() calls so tests can assert foreground-resume
  /// re-announce behaviour.
  int wakeCount = 0;
  @override
  void wake() => wakeCount++;

  void _addNeighbor(PeerId other) {
    final linkId = other.hex;
    if (_neighbours.containsKey(linkId)) return;
    _neighbours[linkId] = other;
    if (_online) {
      _linkEvents
          .add(LinkEvent(MeshLink(id: linkId, role: LinkRole.central), true));
    }
  }

  void _removeNeighbor(PeerId other) {
    final linkId = other.hex;
    if (_neighbours.remove(linkId) != null) {
      _linkEvents
          .add(LinkEvent(MeshLink(id: linkId, role: LinkRole.central), false));
    }
  }

  @override
  Future<void> broadcast(Uint8List frameBytes, {String? exceptLinkId}) async {
    for (final entry in _neighbours.entries) {
      if (entry.key == exceptLinkId) continue;
      _deliver(entry.value, frameBytes);
    }
  }

  @override
  Future<void> sendToLink(String linkId, Uint8List frameBytes) async {
    final n = _neighbours[linkId];
    if (n != null) _deliver(n, frameBytes);
  }

  void _deliver(PeerId neighbour, Uint8List bytes) {
    if (dropOutgoing != null && dropOutgoing!(bytes)) return; // simulate loss
    final t = radio.nodes[neighbour.hex];
    if (t == null || !t._online) return;
    // From the neighbour's perspective, the link back to us is keyed by our id.
    final link = MeshLink(id: me.hex, role: LinkRole.central);

    if (radio.mtu == null) {
      // Whole-frame delivery (fast path for logic-only tests).
      t._inbound.add(InboundPacket(link, Uint8List.fromList(bytes)));
      return;
    }

    // Realistic path: split into MTU-sized packets, drop some, reassemble.
    final packets = L2Framing.split(bytes, radio.mtu!);
    final reassembler = t._reassemblerFor(me.hex);
    for (final p in packets) {
      if (radio.shouldDrop()) continue; // lost in the air
      final full = reassembler.offer(Uint8List.fromList(p));
      if (full != null) {
        t._inbound.add(InboundPacket(link, full));
      }
    }
  }
}
