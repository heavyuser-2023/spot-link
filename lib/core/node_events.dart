import 'dart:typed_data';

import 'crypto/identity.dart';
import 'model/peer_id.dart';
import 'transfer/file_transfer.dart';

/// 애플리케이션/UI 계층으로 노출되는 이벤트의 기반 클래스.
sealed class NodeEvent {}

class PeerAnnounced extends NodeEvent {
  final ContactIdentity contact;

  /// 메시 거리: 1 = 직접 이웃, 2 = 우리 사이에 릴레이 하나, …
  final int hops;

  /// 이 announce를 우리에게 건네준 직접 이웃(수신 링크의 반대편). [hops]가
  /// 1이면 발신자 자신이고, 2 이상이면 마지막 릴레이다 — 레이더의 중계 경로
  /// 표시에 쓰인다. 링크가 아직 상대를 식별하지 못했으면 null.
  final PeerId? via;

  /// 발신자의 파츠 아바타 레시피(compact). 없으면 null(이니셜 표시).
  final String? avatar;
  PeerAnnounced(this.contact, {this.hops = 1, this.via, this.avatar});
}

class LinksChanged extends NodeEvent {
  final int count;
  LinksChanged(this.count);
}

class TextReceived extends NodeEvent {
  final PeerId from;
  final String text;
  final String msgId;

  /// 보낸 사람의 전송 시각(그쪽 시계 기준), 레거시 피어의 경우 null. UI가
  /// "보낸 시각 / 도착 시각"을 표시할 수 있게 해준다 — 작성된 지 한참 뒤에야
  /// 도착하는 store-and-forward 텍스트에서 의미가 있다.
  final DateTime? sentAt;
  TextReceived(this.from, this.text, this.msgId, {this.sentAt});
}

/// 로컬에서 보낸 메시지가 종단 간 전달됨(ACK가 돌아옴).
class DeliveryConfirmed extends NodeEvent {
  final String msgId;
  DeliveryConfirmed(this.msgId);
}

/// 로컬에서 보낸 텍스트 메시지가 모든 재시도 후에도 확인(ACK)받지 못함.
class TextDeliveryFailed extends NodeEvent {
  final String msgId;
  TextDeliveryFailed(this.msgId);
}

class FileOffered extends NodeEvent {
  final PeerId from;
  final FileMeta meta;
  FileOffered(this.from, this.meta);
}

/// 상대가 내 QR 논스를 되돌려 보냈다 — 내 QR 화면을 직접 봤다는 증명.
/// 컨트롤러가 논스 유효성을 확인하면 그 상대를 인증된 친구로 승격한다.
class VerifyReceived extends NodeEvent {
  final PeerId from;
  final Uint8List nonce;
  VerifyReceived(this.from, this.nonce);
}

/// 상대가 내 메시지에 이모지 리액션을 추가/제거했다.
class ReactionReceived extends NodeEvent {
  final PeerId from;
  final String targetMsgIdHex;
  final String emoji;
  final bool removed;
  ReactionReceived(this.from, this.targetMsgIdHex, this.emoji, this.removed);
}

/// 파일 바이트가 실제로 이동하는 경로가 확정된 순간('wifi' = fast lane 직결,
/// 'ble' = 블루투스 청킹). 송신·수신 양쪽에서 발생하며 UI가 말풍선에
/// 경로 칩을 그리는 근거다.
/// 멀티홉 BLE 예산을 초과해 보류된 발신 파일. 전송은 실패가 아니라
/// 대기(queued) 상태가 되고, 상대가 직접(1홉)으로 나타나면 앱 계층이
/// 자동 재전송한다 — 중간 노드의 라디오·배터리를 수 분간 점유하는
/// 멀티홉 BLE 대용량 전송을 막는 문지기.
class FileDeferred extends NodeEvent {
  final String transferIdHex;
  final PeerId to;
  final String name;
  final int hops;
  FileDeferred(this.transferIdHex, this.to, this.name, this.hops);
}

class TransferLane extends NodeEvent {
  final String transferIdHex;
  final String lane; // 'wifi' | 'ble'
  TransferLane(this.transferIdHex, this.lane);
}

/// 같은 파일(동일 발신자·이름·크기)의 새 전송이 시작되어 옛 미완료 수신이
/// 대체됨 — 옛 말풍선은 조용히 사라져야 한다(재시도가 성공했는데 옛 유령
/// 수신자의 "실패" 말풍선이 나란히 남아 혼란을 줬다).
class FileSuperseded extends NodeEvent {
  final String oldTransferIdHex;
  FileSuperseded(this.oldTransferIdHex);
}

class FileProgress extends NodeEvent {
  final String transferId;
  final double progress;
  final bool outgoing;
  FileProgress(this.transferId, this.progress, this.outgoing);
}

/// 파일 전송을 포기함(전송 감시 타이머 또는 수신 복구가 타임아웃됨).
class FileFailed extends NodeEvent {
  final String transferIdHex;
  final String name;
  final bool incoming;
  FileFailed(this.transferIdHex, this.name, {required this.incoming});
}

/// 파일이 다 도착함. 페이로드는 디스크에 그대로 남는다([path], 수신 측의
/// 부분 파일, 해시 검증 완료) — 앱 계층이 이를 제자리로 옮긴다.
/// 여기서 바이트를 직접 넘기던 방식은 완료 시점에 파일 크기의 2배만큼 RAM을 치솟게 했다.
class FileReceived extends NodeEvent {
  final PeerId from;
  final FileMeta meta;
  final String path;
  FileReceived(this.from, this.meta, this.path);
}

class NodeError extends NodeEvent {
  final String message;
  NodeError(this.message);
}
