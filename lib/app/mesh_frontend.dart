import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/ble/mesh_transport.dart' show RadioStatus;
import '../core/ble/radio_profile.dart' show EncounterLocationPolicy;
import '../core/model/peer_id.dart';
import '../data/models.dart';

/// 대화(받은편지함) 목록의 한 행.
class ConversationSummary {
  final String peerHex;
  final String displayName;
  final bool verified;
  final bool nearby;
  final ChatMessage? lastMessage;
  final int unread;

  ConversationSummary({
    required this.peerHex,
    required this.displayName,
    required this.verified,
    required this.nearby,
    required this.lastMessage,
    required this.unread,
  });
}

/// Flutter UI가 "메시"로부터 필요로 하는 모든 것으로, 메시가 실제로 어디서
/// 실행되는지와 무관하다.
///
/// 두 가지 구현:
/// - [MeshController] — 진짜 두뇌(BLE 노드 + 영속화). iOS에서, 그리고 Android
///   foreground-service isolate 안에서 사용된다.
/// - [RemoteMeshController] — Android UI: foreground-task 메시지 포트를 통해
///   서비스가 소유한 메시를 미러링하는 씬 클라이언트로, BLE 자체는 결코 건드리지
///   않는다. 메시는 정확히 하나의 isolate에만 존재해야 한다 — 메시를 둘 두는 모든
///   조율 방식은 결국 경쟁 상태에 빠져 GATT 서버를 이중으로 만들었다
///   (headless_mesh.dart 이력 참고).
abstract class MeshFrontend extends ChangeNotifier {
  // ---- 신원 / 프로필 ----
  String get displayName;
  PeerId get myId;
  String get myQrPayload;
  Future<void> setDisplayName(String name);

  /// 내 파츠 아바타 레시피(compact, [AvatarCodec]) — null이면 이니셜 아바타.
  String? get myAvatar;

  /// 사용자가 빌더에서 직접 아바타를 저장한 적 있는가. false = 자동 생성
  /// 기본 아바타(내 정보의 커스텀 유도 카드·탭 배지가 이 값으로 뜬다).
  bool get avatarCustomized;

  /// 아바타 레시피를 저장하고 즉시 재announce해 이웃 화면에 반영한다.
  Future<void> setAvatarRecipe(String recipe);

  // ---- 상태 ----
  bool get started;
  int get linkCount;

  /// 서로 다른 연결된 기기 수(상태 칩용). 양방향으로 링크된 피어는 여기서 한 번만
  /// 세며, 각 C:/P: 링크를 세는 [linkCount]와 다르다.
  int get peerCount;
  String? get lastError;
  RadioStatus get radioStatus;

  /// 무선 상태 판정이 **믿을 만한가**. 앱 시작 직후 CoreBluetooth/Android
  /// 스택은 잠시 `unknown`이나 `unauthorized`를 보고한다(권한 프롬프트가 아직
  /// 떠 있는 동안 포함). 그 과도 상태를 그대로 오류 배너로 그리면 정상 시작
  /// 중에도 "블루투스 권한 없음"이 20초 넘게 떠 있다(2026-07-27 신고).
  /// 확정 전에는 배너를 숨긴다 — 단, 명백한 [RadioStatus.poweredOff]는 즉시
  /// 보여준다(그건 과도 상태가 아니다).
  bool get radioVerdictSettled;
  bool get powerSaver;
  void setPowerSaver(bool saver);

  /// 일시적인 사용자 대상 에러(스낵바용).
  Stream<String> get errorEvents;

  /// 사용자가 명시적으로 요청한 즉시 재탐색(친구 탭 당겨서 새로고침).
  /// 다음 self-heal / 적응형 틱을 기다리지 않고 지금 바로: 프레즌스를 다시
  /// announce하고, 광고·스캔을 재활용하며, 탐색 백오프/쿨다운을 비우고
  /// (iOS) 알려진 피어 대기 연결을 재장전하고 (Android) 60초 저지연 스캔
  /// 버스트를 건다. 발견 자체를 기다리지는 않는다 — 새 피어는 평소처럼
  /// 상태 변경 알림으로 도착한다.
  Future<void> boostDiscovery();

  // ---- 프레즌스 / 연락처 ----
  List<Contact> get contacts;
  Contact? contactByHex(String peerHex);
  bool isNearby(String peerHex);
  int get nearbyCount;
  int hopsTo(String peerHex);

  /// 멀티홉 피어의 마지막 릴레이(직접 이웃)의 peerHex. 직접 연결(1홉)이거나
  /// 아직 모르면 null. 레이더의 중계 경로 표시용.
  String? viaOf(String peerHex);

  /// 파일 전송의 실제 경로('wifi'|'ble') 세션 캐시. 영구 값은 메시지 행의
  /// [ChatMessage.lane]에 있다 — UI는 `message.lane ?? laneOf(msgId)`로 읽는다.
  String? laneOf(String msgId);

  /// 이 피어와 주고받은 대화(메시지 이력)가 있는가 — 레이더/목록에서
  /// "대화했던 친구"를 구분하는 근거.
  bool hasChat(String peerHex);
  int? rssiOf(String peerHex);
  /// [verifyNonce]: 스캔한 QR에 실려 있던 상호 인증 논스. 넘기면 상대에게
  /// 암호화해 되돌려 보내 "네 화면을 직접 봤다"를 증명하고, 상대 쪽에서도
  /// 내가 인증된 친구로 승격된다.
  Future<Contact> addContactFromBundle(Uint8List bundle,
      {String? name, bool verified = true, Uint8List? verifyNonce});
  Future<void> deleteContact(String peerHex);
  Future<void> renameContact(String peerHex, String name);

  // ---- 스쳐간 친구(만남 기록) ----

  /// 최신순 만남 기록. 위치는 이 기기에만 저장된다.
  Future<List<Encounter>> encounters();

  /// 기록이 바뀔 때마다 증가한다 — 화면이 다시 읽어야 할 때를 안다.
  int get encounterRev;

  /// 이 플랫폼이 만남에 위치를 붙이는 방식(설정 안내 문구용).
  EncounterLocationPolicy get encounterLocationPolicy;
  bool get encounterLocationEnabled;
  Future<void> setEncounterLocationEnabled(bool on);
  Future<void> clearEncounters();

  /// 좌표만 있고 장소 이름이 비어 있는 기록을 채운다(온라인일 때만 성공).
  Future<void> resolveEncounterPlaces();

  /// 친구별 자동 메시지(스쳐 지날 때 연결되면 보냄). null·공백이면 끈다.
  Future<void> setAutoMessage(String peerHex, String? message);

  // ---- 릴레이 메일박스(설정 UI) ----
  int get relayStoreCount;
  int get relayStoreBytes;
  Future<void> clearRelayStore();

  // ---- 웨이크 비콘(iOS 전용 토글; Android에서는 의미 없음) ----
  bool get beaconMonitoring;
  Future<void> setBeaconMonitoring(bool on);

  /// iOS 전용: 웨이크 비콘은 켜져 있지만 위치 권한이 "사용 중에만"에 불과해서, OS가
  /// 백그라운드에서 우리를 깨우지 못한다 — 앱 스스로는 이를 고칠 수 없고(iOS는 한 번
  /// 거부되면 반복되는 업그레이드 프롬프트를 무시한다), 사용자가 설정에서 "항상"으로
  /// 바꿔야 한다. 홈 경고 배너를 구동한다. Android에서는 항상 false다.
  bool get beaconNeedsAlways;

  // ---- 받은편지함 / 대화 ----
  List<ConversationSummary> conversations();
  List<ChatMessage> conversation(String peerHex);
  int unreadFor(String peerHex);
  int get totalUnread;
  Future<void> openConversation(String peerHex);
  void closeConversation();

  // ---- 메시징 ----
  Future<void> sendText(String peerHex, String text);
  Future<void> retryText(ChatMessage failed);
  Future<void> sendFile(String peerHex,
      {required Uint8List bytes, required String name, required String mime});

  /// 경로가 있을 때는 [sendFile]보다 선호된다: 파일을 디스크에서 곧바로 해싱하고
  /// 청크로 나누므로, 큰 전송이 전체 페이로드를 RAM에 고정하는 일이 결코 없다
  /// (iOS에서 jetsam의 먹잇감이 된다).
  Future<void> sendFilePath(String peerHex,
      {required String path, required String name, required String mime});
  Future<void> cancelFile(ChatMessage msg);
  Future<void> retryFile(ChatMessage failed);
  Future<void> deleteMessage(ChatMessage msg);
  Map<String, double> get transferProgress;

  // ---- 이모지 리액션 ----

  /// 이 메시지에 달린 리액션들(열린 대화 기준 캐시).
  List<Reaction> reactionsOf(String msgId);

  /// 내 리액션 토글: 없으면 추가, 있으면 제거. 상대에게 리액션 프레임이
  /// 전송되며 store-and-forward라 오프라인이어도 나중에 도착한다.
  Future<void> toggleReaction(String peerHex, String msgId, String emoji);

  // ---- 로컬 파일 동작(공유 앱 컨테이너 내 경로에 대해 작동) --
  Future<void> openFile(ChatMessage msg);
  Future<bool> saveToGallery(ChatMessage msg);
  Future<void> shareFile(ChatMessage msg);
}
