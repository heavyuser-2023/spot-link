import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// SQLite persistence for contacts and messages. See docs/ARCHITECTURE.md §10.
class AppDatabase {
  Database? _db;

  /// Optional explicit path/factory override (used by tests with an in-memory
  /// or temp database). When null, the default per-app database file is used.
  final String? overridePath;

  AppDatabase({this.overridePath});

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final String path;
    if (overridePath != null) {
      path = overridePath!;
    } else {
      final dir = await getDatabasesPath();
      path = p.join(dir, 'spotlink.db');
    }
    _db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
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
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            peer_hex TEXT NOT NULL,
            msg_id TEXT NOT NULL,
            direction INTEGER NOT NULL,
            kind INTEGER NOT NULL,
            text TEXT,
            file_name TEXT,
            file_path TEXT,
            file_size INTEGER,
            status INTEGER NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_messages_peer ON messages(peer_hex, timestamp)');
        await db
            .execute('CREATE INDEX idx_messages_msgid ON messages(msg_id)');
        await _createRelayStore(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createRelayStore(db);
      },
    );
    return _db!;
  }

  /// Durable store-and-forward mailbox: encrypted frames we relay for others
  /// (and our own undelivered texts), kept until delivered or purged.
  static Future<void> _createRelayStore(Database db) async {
    await db.execute('''
      CREATE TABLE relay_store (
        msg_id TEXT PRIMARY KEY,
        frame BLOB NOT NULL,
        stored_at INTEGER NOT NULL
      )
    ''');
  }

  // ----- Contacts -----

  Future<void> upsertContact(Contact c) async {
    final db = await _database;
    await db.insert('contacts', c.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Contact>> allContacts() async {
    final db = await _database;
    final rows = await db.query('contacts', orderBy: 'display_name');
    return rows.map(Contact.fromMap).toList();
  }

  Future<Contact?> contact(String peerHex) async {
    final db = await _database;
    final rows =
        await db.query('contacts', where: 'peer_hex = ?', whereArgs: [peerHex]);
    return rows.isEmpty ? null : Contact.fromMap(rows.first);
  }

  Future<void> touchContact(String peerHex, int lastSeen) async {
    final db = await _database;
    await db.update('contacts', {'last_seen': lastSeen},
        where: 'peer_hex = ?', whereArgs: [peerHex]);
  }

  // ----- Messages -----

  Future<int> insertMessage(ChatMessage m) async {
    final db = await _database;
    return db.insert('messages', m.toMap()..remove('id'));
  }

  Future<List<ChatMessage>> messagesFor(String peerHex) async {
    final db = await _database;
    final rows = await db.query('messages',
        where: 'peer_hex = ?', whereArgs: [peerHex], orderBy: 'timestamp ASC');
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// Returns the number of rows updated (0 = message not persisted yet).
  Future<int> updateStatusByMsgId(String msgId, MsgStatus status) async {
    final db = await _database;
    return db.update('messages', {'status': status.index},
        where: 'msg_id = ?', whereArgs: [msgId]);
  }

  /// Update a message's msgId + status by row id (used when retrying a failed
  /// send, which produces a new msgId).
  Future<void> updateMessageDelivery(
      int id, String msgId, MsgStatus status) async {
    final db = await _database;
    await db.update('messages', {'msg_id': msgId, 'status': status.index},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Attach the saved file path (+ new status) to a file message, e.g. when an
  /// in-progress incoming transfer completes. Returns the number of rows
  /// updated (0 = no such message).
  Future<int> updateFileByMsgId(
      String msgId, String filePath, MsgStatus status) async {
    final db = await _database;
    return db.update(
        'messages', {'file_path': filePath, 'status': status.index},
        where: 'msg_id = ?', whereArgs: [msgId]);
  }

  /// Mark transfers that were mid-flight when the app died as failed, so no
  /// bubble is stuck on "sending/receiving" forever after a restart.
  Future<void> failStaleTransfers() async {
    final db = await _database;
    await db.update('messages', {'status': MsgStatus.failed.index},
        where: 'status IN (?, ?)',
        whereArgs: [MsgStatus.sending.index, MsgStatus.receiving.index]);
  }

  Future<void> deleteContact(String peerHex) async {
    final db = await _database;
    await db.delete('contacts', where: 'peer_hex = ?', whereArgs: [peerHex]);
  }

  Future<void> deleteMessagesFor(String peerHex) async {
    final db = await _database;
    await db.delete('messages', where: 'peer_hex = ?', whereArgs: [peerHex]);
  }

  /// Delete a single message (text or file bubble) by its frame msgId.
  Future<void> deleteMessage(String msgId) async {
    final db = await _database;
    await db.delete('messages', where: 'msg_id = ?', whereArgs: [msgId]);
  }

  // ----- Durable relay store (store-and-forward mailbox) -----

  Future<List<Uint8List>> loadRelayFrames() async {
    final db = await _database;
    final rows = await db.query('relay_store', orderBy: 'stored_at ASC');
    return rows.map((r) => r['frame'] as Uint8List).toList();
  }

  Future<void> upsertRelayFrame(String msgIdHex, Uint8List frame) async {
    final db = await _database;
    await db.insert(
        'relay_store',
        {
          'msg_id': msgIdHex,
          'frame': frame,
          'stored_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteRelayFrame(String msgIdHex) async {
    final db = await _database;
    await db
        .delete('relay_store', where: 'msg_id = ?', whereArgs: [msgIdHex]);
  }

  Future<void> clearRelayStore() async {
    final db = await _database;
    await db.delete('relay_store');
  }

  /// Distinct peers with at least one message, most-recent first.
  Future<List<String>> conversationPeers() async {
    final db = await _database;
    final rows = await db.rawQuery('''
      SELECT peer_hex, MAX(timestamp) AS t
      FROM messages GROUP BY peer_hex ORDER BY t DESC
    ''');
    return rows.map((r) => r['peer_hex'] as String).toList();
  }

  Future<ChatMessage?> lastMessageFor(String peerHex) async {
    final db = await _database;
    final rows = await db.query('messages',
        where: 'peer_hex = ?',
        whereArgs: [peerHex],
        orderBy: 'timestamp DESC',
        limit: 1);
    return rows.isEmpty ? null : ChatMessage.fromMap(rows.first);
  }
}
