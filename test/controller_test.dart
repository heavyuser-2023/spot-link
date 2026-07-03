import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spot_link/app/mesh_controller.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/data/app_database.dart';
import 'package:spot_link/data/identity_store.dart';
import 'package:spot_link/data/models.dart';

import 'fake_transport.dart';

/// Routes path_provider to the test temp dir so the controller's file
/// save/load paths work without a real platform channel.
class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  var counter = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('spotlink_ctrl');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<(MeshController, Identity)> build() async {
    final id = await Identity.generate();
    final radio = FakeRadio();
    final node = MeshNode(
        identity: id, displayName: 'Me', transport: radio.create(id.peerId));
    final c = MeshController(
      identity: id,
      displayName: 'Me',
      db: AppDatabase(overridePath: p.join(tmp.path, 'c${counter++}.db')),
      identityStore: IdentityStore(),
      node: node,
    );
    await c.init();
    return (c, id);
  }

  test('auto-starts once the adapter becomes usable (first-run permission)',
      () async {
    final id = await Identity.generate();
    final radio = FakeRadio();
    final t = radio.create(id.peerId);
    t.ready = false; // OS permission prompt still on screen
    final node =
        MeshNode(identity: id, displayName: 'Me', transport: t);
    final c = MeshController(
      identity: id,
      displayName: 'Me',
      db: AppDatabase(overridePath: p.join(tmp.path, 'c${counter++}.db')),
      identityStore: IdentityStore(),
      node: node,
    );
    await c.init();
    expect(c.started, isFalse);
    expect(c.lastError, isNotNull);

    // The user grants the permission: the adapter flips to poweredOn.
    t.ready = true;
    t.setAvailability(true);
    await pumpEventQueue();

    expect(c.started, isTrue);
    expect(c.lastError, isNull);

    await c.node.dispose();
    c.dispose();
  });

  test('file attach: bubble appears immediately and completes on both ends',
      () async {
    final ida = await Identity.generate();
    final idb = await Identity.generate();
    final radio = FakeRadio();
    MeshController make(Identity id, String name, FakeTransport t) =>
        MeshController(
          identity: id,
          displayName: name,
          db: AppDatabase(overridePath: p.join(tmp.path, 'c${counter++}.db')),
          identityStore: IdentityStore(),
          node: MeshNode(identity: id, displayName: name, transport: t),
        );
    final ca = make(ida, 'A', radio.create(ida.peerId));
    final cb = make(idb, 'B', radio.create(idb.peerId));
    await ca.init();
    await cb.init();
    radio.connect(ida.peerId, idb.peerId);
    // Link-up ANNOUNCE teaches both sides the peer's keys.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Both users are looking at the chat (populates the conversation cache).
    await ca.openConversation(idb.peerId.hex);
    await cb.openConversation(ida.peerId.hex);

    final bytes = Uint8List.fromList(List.generate(5000, (i) => i & 0xff));
    await ca.sendFile(idb.peerId.hex,
        bytes: bytes, name: 'pic.bin', mime: 'application/octet-stream');

    // Sender bubble exists immediately, with a local copy for retry/open.
    var aMsg = ca.conversation(idb.peerId.hex).last;
    expect(aMsg.kind, MsgKind.file);
    expect(aMsg.filePath, isNotNull);
    expect(
        aMsg.status, anyOf(MsgStatus.sending, MsgStatus.delivered));

    // Give the background chunk stream + ACK round-trip time to finish.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // Receiver ends with a received bubble pointing at the saved file.
    final bMsg = cb.conversation(ida.peerId.hex).last;
    expect(bMsg.kind, MsgKind.file);
    expect(bMsg.status, MsgStatus.received);
    expect(bMsg.filePath, isNotNull);
    expect(File(bMsg.filePath!).lengthSync(), bytes.length);

    // The completion ACK flips the sender bubble to delivered.
    aMsg = ca.conversation(idb.peerId.hex).last;
    expect(aMsg.status, MsgStatus.delivered);

    await ca.node.dispose();
    ca.dispose();
    await cb.node.dispose();
    cb.dispose();
  });

  test('durable relay store survives an app restart', () async {
    final id = await Identity.generate();
    final bob = await Identity.generate();
    final dbPath = p.join(tmp.path, 'c${counter++}.db');
    MeshController make() {
      final radio = FakeRadio();
      return MeshController(
        identity: id,
        displayName: 'Me',
        db: AppDatabase(overridePath: dbPath),
        identityStore: IdentityStore(),
        node: MeshNode(
            identity: id, displayName: 'Me', transport: radio.create(id.peerId)),
      );
    }

    // Send a text to a known-but-offline peer: it parks in the durable store.
    var c = make();
    await c.init();
    await c.addContactFromBundle(bob.publicBundle, name: 'Bob');
    await c.sendText(bob.peerId.hex, '언젠가 도착할 메시지');
    expect(c.node.store.durableCount, greaterThanOrEqualTo(1));
    // Let the fire-and-forget db mirror writes land.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await c.node.dispose();
    c.dispose();

    // "App restart": new controller over the same database.
    c = make();
    await c.init();
    expect(c.node.store.durableCount, greaterThanOrEqualTo(1),
        reason: '보관된 텍스트는 재시작 후에도 살아있어야 한다');

    // User purge empties both memory and disk.
    await c.clearRelayStore();
    expect(c.node.store.durableCount, 0);
    expect(await c.db.loadRelayFrames(), isEmpty);

    await c.node.dispose();
    c.dispose();
  });

  test('retry syncs the inbox summary (_lastMessage), not just the thread',
      () async {
    final (c, _) = await build();
    final bob = await Identity.generate();
    final bobHex = bob.peerId.hex;

    // Send with the recipient key unknown -> failed.
    await c.sendText(bobHex, 'hi bob');
    var summary = c.conversations().firstWhere((s) => s.peerHex == bobHex);
    expect(summary.lastMessage!.status, MsgStatus.failed);
    final oldMsgId = summary.lastMessage!.msgId;

    // Now we learn Bob's key (e.g. scanned QR) and retry.
    await c.addContactFromBundle(bob.publicBundle, name: 'Bob');
    await c.openConversation(bobHex);
    final failed = c
        .conversation(bobHex)
        .firstWhere((m) => m.status == MsgStatus.failed);
    await c.retryText(failed);

    // The inbox summary must reflect the retried (sent) message with the new id.
    summary = c.conversations().firstWhere((s) => s.peerHex == bobHex);
    expect(summary.lastMessage!.status, MsgStatus.sent);
    expect(summary.lastMessage!.msgId, isNot(oldMsgId));
    // The thread copy is updated too.
    final threadMsg = c.conversation(bobHex).last;
    expect(threadMsg.status, MsgStatus.sent);

    await c.node.dispose();
    c.dispose();
  });

  test('rssiOf smooths readings with an EMA', () async {
    final id = await Identity.generate();
    final radio = FakeRadio();
    final t = radio.create(id.peerId);
    final c = MeshController(
      identity: id,
      displayName: 'Me',
      db: AppDatabase(overridePath: p.join(tmp.path, 'c${counter++}.db')),
      identityStore: IdentityStore(),
      node: MeshNode(identity: id, displayName: 'Me', transport: t),
    );
    await c.init();
    final bob = await Identity.generate();
    final bobHex = bob.peerId.hex;

    expect(c.rssiOf(bobHex), isNull); // no reading yet

    t.emitRssi(bob.peerId, -60);
    await pumpEventQueue();
    expect(c.rssiOf(bobHex), -60);

    // 0.6 * -60 + 0.4 * -80 = -68: jumpy raw readings get damped.
    t.emitRssi(bob.peerId, -80);
    await pumpEventQueue();
    expect(c.rssiOf(bobHex), -68);

    await c.node.dispose();
    c.dispose();
  });

  test('deleteContact removes contact, conversation and db rows', () async {
    final (c, _) = await build();
    final bob = await Identity.generate();
    final bobHex = bob.peerId.hex;
    await c.addContactFromBundle(bob.publicBundle, name: 'Bob');
    await c.openConversation(bobHex);
    await c.sendText(bobHex, '지워질 대화');
    expect(c.conversation(bobHex), isNotEmpty);

    await c.deleteContact(bobHex);

    expect(c.contacts, isEmpty);
    expect(c.conversation(bobHex), isEmpty);
    expect(await c.db.contact(bobHex), isNull);
    expect(await c.db.messagesFor(bobHex), isEmpty);
    // The inbox row is gone too.
    expect(c.conversations().where((s) => s.peerHex == bobHex), isEmpty);

    await c.node.dispose();
    c.dispose();
  });

  test('renameContact updates the contact and persists', () async {
    final (c, _) = await build();
    final bob = await Identity.generate();
    await c.addContactFromBundle(bob.publicBundle, name: 'Bob');
    await c.renameContact(bob.peerId.hex, 'Bobby');
    expect(c.contactByHex(bob.peerId.hex)!.displayName, 'Bobby');

    // Reload from DB to confirm persistence.
    final reloaded = await c.db.contact(bob.peerId.hex);
    expect(reloaded!.displayName, 'Bobby');

    await c.node.dispose();
    c.dispose();
  });

  test('QR round-trip through controller', () async {
    final (c, id) = await build();
    final parsed = MeshController.parseQr(c.myQrPayload);
    expect(parsed, isNotNull);
    expect(Identity.peerIdFromBundle(parsed!.$1), id.peerId);
    await c.node.dispose();
    c.dispose();
  });

  test('incoming message notifies only when app is backgrounded', () async {
    final ida = await Identity.generate();
    final idb = await Identity.generate();
    final radio = FakeRadio();
    final notifications = <(String, String, String)>[];

    final ca = MeshController(
      identity: ida,
      displayName: 'A',
      db: AppDatabase(overridePath: p.join(tmp.path, 'c${counter++}.db')),
      identityStore: IdentityStore(),
      node: MeshNode(
          identity: ida, displayName: 'A', transport: radio.create(ida.peerId)),
      notifier: (key, title, body) => notifications.add((key, title, body)),
    );
    final cb = MeshController(
      identity: idb,
      displayName: 'Bob',
      db: AppDatabase(overridePath: p.join(tmp.path, 'c${counter++}.db')),
      identityStore: IdentityStore(),
      node: MeshNode(
          identity: idb, displayName: 'Bob', transport: radio.create(idb.peerId)),
    );
    await ca.init();
    await cb.init();
    radio.connect(ida.peerId, idb.peerId);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // Foreground: no notification.
    ca.setForegroundForTest(true);
    await cb.sendText(ida.peerId.hex, 'while foreground');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(notifications, isEmpty);

    // Backgrounded (screen off): notification fires with sender name + body.
    ca.setForegroundForTest(false);
    await cb.sendText(ida.peerId.hex, 'while backgrounded');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(notifications.length, 1);
    expect(notifications.single.$1, idb.peerId.hex); // conversation key
    expect(notifications.single.$2, 'Bob'); // sender display name
    expect(notifications.single.$3, 'while backgrounded');

    await ca.node.dispose();
    ca.dispose();
    await cb.node.dispose();
    cb.dispose();
  });
}
