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
      version: 1,
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
      },
    );
    return _db!;
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

  Future<void> updateStatusByMsgId(String msgId, MsgStatus status) async {
    final db = await _database;
    await db.update('messages', {'status': status.index},
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
