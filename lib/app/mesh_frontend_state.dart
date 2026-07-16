import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../core/model/peer_id.dart';
import '../data/models.dart';
import 'mesh_frontend.dart';

/// 두(BOTH) [MeshFrontend] 구현 — 실제 [MeshController](iOS UI isolate /
/// Android 서비스 isolate)와 [RemoteMeshController] UI 미러 — 이 공유하는
/// 인메모리 상태와 파생 쿼리.
///
/// 프레즌스, 연락처 로스터, 받은편지함 동작이 여기 딱 한 번만 존재한다:
/// 손으로 관리하는 두 사본이 서로 어긋나는 대신, 변경 하나가 모든 플랫폼에서
/// 자동으로 동일해진다.
mixin MeshFrontendState on MeshFrontend {
  /// 피어가 이 시간 창 안에 announce했다면 "근처(nearby)"로 간주한다.
  static const Duration presenceTtl = Duration(seconds: 40);

  /// 이보다 오래된 RSSI 측정값은 더 이상 근접성에 대해 아무것도 말해 주지 않는다.
  static const Duration rssiTtl = Duration(seconds: 40);

  // 소유 컨트롤러가 기록하는 가변 상태(실제 컨트롤러에서는 announce 이벤트로,
  // 미러에서는 스냅샷 적용으로). @protected: 이것은 구현 배관(plumbing)이다 —
  // UI는 MeshFrontend getter를 통해 읽는다.
  @protected
  final List<Contact> contactList = [];
  @protected
  final Map<String, int> lastSeenAt = {}; // peerHex -> announce 시각의 epoch ms
  @protected
  final Map<String, int> lastHopCount = {}; // peerHex -> 메시 거리
  @protected
  final Map<String, double> rssiSmoothed = {}; // peerHex -> EMA dBm
  @protected
  final Map<String, int> rssiSeenAt = {}; // peerHex -> 샘플 시각의 epoch ms
  @protected
  final Map<String, int> unreadCounts = {}; // peerHex -> 읽지 않은 수
  @protected
  final Map<String, ChatMessage> lastMessages = {}; // peerHex -> 최신 메시지
  @protected
  final Map<String, List<ChatMessage>> conversationCache = {};

  /// 일시적인, 사용자에게 보이는 오류(스낵바로 표시됨).
  @protected
  final StreamController<String> errors = StreamController<String>.broadcast();

  @override
  Stream<String> get errorEvents => errors.stream;

  @protected
  void reportError(String message) => errors.add(message);

  @override
  final Map<String, double> transferProgress = {};

  // ---- contacts ----

  @override
  List<Contact> get contacts => List.unmodifiable(contactList);

  @override
  Contact? contactByHex(String peerHex) {
    for (final c in contactList) {
      if (c.peerHex == peerHex) return c;
    }
    return null;
  }

  /// peerHex 기준으로 삽입 또는 교체.
  @protected
  void replaceContact(Contact c) {
    contactList.removeWhere((x) => x.peerHex == c.peerHex);
    contactList.add(c);
  }

  // ---- presence ----

  @override
  bool isNearby(String peerHex) {
    final seen = lastSeenAt[peerHex];
    if (seen == null) return false;
    return DateTime.now().millisecondsSinceEpoch - seen <
        presenceTtl.inMilliseconds;
  }

  @override
  int get nearbyCount => contactList.where((c) => isNearby(c.peerHex)).length;

  @override
  int hopsTo(String peerHex) => lastHopCount[peerHex] ?? 1;

  /// 직접 이웃에 대한 평활화된 RSSI(dBm), 또는 최신 측정값이 없을 때 null
  /// (멀티홉 피어이거나 무선이 조용해진 경우).
  @override
  int? rssiOf(String peerHex) {
    final at = rssiSeenAt[peerHex];
    if (at == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - at > rssiTtl.inMilliseconds) {
      return null;
    }
    return rssiSmoothed[peerHex]?.round();
  }

  // ---- inbox ----

  @override
  List<ChatMessage> conversation(String peerHex) =>
      List.unmodifiable(conversationCache[peerHex] ?? const []);

  @override
  int unreadFor(String peerHex) => unreadCounts[peerHex] ?? 0;

  @override
  int get totalUnread => unreadCounts.values.fold(0, (a, b) => a + b);

  /// 받은편지함: 대화를 나눈 적 있는 모든 사람 또는(OR) 연락처인 사람, 최신
  /// 메시지 순, 그다음 근처 순, 그다음 이름 순.
  @override
  List<ConversationSummary> conversations() {
    final hexes = <String>{
      ...lastMessages.keys,
      ...contactList.map((c) => c.peerHex),
    };
    final list = hexes.map((hex) {
      final contact = contactByHex(hex);
      return ConversationSummary(
        peerHex: hex,
        displayName: contact?.displayName ?? PeerId.fromHex(hex).short,
        verified: contact?.verified ?? false,
        nearby: isNearby(hex),
        lastMessage: lastMessages[hex],
        unread: unreadFor(hex),
      );
    }).toList();
    list.sort((a, b) {
      final at = a.lastMessage?.timestamp ?? 0;
      final bt = b.lastMessage?.timestamp ?? 0;
      if (at != bt) return bt - at; // 최신 순
      final an = a.nearby ? 0 : 1;
      final bn = b.nearby ? 0 : 1;
      if (an != bn) return an - bn;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return list;
  }

  @override
  void dispose() {
    errors.close();
    super.dispose();
  }
}

/// 두 프런트엔드가 그대로 공유하는 로컬 파일 동작. 공유 앱 컨테이너 안의
/// 경로에 대해 작동한다 — 메시는 관여하지 않는다.
mixin LocalFileActions on MeshFrontend {
  /// 오류 싱크, [MeshFrontendState]가 제공한다.
  @protected
  void reportError(String message);

  @override
  Future<void> openFile(ChatMessage msg) async {
    if (msg.filePath == null) return;
    final result = await OpenFilex.open(msg.filePath!);
    if (result.type != ResultType.done) {
      reportError('Could not open file: ${result.message}');
    }
  }

  /// 수신한 이미지/동영상을 기기 사진 갤러리에 저장한다.
  /// 해당 파일 종류가 갤러리에 들어갈 수 없으면 false를 반환한다(그리고 오류를 표시한다).
  @override
  Future<bool> saveToGallery(ChatMessage msg) async {
    final path = msg.filePath;
    if (path == null) return false;
    final mime = lookupMimeType(msg.fileName ?? path) ?? '';
    try {
      if (mime.startsWith('image/')) {
        await Gal.putImage(path);
      } else if (mime.startsWith('video/')) {
        await Gal.putVideo(path);
      } else {
        return false; // 미디어 파일이 아님 — 대신 공유/파일 앱을 사용
      }
      return true;
    } catch (e) {
      reportError('갤러리 저장 실패: $e');
      notifyListeners();
      return false;
    }
  }

  /// 시스템 공유 시트 — "파일 앱에 저장", AirDrop, 기타 앱을 아우른다.
  @override
  Future<void> shareFile(ChatMessage msg) async {
    final path = msg.filePath;
    if (path == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }
}
