import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/core/model/frame.dart';

import 'fake_transport.dart';

class TestNode {
  final MeshNode node;
  final List<NodeEvent> events = [];
  TestNode(this.node) {
    node.events.listen(events.add);
  }

  Iterable<T> ofType<T>() => events.whereType<T>();
}

Future<TestNode> makeNode(FakeRadio radio, Identity id, String name) async {
  final node = MeshNode(
      identity: id, displayName: name, transport: radio.create(id.peerId));
  final tn = TestNode(node);
  await node.start();
  return tn;
}

Future<T> waitFor<T extends NodeEvent>(
  TestNode n,
  bool Function(T) test, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final match = n.events.whereType<T>().where(test);
    if (match.isNotEmpty) return match.last;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TimeoutException('event ${T.toString()} not observed', timeout);
}

Future<void> settle([int ms = 80]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('Real L2 framing (small MTU, lossless)', () {
    test('long multi-packet text reassembles direct', () async {
      final radio = FakeRadio(mtu: 20); // forces many packets/frame
      final idA = await Identity.generate();
      final idB = await Identity.generate();
      final a = await makeNode(radio, idA, 'A');
      final b = await makeNode(radio, idB, 'B');
      a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
      b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
      radio.connect(idA.peerId, idB.peerId);
      await settle();

      final longText = '가나다라마바사' * 40; // ~280 chars -> many L2 packets
      await a.node.sendText(idB.peerId, longText);

      final rx = await waitFor<TextReceived>(b, (e) => true);
      expect(rx.text, longText);
    });

    test('multi-packet text over multi-hop with tiny MTU', () async {
      final radio = FakeRadio(mtu: 24);
      final idA = await Identity.generate();
      final idR = await Identity.generate();
      final idB = await Identity.generate();
      final a = await makeNode(radio, idA, 'A');
      await makeNode(radio, idR, 'R');
      final b = await makeNode(radio, idB, 'B');
      a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
      b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
      radio.connect(idA.peerId, idR.peerId);
      radio.connect(idR.peerId, idB.peerId);
      await settle();

      final text = 'The quick brown fox jumps over the lazy dog. ' * 6;
      await a.node.sendText(idB.peerId, text);
      final rx = await waitFor<TextReceived>(b, (e) => true);
      expect(rx.text, text);
    });
  });

  group('Lossy link with retransmission', () {
    test('file transfer recovers under 10% packet loss', () async {
      // MTU 185 (typical after negotiation) with 10% per-packet loss and a
      // chunk size that fits in ~1-2 L2 packets — realistic BLE conditions.
      final radio = FakeRadio(mtu: 185, dropRate: 0.10, seed: 7);
      final idA = await Identity.generate();
      final idB = await Identity.generate();
      final a = await makeNode(radio, idA, 'A');
      final b = await makeNode(radio, idB, 'B');
      a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
      b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
      radio.connect(idA.peerId, idB.peerId);
      await settle();

      final rnd = Random(3);
      final data =
          Uint8List.fromList(List.generate(4096, (_) => rnd.nextInt(256)));
      await a.node.sendFile(idB.peerId,
          bytes: data, name: 'lossy.bin', mime: 'x', chunkSize: 128);

      final got = await waitFor<FileReceived>(b, (e) => true,
          timeout: const Duration(seconds: 25));
      expect(got.bytes, data);
    });

    test('tail loss does not stall: 23-chunk file (not a multiple of 16)',
        () async {
      // Chunk count is deliberately NOT a multiple of 16, so the every-16 ACK
      // alone would never cover the tail — only the recovery timer can finish
      // it. With moderate loss this must still complete.
      final radio = FakeRadio(mtu: 185, dropRate: 0.12, seed: 11);
      final idA = await Identity.generate();
      final idB = await Identity.generate();
      final a = await makeNode(radio, idA, 'A');
      final b = await makeNode(radio, idB, 'B');
      a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
      b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
      radio.connect(idA.peerId, idB.peerId);
      await settle();

      final rnd = Random(5);
      // 23 chunks (not a multiple of 16).
      final data =
          Uint8List.fromList(List.generate(23 * 120, (_) => rnd.nextInt(256)));
      await a.node.sendFile(idB.peerId,
          bytes: data, name: 't.bin', mime: 'x', chunkSize: 120);

      final got = await waitFor<FileReceived>(b, (e) => true,
          timeout: const Duration(seconds: 25));
      expect(got.bytes, data);
    });
  });

  group('Adversarial / malformed input does not crash the node', () {
    late FakeRadio radio;
    late TestNode a;
    late TestNode b;
    late Identity idA;
    late Identity idB;
    late FakeTransport bTransport;

    setUp(() async {
      radio = FakeRadio();
      idA = await Identity.generate();
      idB = await Identity.generate();
      final ta = radio.create(idA.peerId);
      bTransport = radio.create(idB.peerId);
      final nodeA = MeshNode(identity: idA, displayName: 'A', transport: ta);
      final nodeB =
          MeshNode(identity: idB, displayName: 'B', transport: bTransport);
      a = TestNode(nodeA);
      b = TestNode(nodeB);
      await nodeA.start();
      await nodeB.start();
      a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
      b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    });

    Future<void> assertStillWorks() async {
      // Connect and verify a legit message still flows after the abuse.
      radio.connect(idA.peerId, idB.peerId);
      await settle();
      await a.node.sendText(idB.peerId, 'still alive');
      final rx = await waitFor<TextReceived>(b, (e) => e.text == 'still alive');
      expect(rx.text, 'still alive');
    }

    test('random garbage frames are ignored', () async {
      final rnd = Random(1);
      for (var i = 0; i < 200; i++) {
        final len = rnd.nextInt(80);
        bTransport.injectRaw(
            Uint8List.fromList(List.generate(len, (_) => rnd.nextInt(256))));
      }
      await settle();
      await assertStillWorks();
    });

    test('malformed unencrypted ACK (1-byte payload) does not crash', () async {
      // This is the exact HIGH-severity crash vector: ack kind byte, no id.
      final evil = Frame.create(
        type: FrameType.ack,
        ttl: 3,
        src: idA.peerId,
        dst: idB.peerId,
        payload: Uint8List.fromList([0]), // _AckKind.message, but no msgId
        flags: 0, // unencrypted
      );
      bTransport.injectRaw(evil.encode());
      // File-ack variant, truncated.
      final evil2 = Frame.create(
        type: FrameType.ack,
        ttl: 3,
        src: idA.peerId,
        dst: idB.peerId,
        payload: Uint8List.fromList([1, 9, 9]),
        flags: 0,
      );
      bTransport.injectRaw(evil2.encode());
      await settle();
      await assertStillWorks();
    });

    test('encrypted frame from unknown sender is dropped, not fatal', () async {
      final stranger = await Identity.generate();
      final frame = Frame.create(
        type: FrameType.text,
        ttl: 3,
        src: stranger.peerId,
        dst: idB.peerId,
        payload: Uint8List.fromList([1, 2, 3, 4, 5]),
        flags: FrameFlags.encrypted,
      );
      bTransport.injectRaw(frame.encode());
      await settle();
      await assertStillWorks();
    });

    test('truncated file chunk / meta do not crash', () async {
      for (final type in [FrameType.fileMeta, FrameType.fileChunk]) {
        final f = Frame.create(
          type: type,
          ttl: 3,
          src: idA.peerId,
          dst: idB.peerId,
          payload: Uint8List.fromList([1, 2]), // too short after "decrypt"
          flags: 0, // unencrypted so it's parsed directly
        );
        bTransport.injectRaw(f.encode());
      }
      await settle();
      await assertStillWorks();
    });
  });

  group('TTL exhaustion in a line of nodes', () {
    test('message dies before reaching a too-distant node', () async {
      // Line: A - R1 - R2 - R3 - B  (B is 4 hops from A)
      final radio = FakeRadio();
      final ids =
          await Future.wait(List.generate(5, (_) => Identity.generate()));
      final nodes = <TestNode>[];
      for (var i = 0; i < 5; i++) {
        nodes.add(await makeNode(radio, ids[i], 'N$i'));
      }
      final a = nodes[0];
      final b = nodes[4];
      a.node.addContact(ContactIdentity.fromBundle(ids[4].publicBundle));
      b.node.addContact(ContactIdentity.fromBundle(ids[0].publicBundle));
      for (var i = 0; i < 4; i++) {
        radio.connect(ids[i].peerId, ids[i + 1].peerId);
      }
      await settle();

      // TTL 2: A(2)->R1 relays as 1 ->R2 relays as 0 -> dropped. Never reaches B.
      final frame = a.node.router.originate(
        type: FrameType.text,
        dst: ids[4].peerId,
        payload: await a.node.crypto
            .encrypt(Uint8List.fromList('nope'.codeUnits), ids[4].kexPublic),
        flags: FrameFlags.encrypted,
        ttl: 2,
      );
      // Manually broadcast with the small TTL (sendText uses the default ttl;
      // here we exercise the low-ttl path directly).
      await a.node.transport.broadcast(frame.encode());
      await settle(300);
      expect(b.ofType<TextReceived>(), isEmpty);
    });

    test('same line delivers when ttl is sufficient', () async {
      final radio = FakeRadio();
      final ids =
          await Future.wait(List.generate(5, (_) => Identity.generate()));
      final nodes = <TestNode>[];
      for (var i = 0; i < 5; i++) {
        nodes.add(await makeNode(radio, ids[i], 'N$i'));
      }
      final a = nodes[0];
      final b = nodes[4];
      a.node.addContact(ContactIdentity.fromBundle(ids[4].publicBundle));
      b.node.addContact(ContactIdentity.fromBundle(ids[0].publicBundle));
      for (var i = 0; i < 4; i++) {
        radio.connect(ids[i].peerId, ids[i + 1].peerId);
      }
      await settle();

      await a.node.sendText(ids[4].peerId, 'reaches you'); // default ttl 7
      final rx = await waitFor<TextReceived>(b, (e) => true,
          timeout: const Duration(seconds: 5));
      expect(rx.text, 'reaches you');
    });
  });

  group('Frame decode never throws non-FormatException on garbage', () {
    test('fuzz random bytes', () {
      final rnd = Random(99);
      for (var i = 0; i < 5000; i++) {
        final len = rnd.nextInt(120);
        final bytes =
            Uint8List.fromList(List.generate(len, (_) => rnd.nextInt(256)));
        try {
          Frame.decode(bytes);
        } on FormatException {
          // acceptable
        } catch (e) {
          fail('Frame.decode threw ${e.runtimeType} on garbage: $e');
        }
      }
    });
  });
}
