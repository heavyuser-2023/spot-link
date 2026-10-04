import '../core/model/peer_id.dart';

enum MsgDirection { incoming, outgoing }

enum MsgKind { text, file }

// 값은 인덱스로 영구 저장된다 — 추가만 할 것, 절대 순서를 바꾸지 말 것.
enum MsgStatus {
  sending,
  sent,
  delivered,
  failed,
  receiving,
  received,

  /// 지금은 활성 경로가 없음; 영구 store-and-forward 메일박스에 보관되며
  /// 다음 조우 시 자동으로 전달된다.
  queued,
}

/// 한 피어와의 대화에 영구 저장된 채팅 메시지 (텍스트 또는 파일).
class ChatMessage {
  final int? id;
  final String peerHex; // 대화 상대
  final String msgId; // 프레임 msgId hex (중복 제거 / ack 키)
  final MsgDirection direction;
  final MsgKind kind;
  final String? text;
  final String? fileName;
  final String? filePath; // 수신/전송 파일의 로컬 경로
  final int? fileSize;
  final MsgStatus status;
  final int timestamp; // epoch ms — 수신: 도착 시각; 발신: 전송 시각

  /// 수신 전용: 발신자의 전송 시각 (발신자 시계, epoch ms)으로, 텍스트
  /// 엔벌로프에 실려 온다. legacy 피어 / 비텍스트에서는 null. store-and-forward
  /// 텍스트가 작성된 지 한참 뒤에 도착하면 [timestamp]와 눈에 띄게 달라진다.
  final int? sentTs;

  /// 파일 전용: 바이트가 실제로 이동한 경로 — 'wifi'(Wi-Fi 직결 fast lane)
  /// 또는 'ble'(블루투스 청킹). 전송이 경로를 확정하는 순간 기록되고 완료
  /// 후에도 남아, 말풍선이 "무엇으로 전달됐는지"를 계속 말해준다.
  final String? lane;

  ChatMessage({
    this.id,
    required this.peerHex,
    required this.msgId,
    required this.direction,
    required this.kind,
    this.text,
    this.fileName,
    this.filePath,
    this.fileSize,
    required this.status,
    required this.timestamp,
    this.sentTs,
    this.lane,
  });

  ChatMessage copyWith({String? msgId, MsgStatus? status, String? filePath}) =>
      ChatMessage(
        id: id,
        peerHex: peerHex,
        msgId: msgId ?? this.msgId,
        direction: direction,
        kind: kind,
        text: text,
        fileName: fileName,
        filePath: filePath ?? this.filePath,
        fileSize: fileSize,
        status: status ?? this.status,
        timestamp: timestamp,
        sentTs: sentTs,
        lane: lane,
      );

  ChatMessage withId(int id) => ChatMessage(
        id: id,
        peerHex: peerHex,
        msgId: msgId,
        direction: direction,
        kind: kind,
        text: text,
        fileName: fileName,
        filePath: filePath,
        fileSize: fileSize,
        status: status,
        timestamp: timestamp,
        sentTs: sentTs,
        lane: lane,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'peer_hex': peerHex,
        'msg_id': msgId,
        'direction': direction.index,
        'kind': kind.index,
        'text': text,
        'file_name': fileName,
        'file_path': filePath,
        'file_size': fileSize,
        'status': status.index,
        'timestamp': timestamp,
        'sent_ts': sentTs,
        'lane': lane,
      };

  static ChatMessage fromMap(Map<String, Object?> m) => ChatMessage(
        id: m['id'] as int?,
        peerHex: m['peer_hex'] as String,
        msgId: m['msg_id'] as String,
        direction: MsgDirection.values[m['direction'] as int],
        kind: MsgKind.values[m['kind'] as int],
        text: m['text'] as String?,
        fileName: m['file_name'] as String?,
        filePath: m['file_path'] as String?,
        fileSize: m['file_size'] as int?,
        status: MsgStatus.values[m['status'] as int],
        timestamp: m['timestamp'] as int,
        sentTs: m['sent_ts'] as int?,
        lane: m['lane'] as String?,
      );
}

/// 메시지에 달린 이모지 리액션 하나. (msgId, emoji, fromMe)가 자연 키 —
/// 1:1 대화라 "누가"는 fromMe 불리언으로 충분하다.
class Reaction {
  final String msgId;
  final String emoji;
  final bool fromMe;
  Reaction({required this.msgId, required this.emoji, required this.fromMe});
}

/// 영구 저장된 연락처 (알려진 원격 신원).
class Contact {
  final String peerHex;
  final String signingPublicB64;
  final String kexPublicB64;
  final String displayName;
  final bool verified;

  /// 파츠 아바타 레시피(compact, [AvatarCodec] 형식) — 상대의 ANNOUNCE에서
  /// 학습한다. null이면 이니셜 아바타.
  final String? avatar;

  /// 사용자가 이 연락처의 이름을 직접 바꾼 순간 true가 된다. 잠긴 이름은
  /// 피어가 스스로 알린 이름(MeshController._rememberAnnounced 참조)이나
  /// QR 재스캔으로 절대 덮어쓰이지 않는다.
  final bool nameLocked;
  final int lastSeen; // epoch ms, 한 번도 없으면 0

  /// 이 친구와 연결되는 순간 자동으로 보낼 메시지(스쳐 지날 때 인사).
  /// null이면 꺼짐. [EncounterTracker]가 친구당 쿨다운을 지켜 보낸다.
  final String? autoMessage;

  Contact({
    required this.peerHex,
    required this.signingPublicB64,
    required this.kexPublicB64,
    required this.displayName,
    required this.verified,
    this.avatar,
    this.nameLocked = false,
    this.lastSeen = 0,
    this.autoMessage,
  });

  PeerId get peerId => PeerId.fromHex(peerHex);

  Map<String, Object?> toMap() => {
        'peer_hex': peerHex,
        'signing_pub': signingPublicB64,
        'kex_pub': kexPublicB64,
        'display_name': displayName,
        'verified': verified ? 1 : 0,
        'avatar': avatar,
        'name_locked': nameLocked ? 1 : 0,
        'last_seen': lastSeen,
        'auto_message': autoMessage,
      };

  static Contact fromMap(Map<String, Object?> m) => Contact(
        peerHex: m['peer_hex'] as String,
        signingPublicB64: m['signing_pub'] as String,
        kexPublicB64: m['kex_pub'] as String,
        displayName: m['display_name'] as String,
        verified: (m['verified'] as int) == 1,
        avatar: m['avatar'] as String?,
        nameLocked: (m['name_locked'] as int? ?? 0) == 1,
        lastSeen: (m['last_seen'] as int?) ?? 0,
        autoMessage: m['auto_message'] as String?,
      );

  Contact copyWith(
          {String? displayName,
          bool? verified,
          String? avatar,
          bool? nameLocked,
          int? lastSeen}) =>
      Contact(
        peerHex: peerHex,
        signingPublicB64: signingPublicB64,
        kexPublicB64: kexPublicB64,
        displayName: displayName ?? this.displayName,
        verified: verified ?? this.verified,
        avatar: avatar ?? this.avatar,
        nameLocked: nameLocked ?? this.nameLocked,
        lastSeen: lastSeen ?? this.lastSeen,
        autoMessage: autoMessage,
      );

  /// [copyWith]는 null을 "유지"로 읽으므로, 자동 메시지를 **끄는**(null로
  /// 만드는) 경로는 따로 둔다. 공백뿐인 문구도 꺼짐으로 정규화한다.
  Contact withAutoMessage(String? message) {
    final m = message?.trim();
    return Contact(
      peerHex: peerHex,
      signingPublicB64: signingPublicB64,
      kexPublicB64: kexPublicB64,
      displayName: displayName,
      verified: verified,
      avatar: avatar,
      nameLocked: nameLocked,
      lastSeen: lastSeen,
      autoMessage: (m == null || m.isEmpty) ? null : m,
    );
  }
}

/// 만남이 어떻게 감지됐는가.
enum EncounterSource {
  /// 실제로 연결돼 상대의 ANNOUNCE를 받았다 — 누구인지 안다.
  link,

  /// 웨이크 비콘으로만 감지됐다. 비콘은 모든 SpotLink 기기가 같은 신호를
  /// 내므로 **누구인지 담겨 있지 않다** — 연결 전에 멀어진 경우다.
  beacon,
}

/// "스쳐간 친구" 기록 한 건 — 친구가 근처에 있던 한 구간(연속 관측).
class Encounter {
  final int id;

  /// 상대 peerHex. null이면 확인되지 않은 SpotLink 사용자([EncounterSource.beacon]).
  final String? peerHex;
  final int startedAt; // epoch ms
  final int endedAt; // epoch ms — 마지막으로 관측된 시각
  final double? lat;
  final double? lng;

  /// 위치 정확도(미터). 알 수 없으면 null.
  final double? accuracy;

  /// 역지오코딩한 장소 이름(오프라인이면 나중에 채워진다).
  final String? place;

  /// 이 구간에서 본 가장 가까운 거리(1 = 직접 연결, 2+ = 중계 경유).
  final int hops;
  final EncounterSource source;

  /// 이 만남에서 자동 메시지를 보냈는가.
  final bool autoSent;

  /// 앱을 보고 있지 않은 동안의 만남인가 — "보지는 못했지만 스쳐 지나간" 경우.
  final bool missed;

  const Encounter({
    required this.id,
    required this.peerHex,
    required this.startedAt,
    required this.endedAt,
    this.lat,
    this.lng,
    this.accuracy,
    this.place,
    this.hops = 1,
    this.source = EncounterSource.link,
    this.autoSent = false,
    this.missed = false,
  });

  bool get identified => peerHex != null;
  bool get hasLocation => lat != null && lng != null;
  Duration get duration => Duration(milliseconds: endedAt - startedAt);

  static Encounter fromMap(Map<String, Object?> m) => Encounter(
        id: m['id'] as int,
        peerHex: m['peer_hex'] as String?,
        startedAt: m['started_at'] as int,
        endedAt: m['ended_at'] as int,
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
        accuracy: (m['accuracy'] as num?)?.toDouble(),
        place: m['place'] as String?,
        hops: (m['hops'] as int?) ?? 1,
        source: m['source'] == 'beacon'
            ? EncounterSource.beacon
            : EncounterSource.link,
        autoSent: (m['auto_sent'] as int? ?? 0) == 1,
        missed: (m['missed'] as int? ?? 0) == 1,
      );
}
