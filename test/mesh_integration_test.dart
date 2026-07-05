import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/core/model/frame.dart';
import 'package:spot_link/core/model/peer_id.dart';
import 'package:spot_link/core/transfer/fast_lane.dart';

import 'fake_fast_lane.dart';

import 'fake_transport.dart';

/// Spins up a MeshNode backed by a fake transport and records its events.
class TestNode {
  final MeshNode node;
  final List<NodeEvent> events = [];
  TestNode(this.node) {
    node.events.listen(events.add);
  }

  Iterable<T> ofType<T>() => events.whereType<T>();
}

Future<TestNode> makeNode(
  FakeRadio radio,
  Identity id,
  String name, {
  FastLaneInterface? fastLane,
}) async {
  final transport = radio.create(id.peerId);
  final node = MeshNode(
    identity: id,
    displayName: name,
    transport: transport,
    fastLane: fastLane,
  );
  final tn = TestNode(node);
  await node.start();
  return tn;
}

/// Pump the event loop until [test] passes or we time out.
Future<T> waitFor<T extends NodeEvent>(
  TestNode n,
  bool Function(T) test, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final match = n.events.whereType<T>().where(test);
    if (match.isNotEmpty) return match.last;
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }
  throw TimeoutException('event ${T.toString()} not observed', timeout);
}

Future<void> settle() async =>
    Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  test('direct: A -> B text with delivery ack and E2E', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();

    final a = await makeNode(radio, idA, 'Alice');
    final b = await makeNode(radio, idB, 'Bob');

    // Pre-share keys (as if scanned via QR).
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));

    radio.connect(idA.peerId, idB.peerId);
    await settle();

    final msgId = await a.node.sendText(idB.peerId, '안녕 Bob!');
    expect(msgId, isNotNull);

    final received = await waitFor<TextReceived>(b, (e) => true);
    expect(received.text, '안녕 Bob!');
    expect(received.from, idA.peerId);

    // Alice should get an end-to-end delivery confirmation.
    final confirmed = await waitFor<DeliveryConfirmed>(
      a,
      (e) => e.msgId == msgId,
    );
    expect(confirmed.msgId, msgId);
  });

  test('unacked text is delivered the moment the link comes back', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'Alice');
    final b = await makeNode(radio, idB, 'Bob');
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));

    // Send while the link is down — nothing can flow yet.
    final msgId = await a.node.sendText(idB.peerId, '재회 후 도착해야 함');
    await settle();

    // The link comes back (e.g. iOS pending reconnect completed): the unacked
    // text must ride the fresh link immediately — link-up resend, no waiting
    // for the periodic retransmit tick.
    radio.connect(idA.peerId, idB.peerId);
    final rx = await waitFor<TextReceived>(b, (e) => true);
    expect(rx.text, '재회 후 도착해야 함');
    final confirmed =
        await waitFor<DeliveryConfirmed>(a, (e) => e.msgId == msgId);
    expect(confirmed.msgId, msgId);
  });

  test('ANNOUNCE teaches neighbours each others keys', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'Alice');
    final b = await makeNode(radio, idB, 'Bob');

    radio.connect(idA.peerId, idB.peerId);

    // Both learn each other via ANNOUNCE (no addContact needed).
    final annA = await waitFor<PeerAnnounced>(a, (e) => true);
    expect(annA.contact.peerId, idB.peerId);
    expect(annA.contact.displayName, 'Bob');

    // Now Alice can message Bob using only the announced key.
    await settle();
    final msgId = await a.node.sendText(idB.peerId, 'hi via announce');
    expect(msgId, isNotNull);
    final rx = await waitFor<TextReceived>(b, (e) => true);
    expect(rx.text, 'hi via announce');
  });

  test(
    'presence floods over relays: A sees C at 2 hops (A-B-C line)',
    () async {
      final radio = FakeRadio();
      final idA = await Identity.generate();
      final idB = await Identity.generate();
      final idC = await Identity.generate();
      final a = await makeNode(radio, idA, 'Alice');
      final b = await makeNode(radio, idB, 'Bridge');
      final c = await makeNode(radio, idC, 'Carol');

      // Line topology: A <-> B <-> C (A and C are out of radio range).
      radio.connect(idA.peerId, idB.peerId);
      radio.connect(idB.peerId, idC.peerId);

      // A hears B directly (1 hop) and C via B's relay (2 hops).
      final annB = await waitFor<PeerAnnounced>(
        a,
        (e) => e.contact.peerId == idB.peerId,
      );
      expect(annB.hops, 1);
      final annC = await waitFor<PeerAnnounced>(
        a,
        (e) => e.contact.peerId == idC.peerId,
      );
      expect(annC.hops, 2);
      expect(annC.contact.displayName, 'Carol');

      // The relayed announce carried C's keys: A can message C with no QR
      // and no manual key exchange, relayed end-to-end encrypted through B.
      await settle();
      final msgId = await a.node.sendText(idC.peerId, '2홉 안녕!');
      expect(msgId, isNotNull);
      final rx = await waitFor<TextReceived>(c, (e) => true);
      expect(rx.text, '2홉 안녕!');
      expect(rx.from, idA.peerId);
      // B relayed but never saw the plaintext (no TextReceived on B).
      expect(b.ofType<TextReceived>(), isEmpty);
    },
  );

  test('multi-hop: A -> R -> B (A and B not directly linked)', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idR = await Identity.generate();
    final idB = await Identity.generate();

    final a = await makeNode(radio, idA, 'Alice');
    final r = await makeNode(radio, idR, 'Relay');
    final b = await makeNode(radio, idB, 'Bob');

    // Line topology: A - R - B.
    radio.connect(idA.peerId, idR.peerId);
    radio.connect(idR.peerId, idB.peerId);
    await settle();

    // A and B know each other's keys via QR; R does NOT (cannot read content).
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));

    final msgId = await a.node.sendText(idB.peerId, 'relayed hello');
    expect(msgId, isNotNull);

    final rx = await waitFor<TextReceived>(
      b,
      (e) => true,
      timeout: const Duration(seconds: 3),
    );
    expect(rx.text, 'relayed hello');
    expect(rx.from, idA.peerId);

    // Relay never surfaced the plaintext.
    expect(r.ofType<TextReceived>(), isEmpty);

    // Delivery ack travels back A <- R <- B.
    await waitFor<DeliveryConfirmed>(
      a,
      (e) => e.msgId == msgId,
      timeout: const Duration(seconds: 3),
    );
  });

  test('store-and-forward: B receives after connecting later', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idR = await Identity.generate();
    final idB = await Identity.generate();

    final a = await makeNode(radio, idA, 'Alice');
    final r = await makeNode(radio, idR, 'Relay');
    final b = await makeNode(radio, idB, 'Bob');

    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));

    // Only A <-> R connected. B is away.
    radio.connect(idA.peerId, idR.peerId);
    await settle();

    final msgId = await a.node.sendText(idB.peerId, 'catch you later');
    expect(msgId, isNotNull);
    await settle();

    // R should be holding the frame for later (store-and-forward).
    expect(r.node.store.contains(msgId!), isTrue);
    // B has not received anything yet.
    expect(b.ofType<TextReceived>(), isEmpty);

    // Later, B comes into range of R -> HAVE/WANT sync delivers it.
    radio.connect(idR.peerId, idB.peerId);

    final rx = await waitFor<TextReceived>(
      b,
      (e) => true,
      timeout: const Duration(seconds: 3),
    );
    expect(rx.text, 'catch you later');
  });

  test('multi-hop file transfer with integrity', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idR = await Identity.generate();
    final idB = await Identity.generate();

    final a = await makeNode(radio, idA, 'Alice');
    await makeNode(radio, idR, 'Relay');
    final b = await makeNode(radio, idB, 'Bob');

    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));

    radio.connect(idA.peerId, idR.peerId);
    radio.connect(idR.peerId, idB.peerId);
    await settle();

    final rnd = Random(42);
    final fileBytes = Uint8List.fromList(
      List.generate(9000, (_) => rnd.nextInt(256)),
    );

    final tid = await a.node.sendFile(
      idB.peerId,
      bytes: fileBytes,
      name: 'secret.bin',
      mime: 'application/octet-stream',
      chunkSize: 512,
    );
    expect(tid, isNotNull);

    final got = await waitFor<FileReceived>(
      b,
      (e) => true,
      timeout: const Duration(seconds: 5),
    );
    expect(got.meta.name, 'secret.bin');
    expect(got.bytes, fileBytes);
    expect(got.from, idB.peerId == got.from ? got.from : idA.peerId);
  });

  test(
    'fast lane: large file goes over Wi-Fi, sender confirmed delivered',
    () async {
      final radio = FakeRadio();
      final medium = FakeFastMedium();
      final idA = await Identity.generate();
      final idB = await Identity.generate();
      final a = await makeNode(
        radio,
        idA,
        'Alice',
        fastLane: medium.endpoint({FastLaneKind.wifiAware}),
      );
      final b = await makeNode(
        radio,
        idB,
        'Bob',
        fastLane: medium.endpoint({FastLaneKind.wifiAware}),
      );
      a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
      b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
      radio.connect(idA.peerId, idB.peerId);
      await settle();

      // ≥ fastLaneMinBytes so the fast lane is attempted.
      final rnd = Random(7);
      final fileBytes = Uint8List.fromList(
        List.generate(300 * 1024, (_) => rnd.nextInt(256)),
      );

      final tid = await a.node.sendFile(
        idB.peerId,
        bytes: fileBytes,
        name: 'big.bin',
        mime: 'application/octet-stream',
      );
      expect(tid, isNotNull);

      final got = await waitFor<FileReceived>(
        b,
        (e) => true,
        timeout: const Duration(seconds: 5),
      );
      expect(got.bytes, fileBytes); // exact bytes over the fast lane
      // No BLE chunks were used: the file never entered the BLE receiver's
      // chunk store (it completed via the fast path).
      final delivered = await waitFor<DeliveryConfirmed>(
        a,
        (e) => e.msgId == tid,
        timeout: const Duration(seconds: 5),
      );
      expect(delivered.msgId, tid);
    },
  );

  test('fast lane: falls back to BLE when connect fails', () async {
    final radio = FakeRadio();
    final medium = FakeFastMedium()..failConnect = true; // Wi-Fi dial fails
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(
      radio,
      idA,
      'Alice',
      fastLane: medium.endpoint({FastLaneKind.wifiAware}),
    );
    final b = await makeNode(
      radio,
      idB,
      'Bob',
      fastLane: medium.endpoint({FastLaneKind.wifiAware}),
    );
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await settle();

    final rnd = Random(8);
    final fileBytes = Uint8List.fromList(
      List.generate(300 * 1024, (_) => rnd.nextInt(256)),
    );
    final tid = await a.node.sendFile(
      idB.peerId,
      bytes: fileBytes,
      name: 'fb.bin',
      mime: 'application/octet-stream',
    );

    // Despite the Wi-Fi failure, BLE chunking delivers the exact file.
    final got = await waitFor<FileReceived>(
      b,
      (e) => true,
      timeout: const Duration(seconds: 20),
    );
    expect(got.bytes, fileBytes);
    expect(tid, isNotNull);
  });

  test('fast lane: cross-capability mismatch stays on BLE', () async {
    final radio = FakeRadio();
    final medium = FakeFastMedium();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    // A offers Wi-Fi Aware, B only Multipeer → no shared transport.
    final a = await makeNode(
      radio,
      idA,
      'Alice',
      fastLane: medium.endpoint({FastLaneKind.wifiAware}),
    );
    final b = await makeNode(
      radio,
      idB,
      'Bob',
      fastLane: medium.endpoint({FastLaneKind.multipeer}),
    );
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await settle();

    final rnd = Random(9);
    final fileBytes = Uint8List.fromList(
      List.generate(300 * 1024, (_) => rnd.nextInt(256)),
    );
    await a.node.sendFile(
      idB.peerId,
      bytes: fileBytes,
      name: 'mm.bin',
      mime: 'application/octet-stream',
    );

    final got = await waitFor<FileReceived>(
      b,
      (e) => true,
      timeout: const Duration(seconds: 20),
    );
    expect(got.bytes, fileBytes); // delivered over BLE
  });

  test(
    'signed receipt purges relay copies; forged receipt is rejected',
    () async {
      final radio = FakeRadio();
      final idA = await Identity.generate();
      final idB = await Identity.generate();
      final idC = await Identity.generate();
      final a = await makeNode(radio, idA, 'Alice');
      final b = await makeNode(radio, idB, 'Bridge');
      final c = await makeNode(radio, idC, 'Carol');

      // A-B connected; C is away. A/C know each other (e.g. QR) — C needs A's
      // key to decrypt on arrival (A's announce only floods 3 hops / 15s).
      a.node.addContact(ContactIdentity.fromBundle(idC.publicBundle));
      c.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
      radio.connect(idA.peerId, idB.peerId);
      await settle();

      final msgId = (await a.node.sendText(idC.peerId, '전파 삭제 테스트'))!;
      await settle();
      // B relays + parks a copy for C. Keep its bytes for the zombie test.
      expect(b.node.store.contains(msgId), isTrue);
      final parkedBytes = b.node.store.frameFor(msgId)!.encode();

      // A forged receipt from B (knows the msgId but is not the addressee)
      // must NOT bury the message.
      final forged = Frame.create(
        type: FrameType.receipt,
        ttl: 8,
        src: idB.peerId,
        dst: PeerId.broadcast,
        payload: Uint8List(80), // garbage signature
      );
      radio.nodes[idB.peerId.hex]!.injectRaw(forged.encode());
      await settle();
      expect(b.node.store.contains(msgId), isTrue);

      // C shows up next to B: parked text is handed over, C floods a SIGNED
      // receipt, and every carrier drops its copy.
      radio.connect(idB.peerId, idC.peerId);
      final rx = await waitFor<TextReceived>(c, (e) => e.msgId == msgId);
      expect(rx.text, '전파 삭제 테스트');
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while ((b.node.store.contains(msgId) || a.node.store.contains(msgId)) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        b.node.store.contains(msgId),
        isFalse,
        reason: '중계 노드의 사본이 서명 RECEIPT로 정리되어야 한다',
      );
      expect(a.node.store.contains(msgId), isFalse, reason: '발신자 사본도 정리되어야 한다');

      // Zombie block: an offline phone resurfacing with the ORIGINAL frame
      // must not get it re-stored/re-relayed at B (tombstoned).
      radio.nodes[idB.peerId.hex]!.injectRaw(parkedBytes);
      await settle();
      expect(b.node.store.contains(msgId), isFalse);
    },
  );

  test('message from an unknown sender is parked and delivered once their '
      'ANNOUNCE arrives', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'Alice');
    final b = await makeNode(radio, idB, 'Bob');

    // A knows B, but B has never heard of A. Craft the encrypted text and
    // inject it into B directly (as if it arrived from far away, beyond A's
    // announce range).
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    final msgId = (await a.node.sendText(idB.peerId, '먼 곳에서 온 메시지'))!;
    final textBytes = a.node.store.frameFor(msgId)!.encode();
    radio.nodes[idB.peerId.hex]!.injectRaw(textBytes);
    await settle();

    // Not delivered (no key), but parked — not burned.
    expect(b.ofType<TextReceived>(), isEmpty);
    expect(b.node.store.contains(msgId), isTrue);

    // Now A comes into range: its ANNOUNCE teaches B the key, and the parked
    // message is delivered.
    radio.connect(idA.peerId, idB.peerId);
    final rx = await waitFor<TextReceived>(b, (e) => e.msgId == msgId);
    expect(rx.text, '먼 곳에서 온 메시지');
    // Delivered + receipted: the parked copy is gone.
    await settle();
    expect(b.node.store.contains(msgId), isFalse);
  });

  test('duplicate flooding does not double-deliver', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idR1 = await Identity.generate();
    final idR2 = await Identity.generate();
    final idB = await Identity.generate();

    final a = await makeNode(radio, idA, 'Alice');
    await makeNode(radio, idR1, 'R1');
    await makeNode(radio, idR2, 'R2');
    final b = await makeNode(radio, idB, 'Bob');

    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));

    // Diamond: A connects to R1 and R2; both connect to B. Two paths.
    radio.connect(idA.peerId, idR1.peerId);
    radio.connect(idA.peerId, idR2.peerId);
    radio.connect(idR1.peerId, idB.peerId);
    radio.connect(idR2.peerId, idB.peerId);
    await settle();

    await a.node.sendText(idB.peerId, 'once only');
    await settle();
    await settle();

    // Despite two disjoint paths, dedup means exactly one delivery.
    expect(b.ofType<TextReceived>().length, 1);
  });
}
