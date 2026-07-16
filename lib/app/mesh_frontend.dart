import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/ble/mesh_transport.dart' show RadioStatus;
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

  // ---- 상태 ----
  bool get started;
  int get linkCount;

  /// 서로 다른 연결된 기기 수(상태 칩용). 양방향으로 링크된 피어는 여기서 한 번만
  /// 세며, 각 C:/P: 링크를 세는 [linkCount]와 다르다.
  int get peerCount;
  String? get lastError;
  RadioStatus get radioStatus;
  bool get powerSaver;
  void setPowerSaver(bool saver);

  /// 일시적인 사용자 대상 에러(스낵바용).
  Stream<String> get errorEvents;

  // ---- 프레즌스 / 연락처 ----
  List<Contact> get contacts;
  Contact? contactByHex(String peerHex);
  bool isNearby(String peerHex);
  int get nearbyCount;
  int hopsTo(String peerHex);
  int? rssiOf(String peerHex);
  Future<Contact> addContactFromBundle(Uint8List bundle,
      {String? name, bool verified = true});
  Future<void> deleteContact(String peerHex);
  Future<void> renameContact(String peerHex, String name);

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

  // ---- 로컬 파일 동작(공유 앱 컨테이너 내 경로에 대해 작동) --
  Future<void> openFile(ChatMessage msg);
  Future<bool> saveToGallery(ChatMessage msg);
  Future<void> shareFile(ChatMessage msg);
}
