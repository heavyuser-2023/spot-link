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
      );
}

/// 영구 저장된 연락처 (알려진 원격 신원).
class Contact {
  final String peerHex;
  final String signingPublicB64;
  final String kexPublicB64;
  final String displayName;
  final bool verified;

  /// 사용자가 이 연락처의 이름을 직접 바꾼 순간 true가 된다. 잠긴 이름은
  /// 피어가 스스로 알린 이름(MeshController._rememberAnnounced 참조)이나
  /// QR 재스캔으로 절대 덮어쓰이지 않는다.
  final bool nameLocked;
  final int lastSeen; // epoch ms, 한 번도 없으면 0

  Contact({
    required this.peerHex,
    required this.signingPublicB64,
    required this.kexPublicB64,
    required this.displayName,
    required this.verified,
    this.nameLocked = false,
    this.lastSeen = 0,
  });

  PeerId get peerId => PeerId.fromHex(peerHex);

  Map<String, Object?> toMap() => {
        'peer_hex': peerHex,
        'signing_pub': signingPublicB64,
        'kex_pub': kexPublicB64,
        'display_name': displayName,
        'verified': verified ? 1 : 0,
        'name_locked': nameLocked ? 1 : 0,
        'last_seen': lastSeen,
      };

  static Contact fromMap(Map<String, Object?> m) => Contact(
        peerHex: m['peer_hex'] as String,
        signingPublicB64: m['signing_pub'] as String,
        kexPublicB64: m['kex_pub'] as String,
        displayName: m['display_name'] as String,
        verified: (m['verified'] as int) == 1,
        nameLocked: (m['name_locked'] as int? ?? 0) == 1,
        lastSeen: (m['last_seen'] as int?) ?? 0,
      );

  Contact copyWith(
          {String? displayName,
          bool? verified,
          bool? nameLocked,
          int? lastSeen}) =>
      Contact(
        peerHex: peerHex,
        signingPublicB64: signingPublicB64,
        kexPublicB64: kexPublicB64,
        displayName: displayName ?? this.displayName,
        verified: verified ?? this.verified,
        nameLocked: nameLocked ?? this.nameLocked,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}
