import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:spot_link/data/app_database.dart';
import 'package:spot_link/data/models.dart';

void main() {
  late Directory tmp;
  var counter = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('spotlink_db_test');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // A distinct on-disk database per test so state never leaks between tests
  // (the ffi factory reuses a single in-memory db across opens).
  AppDatabase freshDb() =>
      AppDatabase(overridePath: p.join(tmp.path, 'db_${counter++}.sqlite'));

  test('contact upsert / read / touch round-trips', () async {
    final db = freshDb();
    final c = Contact(
      peerHex: 'aabbccddeeff0011',
      signingPublicB64: 'c2ln',
      kexPublicB64: 'a2V4',
      displayName: '김정훈',
      verified: true,
      lastSeen: 100,
    );
    await db.upsertContact(c);

    final read = await db.contact('aabbccddeeff0011');
    expect(read, isNotNull);
    expect(read!.displayName, '김정훈');
    expect(read.verified, isTrue);

    await db.touchContact('aabbccddeeff0011', 999);
    final touched = await db.contact('aabbccddeeff0011');
    expect(touched!.lastSeen, 999);

    // Upsert replaces.
    await db.upsertContact(c.copyWith(displayName: 'Kim'));
    final all = await db.allContacts();
    expect(all.length, 1);
    expect(all.first.displayName, 'Kim');
  });

  test('name_locked round-trips through upsert', () async {
    final db = freshDb();
    final c = Contact(
      peerHex: '0011223344556677',
      signingPublicB64: 'c2ln',
      kexPublicB64: 'a2V4',
      displayName: '별명',
      verified: false,
      nameLocked: true,
    );
    await db.upsertContact(c);
    final read = await db.contact('0011223344556677');
    expect(read!.nameLocked, isTrue);
    expect(read.displayName, '별명');
  });

  test('v3 → v4 migration adds name_locked and keeps existing rows', () async {
    final path = p.join(tmp.path, 'migrate_${counter++}.sqlite');
    // Build a v3-schema database by hand (the schema shipped before v4).
    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE contacts (
              peer_hex TEXT PRIMARY KEY,
              signing_pub TEXT NOT NULL,
              kex_pub TEXT NOT NULL,
              display_name TEXT NOT NULL,
              verified INTEGER NOT NULL,
              last_seen INTEGER NOT NULL
            )
          ''');
        },
      ),
    );
    await old.insert('contacts', {
      'peer_hex': 'aabbccddeeff0011',
      'signing_pub': 'c2ln',
      'kex_pub': 'a2V4',
      'display_name': '김정훈',
      'verified': 0,
      'last_seen': 42,
    });
    await old.close();

    // Reopening through AppDatabase runs the v4 migration.
    final db = AppDatabase(overridePath: path);
    final migrated = await db.contact('aabbccddeeff0011');
    expect(migrated, isNotNull);
    expect(migrated!.displayName, '김정훈');
    expect(migrated.nameLocked, isFalse); // default for pre-v4 rows

    await db.upsertContact(
        migrated.copyWith(displayName: '별명', nameLocked: true));
    final renamed = await db.contact('aabbccddeeff0011');
    expect(renamed!.displayName, '별명');
    expect(renamed.nameLocked, isTrue);
  });

  test('messages persist, order, and status update by msgId', () async {
    final db = freshDb();
    const peer = 'deadbeef00112233';

    await db.insertMessage(ChatMessage(
      peerHex: peer,
      msgId: 'm1',
      direction: MsgDirection.outgoing,
      kind: MsgKind.text,
      text: 'hello',
      status: MsgStatus.sent,
      timestamp: 10,
    ));
    await db.insertMessage(ChatMessage(
      peerHex: peer,
      msgId: 'm2',
      direction: MsgDirection.incoming,
      kind: MsgKind.text,
      text: 'hi back',
      status: MsgStatus.received,
      timestamp: 20,
    ));

    final msgs = await db.messagesFor(peer);
    expect(msgs.length, 2);
    expect(msgs.first.text, 'hello'); // ordered by timestamp ASC
    expect(msgs.last.text, 'hi back');

    // Delivery ack flips status.
    await db.updateStatusByMsgId('m1', MsgStatus.delivered);
    final after = await db.messagesFor(peer);
    expect(after.first.status, MsgStatus.delivered);

    final last = await db.lastMessageFor(peer);
    expect(last!.text, 'hi back');
  });

  test('file message persists path and size', () async {
    final db = freshDb();
    const peer = 'ffffffffffffffff';
    await db.insertMessage(ChatMessage(
      peerHex: peer,
      msgId: 'file-1',
      direction: MsgDirection.incoming,
      kind: MsgKind.file,
      fileName: 'photo.jpg',
      filePath: '/tmp/photo.jpg',
      fileSize: 12345,
      status: MsgStatus.received,
      timestamp: 5,
    ));
    final msgs = await db.messagesFor(peer);
    expect(msgs.single.kind, MsgKind.file);
    expect(msgs.single.fileName, 'photo.jpg');
    expect(msgs.single.fileSize, 12345);
    expect(msgs.single.filePath, '/tmp/photo.jpg');
  });

  test('conversationPeers is ordered most-recent first', () async {
    final db = freshDb();
    await db.insertMessage(ChatMessage(
      peerHex: 'peerOld',
      msgId: 'a',
      direction: MsgDirection.outgoing,
      kind: MsgKind.text,
      text: 'x',
      status: MsgStatus.sent,
      timestamp: 100,
    ));
    await db.insertMessage(ChatMessage(
      peerHex: 'peerNew',
      msgId: 'b',
      direction: MsgDirection.outgoing,
      kind: MsgKind.text,
      text: 'y',
      status: MsgStatus.sent,
      timestamp: 200,
    ));
    final peers = await db.conversationPeers();
    expect(peers, ['peerNew', 'peerOld']);
  });
}
