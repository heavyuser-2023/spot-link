import '../core/model/peer_id.dart';

enum MsgDirection { incoming, outgoing }

enum MsgKind { text, file }

// Values are persisted by index — append only, never reorder.
enum MsgStatus {
  sending,
  sent,
  delivered,
  failed,
  receiving,
  received,

  /// No live route right now; parked in the durable store-and-forward
  /// mailbox and delivered automatically at the next encounter.
  queued,
}

/// A persisted chat message (text or file) in a conversation with one peer.
class ChatMessage {
  final int? id;
  final String peerHex; // conversation partner
  final String msgId; // frame msgId hex (dedup / ack key)
  final MsgDirection direction;
  final MsgKind kind;
  final String? text;
  final String? fileName;
  final String? filePath; // local path for received/sent files
  final int? fileSize;
  final MsgStatus status;
  final int timestamp; // epoch ms

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
      );
}

/// A persisted contact (known remote identity).
class Contact {
  final String peerHex;
  final String signingPublicB64;
  final String kexPublicB64;
  final String displayName;
  final bool verified;

  /// True once the user renamed this contact themselves. A locked name is
  /// never overwritten by the peer's self-announced name (see
  /// MeshController._rememberAnnounced) or by a QR re-scan.
  final bool nameLocked;
  final int lastSeen; // epoch ms, 0 if never

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
