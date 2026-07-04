import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/core/transfer/lan_socket_fast_lane.dart';

import 'fake_transport.dart';

/// End-to-end over a REAL loopback TCP socket (not a fake): proves the LAN
/// fast lane negotiates over BLE and moves the bytes over an actual socket.
class TestNode {
  final MeshNode node;
  final List<NodeEvent> events = [];
  TestNode(this.node) {
    node.events.listen(events.add);
  }
}

Future<T> waitFor<T extends NodeEvent>(TestNode n, bool Function(T) t,
    {Duration timeout = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final m = n.events.whereType<T>().where(t);
    if (m.isNotEmpty) return m.last;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('event ${T.toString()} not observed');
}

void main() {
  test('LAN fast lane transfers a large file over a real loopback socket',
      () async {
    // Bind + advertise loopback so both nodes talk over real 127.0.0.1 TCP.
    LanSocketFastLane lan() => LanSocketFastLane(
          bindHost: InternetAddress.loopbackIPv4,
          localAddresses: () async => [InternetAddress.loopbackIPv4],
        );

    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = TestNode(MeshNode(
        identity: idA,
        displayName: 'A',
        transport: radio.create(idA.peerId),
        fastLane: lan()));
    final b = TestNode(MeshNode(
        identity: idB,
        displayName: 'B',
        transport: radio.create(idB.peerId),
        fastLane: lan()));
    await a.node.start();
    await b.node.start();
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final rnd = Random(123);
    final fileBytes = Uint8List.fromList(
        List.generate(500 * 1024, (_) => rnd.nextInt(256)));

    final tid = await a.node.sendFile(idB.peerId,
        bytes: fileBytes, name: 'photo.jpg', mime: 'image/jpeg');
    expect(tid, isNotNull);

    final got = await waitFor<FileReceived>(b, (e) => true);
    expect(got.meta.name, 'photo.jpg');
    expect(got.bytes, fileBytes); // exact bytes over real TCP
    expect(got.from, idA.peerId);

    // Sender flips to delivered via the reused BLE completion ACK.
    final done = await waitFor<DeliveryConfirmed>(a, (e) => e.msgId == tid);
    expect(done.msgId, tid);

    await a.node.dispose();
    await b.node.dispose();
  });

  test('LAN fast lane with no network address stays on BLE', () async {
    // localAddresses empty ⇒ capabilities empty ⇒ never attempts fast lane.
    final noNet = LanSocketFastLane(localAddresses: () async => []);
    // capabilities is a fixed set, but prepareInbound returns null with no
    // address, so the sender times out and BLE carries it.
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = TestNode(MeshNode(
        identity: idA,
        displayName: 'A',
        transport: radio.create(idA.peerId),
        fastLane: noNet));
    final b = TestNode(MeshNode(
        identity: idB,
        displayName: 'B',
        transport: radio.create(idB.peerId),
        fastLane: LanSocketFastLane(localAddresses: () async => [])));
    await a.node.start();
    await b.node.start();
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final rnd = Random(5);
    final fileBytes = Uint8List.fromList(
        List.generate(300 * 1024, (_) => rnd.nextInt(256)));
    await a.node.sendFile(idB.peerId,
        bytes: fileBytes, name: 'x.bin', mime: 'application/octet-stream');

    final got = await waitFor<FileReceived>(b, (e) => true,
        timeout: const Duration(seconds: 30));
    expect(got.bytes, fileBytes); // delivered over BLE fallback

    await a.node.dispose();
    await b.node.dispose();
  });
}
