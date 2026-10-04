import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// 연락처와 메시지를 위한 SQLite 영구 저장소. docs/ARCHITECTURE.md §10 참조.
class AppDatabase {
  Database? _db;

  /// 현재 앱의 Documents 디렉터리(부트스트랩에서 주입). iOS는 앱
  /// 업데이트/재설치 때 데이터 컨테이너 UUID를 바꿀 수 있어, DB에 저장된
  /// 절대 파일 경로가 통째로 죽는다 — 파일 자체는 Documents와 함께 이사해
  /// 살아 있으므로, 읽기 시점에 현재 컨테이너 기준으로 재해석한다
  /// (관찰: 재설치 뒤 옛 사진 말풍선이 썸네일 없이 이름만 남고 안 열림).
  static String? documentsDir;

  /// DB를 둘 디렉터리(앱 계층이 주입). **데스크톱 전용**으로 쓴다:
  /// sqflite의 기본 경로가 macOS 비샌드박스에서 TCC 보호된 `~/Documents`로
  /// 잡혀 DB를 아예 열 수 없었다(`error opening!: 23`, 2026-07 맥 16일 실명
  /// 사건의 절반). 모바일은 null로 두어 기존 경로(=기존 데이터)를 유지한다.
  /// [AppPaths] 참고.
  static String? dbDir;

  static ChatMessage _fixPath(ChatMessage m) {
    final path = m.filePath;
    final docs = documentsDir;
    if (path == null || docs == null) return m;
    if (File(path).existsSync()) return m; // 경로가 살아 있으면 그대로
    const marker = '/Documents/';
    final i = path.indexOf(marker);
    if (i < 0) return m;
    final rebased = p.join(docs, path.substring(i + marker.length));
    if (!File(rebased).existsSync()) return m; // 진짜 사라진 파일 — 손대지 않음
    return m.copyWith(filePath: rebased);
  }

  /// 선택적 명시 경로/팩토리 오버라이드 (in-memory 또는 임시 데이터베이스를
  /// 쓰는 테스트에서 사용). null이면 앱별 기본 데이터베이스 파일을 사용한다.
  final String? overridePath;

  AppDatabase({this.overridePath});

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final String path;
    if (overridePath != null) {
      path = overridePath!;
    } else {
      final dir = dbDir ?? await getDatabasesPath();
      path = p.join(dir, 'spotlink.db');
    }
    _db = await openDatabase(
      path,
      version: 9,
      // WAL: Android 서비스 isolate가 이 파일에 쓰는 동안 UI isolate가
      // 읽는다 (한 프로세스에 두 개의 SQLite 연결). 롤백 저널 모드였다면
      // 쓰기 중 리더가 SQLITE_BUSY를 만나게 된다; WAL은 하나의 라이터 +
      // 동시 리더를 허용한다. 파일별로 영구 유지되지만, 구버전 설치를 위해
      // 열 때마다 확실히 설정한다.
      onConfigure: (db) async {
        try {
          await db.rawQuery('PRAGMA journal_mode=WAL');
        } catch (_) {} // 예: in-memory 테스트 DB — 저널 모드가 의미 없는 경우
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE contacts (
            peer_hex TEXT PRIMARY KEY,
            signing_pub TEXT NOT NULL,
            kex_pub TEXT NOT NULL,
            display_name TEXT NOT NULL,
            verified INTEGER NOT NULL,
            name_locked INTEGER NOT NULL DEFAULT 0,
            last_seen INTEGER NOT NULL,
            avatar TEXT,
            auto_message TEXT
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
            timestamp INTEGER NOT NULL,
            sent_ts INTEGER,
            lane TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_messages_peer ON messages(peer_hex, timestamp)');
        await db
            .execute('CREATE INDEX idx_messages_msgid ON messages(msg_id)');
        await _createRelayStore(db);
        await _createPendingDelivery(db);
        await _createReactions(db);
        await _createEncounters(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createRelayStore(db);
        if (oldVersion < 3) await _createPendingDelivery(db);
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE contacts '
              'ADD COLUMN name_locked INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 5) {
          // 수신 텍스트를 위한 발신자의 전송 시각 ("보낸 시각 / 도착 시각").
          await db.execute('ALTER TABLE messages ADD COLUMN sent_ts INTEGER');
        }
        if (oldVersion < 6) {
          // 파일 전송 경로('wifi'|'ble') — 말풍선의 경로 표시용.
          await db.execute('ALTER TABLE messages ADD COLUMN lane TEXT');
        }
        if (oldVersion < 7) await _createReactions(db);
        if (oldVersion < 8) {
          // 파츠 아바타 레시피(ANNOUNCE에서 학습).
          await db.execute('ALTER TABLE contacts ADD COLUMN avatar TEXT');
        }
        if (oldVersion < 9) {
          // 스쳐간 친구 기록 + 친구별 자동 메시지.
          await db
              .execute('ALTER TABLE contacts ADD COLUMN auto_message TEXT');
          await _createEncounters(db);
        }
      },
    );
    return _db!;
  }

  /// 스쳐간 친구 기록. 한 행 = 한 친구가 근처에 있던 한 구간(연속 관측).
  /// peer_hex가 NULL이면 비콘으로만 감지된 미확인 사용자다. 위치는 이 기기에만
  /// 저장된다.
  static Future<void> _createEncounters(Database db) async {
    await db.execute('''
      CREATE TABLE encounters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        peer_hex TEXT,
        started_at INTEGER NOT NULL,
        ended_at INTEGER NOT NULL,
        lat REAL,
        lng REAL,
        accuracy REAL,
        place TEXT,
        hops INTEGER NOT NULL DEFAULT 1,
        source TEXT NOT NULL DEFAULT 'link',
        auto_sent INTEGER NOT NULL DEFAULT 0,
        missed INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_encounters_peer ON encounters(peer_hex, ended_at)');
    await db.execute(
        'CREATE INDEX idx_encounters_started ON encounters(started_at)');
  }

  // ---- 스쳐간 친구(만남 기록) ----

  Future<int> insertEncounter({
    required String? peerHex,
    required int at,
    required int hops,
    required EncounterSource source,
    required bool missed,
  }) async {
    final db = await _database;
    return db.insert('encounters', {
      'peer_hex': peerHex,
      'started_at': at,
      'ended_at': at,
      'hops': hops,
      'source': source.name,
      'missed': missed ? 1 : 0,
    });
  }

  /// 이 친구의 가장 최근 만남(재시작 뒤에도 진행 중인 만남을 이어 붙이는 근거).
  Future<Encounter?> latestEncounterFor(String peerHex) async {
    final db = await _database;
    final rows = await db.query('encounters',
        where: 'peer_hex = ?',
        whereArgs: [peerHex],
        orderBy: 'ended_at DESC',
        limit: 1);
    return rows.isEmpty ? null : Encounter.fromMap(rows.first);
  }

  /// [sinceMs] 이후에 관측된 미확인(비콘) 만남 중 가장 최근 것.
  Future<Encounter?> latestUnidentifiedSince(int sinceMs) async {
    final db = await _database;
    final rows = await db.query('encounters',
        where: 'peer_hex IS NULL AND ended_at >= ?',
        whereArgs: [sinceMs],
        orderBy: 'ended_at DESC',
        limit: 1);
    return rows.isEmpty ? null : Encounter.fromMap(rows.first);
  }

  Future<void> extendEncounter(int id,
      {required int endedAt, required int hops, bool? missed}) async {
    final db = await _database;
    await db.update(
        'encounters',
        {
          'ended_at': endedAt,
          'hops': hops,
          if (missed != null) 'missed': missed ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  /// 비콘으로만 잡혔던 만남이 곧이어 연결돼 누구인지 드러났을 때 승격한다.
  Future<void> identifyEncounter(int id, String peerHex,
      {required int endedAt, required int hops}) async {
    final db = await _database;
    await db.update(
        'encounters',
        {
          'peer_hex': peerHex,
          'source': EncounterSource.link.name,
          'ended_at': endedAt,
          'hops': hops,
        },
        where: 'id = ? AND peer_hex IS NULL',
        whereArgs: [id]);
  }

  Future<void> setEncounterLocation(int id,
      {required double lat, required double lng, double? accuracy}) async {
    final db = await _database;
    await db.update(
        'encounters', {'lat': lat, 'lng': lng, 'accuracy': accuracy},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setEncounterPlace(int id, String place) async {
    final db = await _database;
    await db.update('encounters', {'place': place},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markEncounterAutoSent(int id) async {
    final db = await _database;
    await db.update('encounters', {'auto_sent': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 이 친구에게 마지막으로 자동 메시지를 보낸 만남의 시작 시각(없으면 null).
  Future<int?> lastAutoSentAt(String peerHex) async {
    final db = await _database;
    final rows = await db.rawQuery(
        'SELECT MAX(started_at) AS t FROM encounters '
        'WHERE peer_hex = ? AND auto_sent = 1',
        [peerHex]);
    return rows.first['t'] as int?;
  }

  /// 최신순 만남 목록.
  Future<List<Encounter>> encounters({int limit = 500}) async {
    final db = await _database;
    final rows =
        await db.query('encounters', orderBy: 'started_at DESC', limit: limit);
    return rows.map(Encounter.fromMap).toList();
  }

  /// 좌표는 있는데 장소 이름이 아직 없는 만남(오프라인이었던 경우 나중에 채운다).
  Future<List<Encounter>> encountersMissingPlace({int limit = 20}) async {
    final db = await _database;
    final rows = await db.query('encounters',
        where: 'lat IS NOT NULL AND place IS NULL',
        orderBy: 'started_at DESC',
        limit: limit);
    return rows.map(Encounter.fromMap).toList();
  }

  Future<void> clearEncounters() async {
    final db = await _database;
    await db.delete('encounters');
  }

  /// 연락처를 지우면 그 친구와의 만남 기록도 함께 지운다(흔적을 남기지 않는다).
  Future<void> deleteEncountersFor(String peerHex) async {
    final db = await _database;
    await db.delete('encounters', where: 'peer_hex = ?', whereArgs: [peerHex]);
  }

  /// 영구 store-and-forward 메일박스: 다른 사람을 위해 릴레이하는 암호화된
  /// 프레임 (그리고 우리 자신의 미전달 텍스트)으로, 전달되거나 정리될
  /// 때까지 보관된다.
  static Future<void> _createRelayStore(Database db) async {
    await db.execute('''
      CREATE TABLE relay_store (
        msg_id TEXT PRIMARY KEY,
        frame BLOB NOT NULL,
        stored_at INTEGER NOT NULL
      )
    ''');
  }

  /// 메시지별 이모지 리액션. (msg_id, emoji, from_me)가 자연 키 — 같은
  /// 사람이 같은 이모지를 두 번 달 수 없고(멱등), 재배달된 리액션 프레임은
  /// INSERT OR IGNORE로 흡수된다.
  static Future<void> _createReactions(Database db) async {
    await db.execute('''
      CREATE TABLE reactions (
        peer_hex TEXT NOT NULL,
        msg_id TEXT NOT NULL,
        emoji TEXT NOT NULL,
        from_me INTEGER NOT NULL,
        PRIMARY KEY (msg_id, emoji, from_me)
      )
    ''');
    await db
        .execute('CREATE INDEX idx_reactions_peer ON reactions(peer_hex)');
  }

  /// 우리에게 온 메시지 중 목격은 되었으나 아직 앱으로 전달되지 못한
  /// (복호화 실패 / 키 없음) 메시지들의 id. 깨끗한 복사본이 도착하기 전에
  /// 재시작이 일어나도 라우팅 seen-cache 뒤에서 다시 발이 묶이지 않도록
  /// 영구 저장한다.
  static Future<void> _createPendingDelivery(Database db) async {
    await db.execute('''
      CREATE TABLE pending_delivery (
        msg_id TEXT PRIMARY KEY
      )
    ''');
  }

  Future<List<String>> loadPendingDeliveries() async {
    final db = await _database;
    final rows = await db.query('pending_delivery', columns: ['msg_id']);
    return rows.map((r) => r['msg_id'] as String).toList();
  }

  Future<void> addPendingDelivery(String msgIdHex) async {
    final db = await _database;
    await db.insert('pending_delivery', {'msg_id': msgIdHex},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removePendingDelivery(String msgIdHex) async {
    final db = await _database;
    await db
        .delete('pending_delivery', where: 'msg_id = ?', whereArgs: [msgIdHex]);
  }

  // ----- 연락처 -----

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

  // ----- 메시지 -----

  Future<int> insertMessage(ChatMessage m) async {
    final db = await _database;
    return db.insert('messages', m.toMap()..remove('id'));
  }

  /// 한 대화의 메시지, 오래된 것 먼저. [limit]이 설정되면 가장 최근 [limit]
  /// 개의 행만 반환된다 (여전히 오래된 것 먼저) — 채팅 화면이 수년 치 기록을
  /// RAM에 고정해 둘 필요는 없다.
  Future<List<ChatMessage>> messagesFor(String peerHex, {int? limit}) async {
    final db = await _database;
    if (limit == null) {
      final rows = await db.query('messages',
          where: 'peer_hex = ?',
          whereArgs: [peerHex],
          orderBy: 'timestamp ASC');
      return rows.map(ChatMessage.fromMap).map(_fixPath).toList();
    }
    final rows = await db.query('messages',
        where: 'peer_hex = ?',
        whereArgs: [peerHex],
        orderBy: 'timestamp DESC',
        limit: limit);
    return rows
        .map(ChatMessage.fromMap)
        .map(_fixPath)
        .toList()
        .reversed
        .toList();
  }

  /// 갱신된 행 수를 반환한다 (0 = 메시지가 아직 영구 저장되지 않음).
  /// 유령 META(스토어 재전달)가 받은 파일 말풍선을 failed로 뒤집은 것을
  /// 복구한다: 로컬 파일 경로가 붙어 있는(=완주했던) 수신 파일 메시지를
  /// received로 되돌린다. 갱신된 행 수를 반환한다.
  Future<int> repairIncomingFilesWithLocalPath() async {
    final db = await _database;
    return db.update(
      'messages',
      {'status': MsgStatus.received.index},
      where:
          'kind = ? AND direction = ? AND status = ? AND file_path IS NOT NULL',
      whereArgs: [
        MsgKind.file.index,
        MsgDirection.incoming.index,
        MsgStatus.failed.index,
      ],
    );
  }

  /// 보류(queued) 상태의 발신 파일 메시지들 — 재기동 후 "가까워지면 전달"
  /// 큐를 복원하는 데 쓴다.
  Future<List<ChatMessage>> queuedOutgoingFiles() async {
    final db = await _database;
    final rows = await db.query('messages',
        where: 'status = ? AND direction = ? AND kind = ?',
        whereArgs: [
          MsgStatus.queued.index,
          MsgDirection.outgoing.index,
          MsgKind.file.index,
        ]);
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<int> updateStatusByMsgId(String msgId, MsgStatus status) async {
    final db = await _database;
    return db.update('messages', {'status': status.index},
        where: 'msg_id = ?', whereArgs: [msgId]);
  }

  /// 파일 전송의 실제 경로('wifi'|'ble')를 기록한다.
  Future<int> updateLaneByMsgId(String msgId, String lane) async {
    final db = await _database;
    return db.update('messages', {'lane': lane},
        where: 'msg_id = ?', whereArgs: [msgId]);
  }

  /// 행 id로 메시지의 msgId + status를 갱신한다 (새 msgId를 만드는 실패
  /// 전송 재시도 시 사용).
  Future<void> updateMessageDelivery(
      int id, String msgId, MsgStatus status) async {
    final db = await _database;
    await db.update('messages', {'msg_id': msgId, 'status': status.index},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 저장된 파일 경로(+ 새 status)를 파일 메시지에 붙인다, 예: 진행 중이던
  /// 수신 전송이 완료될 때. 갱신된 행 수를 반환한다 (0 = 해당 메시지 없음).
  Future<int> updateFileByMsgId(
      String msgId, String filePath, MsgStatus status) async {
    final db = await _database;
    return db.update(
        'messages', {'file_path': filePath, 'status': status.index},
        where: 'msg_id = ?', whereArgs: [msgId]);
  }

  /// 앱이 죽는 순간 진행 중이던 전송을 failed로 표시한다. 그래야 재시작
  /// 이후 어떤 말풍선도 "전송 중/수신 중" 상태에 영원히 갇히지 않는다.
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

  /// 프레임 msgId로 단일 메시지(텍스트 또는 파일 말풍선)를 삭제한다.
  Future<void> deleteMessage(String msgId) async {
    final db = await _database;
    await db.delete('messages', where: 'msg_id = ?', whereArgs: [msgId]);
  }

  // ----- 영구 릴레이 저장소 (store-and-forward 메일박스) -----

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

  /// 메시지가 하나 이상 있는 고유 피어들, 가장 최근 순.
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
    return rows.isEmpty ? null : _fixPath(ChatMessage.fromMap(rows.first));
  }

  // ---- 리액션 ----

  Future<void> addReaction(
      String peerHex, String msgId, String emoji, bool fromMe) async {
    final db = await _database;
    await db.insert(
      'reactions',
      {
        'peer_hex': peerHex,
        'msg_id': msgId,
        'emoji': emoji,
        'from_me': fromMe ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> removeReaction(String msgId, String emoji, bool fromMe) async {
    final db = await _database;
    await db.delete('reactions',
        where: 'msg_id = ? AND emoji = ? AND from_me = ?',
        whereArgs: [msgId, emoji, fromMe ? 1 : 0]);
  }

  /// 이 대화의 모든 리액션: msgId → 리액션 목록.
  Future<Map<String, List<Reaction>>> reactionsFor(String peerHex) async {
    final db = await _database;
    final rows = await db
        .query('reactions', where: 'peer_hex = ?', whereArgs: [peerHex]);
    final out = <String, List<Reaction>>{};
    for (final r in rows) {
      final reaction = Reaction(
        msgId: r['msg_id'] as String,
        emoji: r['emoji'] as String,
        fromMe: (r['from_me'] as int) == 1,
      );
      (out[reaction.msgId] ??= []).add(reaction);
    }
    return out;
  }

  Future<void> deleteReactionsFor(String peerHex) async {
    final db = await _database;
    await db.delete('reactions', where: 'peer_hex = ?', whereArgs: [peerHex]);
  }
}
