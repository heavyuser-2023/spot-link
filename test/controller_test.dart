import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spot_link/app/mesh_controller.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/data/app_database.dart';
import 'package:spot_link/data/identity_store.dart';
import 'package:spot_link/data/models.dart';

import 'fake_transport.dart';

void main() {
  late Directory tmp;
  var counter = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('spotlink_ctrl');
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
}
