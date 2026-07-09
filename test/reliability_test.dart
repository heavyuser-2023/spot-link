import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/core/model/frame.dart';

import 'dart:typed_data';

import 'fake_transport.dart';

class TestNode {
  final MeshNode node;
  final List<NodeEvent> events = [];
  TestNode(this.node) {
    node.events.listen(events.add);
  }

  Iterable<T> ofType<T>() => events.whereType<T>();
}

Future<TestNode> makeNode(FakeRadio radio, Identity id, String name,
    {Duration retransmit = const Duration(milliseconds: 40),
    int maxAttempts = 3}) async {
  final node = MeshNode(
    identity: id,
    displayName: name,
    transport: radio.create(id.peerId),
    retransmitInterval: retransmit,
    maxTextAttempts: maxAttempts,
  );
  final tn = TestNode(node);
  await node.start();
  return tn;
}

Future<T> waitFor<T extends NodeEvent>(TestNode n, bool Function(T) test,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final m = n.events.whereType<T>().where(test);
    if (m.isNotEmpty) return m.last;
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }
  throw TimeoutException('event ${T.toString()} not observed', timeout);
}

Future<void> settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('text with a route is delivered and never reported failed', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'A');
    final b = await makeNode(radio, idB, 'B');
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await settle();

    final msgId = await a.node.sendText(idB.peerId, 'hi');
    await waitFor<DeliveryConfirmed>(a, (e) => e.msgId == msgId);
    // Give the retransmit timer several ticks; it must NOT fire a failure.
    await settle(250);
    expect(a.ofType<TextDeliveryFailed>(), isEmpty);
  });

  test('text with no route eventually reports TextDeliveryFailed', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'A',
        retransmit: const Duration(milliseconds: 40), maxAttempts: 3);
    // Know B's key but have no link to anyone.
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));

    final msgId = await a.node.sendText(idB.peerId, 'into the void');
    final failed =
        await waitFor<TextDeliveryFailed>(a, (e) => e.msgId == msgId);
    expect(failed.msgId, msgId);
    // Giving up on LIVE retries must not evict the frame from the durable
    // store — it keeps riding along for eventual (DTN) delivery.
    expect(a.node.store.contains(msgId!), isTrue);
  });

  test('queued text delivers on a later encounter and confirms late', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'A',
        retransmit: const Duration(milliseconds: 30), maxAttempts: 2);
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));

    // No route: live retries exhaust and the text is parked (queued).
    final msgId = await a.node.sendText(idB.peerId, '언젠가 도착');
    await waitFor<TextDeliveryFailed>(a, (e) => e.msgId == msgId);

    // B appears later: HAVE/WANT sync hands over the parked text, and the
    // late ACK flips the sender to delivered.
    final b = await makeNode(radio, idB, 'B');
    radio.connect(idA.peerId, idB.peerId);
    final rx = await waitFor<TextReceived>(b, (e) => e.msgId == msgId);
    expect(rx.text, '언젠가 도착');
    final confirmed =
        await waitFor<DeliveryConfirmed>(a, (e) => e.msgId == msgId);
    expect(confirmed.msgId, msgId);
    // Delivered: the parked copy is finally released from the store.
    expect(a.node.store.contains(msgId!), isFalse);
  });

  test('retransmit stops once delivered (no failure after ack)', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'A',
        retransmit: const Duration(milliseconds: 30), maxAttempts: 10);
    final b = await makeNode(radio, idB, 'B');
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await settle();

    final msgId = await a.node.sendText(idB.peerId, 'ok');
    await waitFor<DeliveryConfirmed>(a, (e) => e.msgId == msgId);
    final deliveredCount = b.ofType<TextReceived>().length;
    // Even though retransmit ticks quickly, dedup + ack means exactly one
    // delivery on the receiver.
    await settle(200);
    expect(b.ofType<TextReceived>().length, deliveredCount);
    expect(deliveredCount, 1);
  });

  test('recovers when the recipient\'s first ACK is lost (re-ACK on retransmit)',
      () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'A',
        retransmit: const Duration(milliseconds: 40), maxAttempts: 10);
    final b = await makeNode(radio, idB, 'B');
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));

    // Drop B's FIRST outgoing ACK frame; later ACKs get through.
    var droppedOne = false;
    radio.nodes[idB.peerId.hex]!.dropOutgoing = (bytes) {
      final f = Frame.decode(bytes);
      if (!droppedOne && f.type == FrameType.ack) {
        droppedOne = true;
        return true;
      }
      return false;
    };

    radio.connect(idA.peerId, idB.peerId);
    await settle();

    final msgId = await a.node.sendText(idB.peerId, 'hello');
    // B received & displayed it, but its first ACK was dropped. A retransmits;
    // B must re-ACK the duplicate so A can confirm rather than fail.
    final ok =
        await waitFor<DeliveryConfirmed>(a, (e) => e.msgId == msgId);
    expect(ok.msgId, msgId);
    await settle(150);
    expect(a.ofType<TextDeliveryFailed>(), isEmpty);
    expect(droppedOne, isTrue); // ensure the ACK-loss path was actually exercised
    expect(b.ofType<TextReceived>().length, 1); // delivered exactly once
  });

  test('display name change re-announces to neighbours', () async {
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'Alice');
    final b = await makeNode(radio, idB, 'Bob');
    radio.connect(idA.peerId, idB.peerId);
    await waitFor<PeerAnnounced>(b, (e) => e.contact.displayName == 'Alice');

    await a.node.updateDisplayName('Alice2');
    final renamed =
        await waitFor<PeerAnnounced>(b, (e) => e.contact.displayName == 'Alice2');
    expect(renamed.contact.peerId, idA.peerId);
  });

  test('a garbled (undecryptable) delivery is re-requested and still arrives',
      () async {
    // Regression: a message that the router marked "seen" (loop prevention)
    // but that FAILED to decrypt (a corrupt payload from a flaky link) used to
    // be lost forever — the seen-cache stopped HAVE/WANT from re-requesting it
    // AND made the router drop any resend as a duplicate. (Observed live: 3
    // texts sent, the middle one never arrived.)
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = await makeNode(radio, idA, 'A',
        retransmit: const Duration(milliseconds: 30), maxAttempts: 2);
    final b = await makeNode(radio, idB, 'B');
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));

    // A composes a text while offline: it's parked in A's durable store.
    final msgId = await a.node.sendText(idB.peerId, '가운데 메시지');
    await waitFor<TextDeliveryFailed>(a, (e) => e.msgId == msgId);
    final frame = a.node.store.frameFor(msgId!)!;

    // B receives a CORRUPTED copy first: the router marks the id seen,
    // decryption fails, and nothing reaches the app.
    final bytes = Uint8List.fromList(frame.encode());
    bytes[bytes.length - 1] ^= 0xFF; // flip a ciphertext byte
    radio.nodes[idB.peerId.hex]!.injectRaw(bytes);
    await settle(80);
    expect(b.ofType<TextReceived>(), isEmpty); // garbled — not delivered

    // A real link forms: despite the id already being "seen", HAVE/WANT must
    // fetch a clean copy and B must finally receive it exactly once.
    radio.connect(idA.peerId, idB.peerId);
    final rx = await waitFor<TextReceived>(b, (e) => e.msgId == msgId);
    expect(rx.text, '가운데 메시지');
    final confirmed =
        await waitFor<DeliveryConfirmed>(a, (e) => e.msgId == msgId);
    expect(confirmed.msgId, msgId);
    await settle(120);
    expect(b.ofType<TextReceived>().length, 1); // no duplicate delivery
  });
}
