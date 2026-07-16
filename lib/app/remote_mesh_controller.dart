import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/ble/mesh_transport.dart' show RadioStatus;
import '../core/crypto/identity.dart';
import '../core/model/peer_id.dart';
import '../core/model/qr_payload.dart';
import '../data/app_database.dart';
import '../data/identity_store.dart';
import '../data/models.dart';
import 'background_service.dart';
import 'beacon_wake.dart';
import 'bridge_protocol.dart';
import 'mesh_frontend.dart';
import 'mesh_frontend_state.dart';
import 'notification_service.dart';
import 'permissions.dart';

/// Android UI 측 [MeshFrontend]: 포그라운드 서비스가 소유한 메시의
/// 얇은 클라이언트 (headless_mesh.dart 참조). BLE 스택을 전혀 보유하지 않음 —
/// 상태는 task 포트를 통해 JSON snapshot으로 도착하고, 명령은 같은 경로로
/// 되돌아가며, 채팅 기록은 snapshot의 `rev` 카운터가 움직일 때마다 공유
/// SQLite 파일(WAL)에서 곧바로 읽는다.
///
/// 프레즌스 / 로스터 / 수신함 조회와 로컬 파일 액션은 공유
/// [MeshFrontendState] / [LocalFileActions] 믹스인에 들어 있다.
class RemoteMeshController extends MeshFrontend
    with MeshFrontendState, LocalFileActions, WidgetsBindingObserver {
  final Identity identity;
  final AppDatabase db;
  final IdentityStore identityStore;

  RemoteMeshController({
    required this.identity,
    required String displayName,
    required this.db,
    required this.identityStore,
  }) : _displayName = displayName;

  // ---- 미러링된 상태 (권위 있는 원본은 서비스에 존재) ----
  String _displayName;
  bool _started = false;
  int _linkCount = 0;
  int _peerCount = 0;
  String? _lastError;
  RadioStatus _radio = RadioStatus.unknown;
  // Android 런타임 BLE 권한 누락 (UI isolate에서 확인 — 서비스와 달리 UI
  // isolate에는 권한을 요청할 Activity가 있다). true이고 메시가 올라오지
  // 않은 상태이면, 모호한 `unknown` 기본값 대신 조치 가능한 "권한 없음"
  // 배너를 노출한다: 권한이 없으면 Android가 connectedDevice 포그라운드
  // 서비스를 차단하므로 서비스가 아예 부팅되지 않고 실제 라디오 상태도
  // 보내지 않는다 — 그렇지 않으면 UI는 권한이 해결책이라는 힌트도 없이
  // 모호한 폴백 상태에 머물게 된다.
  bool _blePermMissing = false;
  bool _powerSaver = false;
  int _relayCount = 0;
  int _relayBytes = 0;
  int _rev = -1;

  String? _openPeer;
  bool _foreground = true;
  Timer? _keepalive;
  Completer<void>? _firstSnap;
  bool _wired = false;

  /// 브리지를 올린다: 소유 서비스가 실행 중인지 확인한 뒤 그 첫 상태
  /// snapshot을 기다린다. 타임아웃 시 예외를 던져 호출자의 재시도 루프
  /// (부트스트랩 스플래시)가 계속 주도권을 갖게 한다.
  Future<void> init() async {
    _firstSnap = Completer<void>();
    FlutterForegroundTask.addTaskDataCallback(_onData);
    _wired = true;
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed ||
        WidgetsBinding.instance.lifecycleState == null;

    // 서비스가 응답하는 동안 공유 DB로부터 즉시 첫 화면을 그린다.
    contactList
      ..clear()
      ..addAll(await db.allContacts());
    for (final hex in await db.conversationPeers()) {
      final last = await db.lastMessageFor(hex);
      if (last != null) lastMessages[hex] = last;
    }
    notifyListeners();

    // 소유 서비스를 올린다. 절대 치명적이지 않게: 서비스가 시작되지 못해도
    // (예: Android 14+ 는 Bluetooth 권한이 부여되기 전까지 connectedDevice
    // 포그라운드 서비스를 차단한다) 앱은 연결 중/오프라인 상태로 진입하고
    // 백그라운드에서 계속 재시도한다. 서비스 문제로 스플래시를 먹통으로
    // 만드는 것은 — 30초 하드 타임아웃과 함께 — 명백히 더 나빴다: 사용자가
    // 문제를 해결할 화면에조차 도달할 수 없었다. (갓 초기화한 S23에서 관찰:
    // "mesh service unreachable: TimeoutException after 0:00:30".)
    try {
      await BackgroundService.start();
    } catch (e) {
      _lastError = 'mesh service start failed: $e';
    }
    _sayHello();

    // 정상 경로에 첫 snapshot을 전달할 짧은 시간을 준 뒤, 어떻든 진행한다.
    // S21에서는 snapshot이 1초도 채 안 되어 도착한다.
    try {
      await _firstSnap!.future.timeout(const Duration(seconds: 12));
    } catch (_) {
      _lastError ??= '메시 서비스 연결 중…';
      notifyListeners();
    }

    // 지속적인 브리지 keepalive + 재연결. snapshot이 아직 도착하지 않은
    // 동안에는 startService를 재시도하고 (아예 올라오지 못한 서비스를 커버 —
    // 방금 권한 부여됨, OEM kill) 실행 중이지만 아직 부팅 중인 서비스를
    // 살짝 재촉한다 (그 onReceiveData가 멈춘 메시 부팅을 다시 걷어찬다). 일단
    // 연결되면, 서비스가 UI 생존 하트비트로 사용하는 단순 포그라운드 핑으로
    // 안정화된다 (35초 이상 침묵 → 서비스가 알림 갱신을 재개).
    _keepalive = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_firstSnap?.isCompleted ?? true) {
        _send({'c': Bridge.cmdForeground, 'v': _foreground});
      } else {
        try {
          await BackgroundService.start();
        } catch (_) {}
        _sayHello();
      }
      notifyListeners();
    });
    // 웨이크 토치(iBeacon TX)는 UI 엔진 플러그인이다; 여기서 켠다.
    unawaited(BeaconWake.startTx());
    // 서비스가 필요로 하는 BLE 권한을 확인한다 (서비스는 스스로 요청 불가).
    unawaited(_ensureBlePermission());
  }

  void _sayHello() {
    _send({'c': Bridge.cmdHello});
    _send({'c': Bridge.cmdForeground, 'v': _foreground});
  }

  /// 런타임 BLE 권한을 다시 확인하고, 누락된 경우 재요청한다 (UI isolate에는
  /// Activity가 있어 OS 프롬프트가 뜰 수 있다 — 헤드리스 서비스와 달리).
  /// init 시점과 앱이 포그라운드로 돌아올 때마다 실행되므로, 거부되었거나
  /// 자동 회수된(삼성 "미사용 앱" 정리) 권한을 사용자가 앱을 다시 여는 순간
  /// 복구할 수 있다. 프롬프트가 뜨지 않는 영구 거부 상황은 `unauthorized`
  /// 배너와 그 "설정 열기" 버튼이 커버한다.
  Future<void> _ensureBlePermission() async {
    if (!Platform.isAndroid) return;
    var granted = await Permissions.hasBleGranted();
    if (!granted) {
      granted = await Permissions.request();
    }
    final missing = !granted;
    if (missing != _blePermMissing) {
      _blePermMissing = missing;
      notifyListeners();
    }
    // 방금 권한 부여됨: keepalive 틱을 기다리는 대신 서비스를 찔러 지금
    // (재)시작하게 한다 — 'fg' 명령이 다운된 메시를 재시도한다.
    if (granted) _send({'c': Bridge.cmdForeground, 'v': _foreground});
  }

  void _send(Map<String, Object?> m) =>
      BackgroundService.sendToService(jsonEncode(m));

  void _onData(Object data) {
    if (data is! String) return;
    Map<String, Object?> m;
    try {
      m = (jsonDecode(data) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case Bridge.typeSnapshot:
        _applySnapshot(m);
      case Bridge.typeError:
        final msg = m['m'] as String? ?? 'unknown error';
        _lastError = msg;
        reportError(msg);
        notifyListeners();
    }
  }

  void _applySnapshot(Map<String, Object?> m) {
    _started = m['started'] == true;
    _linkCount = (m['links'] as num?)?.toInt() ?? 0;
    _peerCount = (m['peers'] as num?)?.toInt() ?? _linkCount;
    _lastError = m['err'] as String?;
    final radioIdx = (m['radio'] as num?)?.toInt() ?? 0;
    _radio = RadioStatus
        .values[radioIdx.clamp(0, RadioStatus.values.length - 1)];
    _powerSaver = m['saver'] == true;
    _relayCount = (m['relayN'] as num?)?.toInt() ?? 0;
    _relayBytes = (m['relayB'] as num?)?.toInt() ?? 0;
    _displayName = m['name'] as String? ?? _displayName;

    Map<String, Object?> asMap(Object? o) =>
        (o as Map?)?.cast<String, Object?>() ?? const {};

    contactList
      ..clear()
      ..addAll([
        for (final c in (m['contacts'] as List? ?? const []))
          Contact.fromMap((c as Map).cast<String, Object?>()),
      ]);
    lastSeenAt
      ..clear()
      ..addAll(asMap(m['seen']).map((k, v) => MapEntry(k, (v as num).toInt())));
    lastHopCount
      ..clear()
      ..addAll(asMap(m['hops']).map((k, v) => MapEntry(k, (v as num).toInt())));
    rssiSmoothed.clear();
    rssiSeenAt.clear();
    asMap(m['rssi']).forEach((k, v) {
      final pair = v as List;
      rssiSmoothed[k] = (pair[0] as num).toDouble();
      rssiSeenAt[k] = (pair[1] as num).toInt();
    });
    unreadCounts
      ..clear()
      ..addAll(
          asMap(m['unread']).map((k, v) => MapEntry(k, (v as num).toInt())));
    // UI는 열려 있는 대화의 읽지 않음 수를 로컬에서도 억제한다 — 그렇지
    // 않으면 'open' 명령이 다음 snapshot과 경쟁 상태가 된다.
    if (_openPeer != null) unreadCounts.remove(_openPeer);
    lastMessages
      ..clear()
      ..addAll(asMap(m['last']).map((k, v) =>
          MapEntry(k, ChatMessage.fromMap((v as Map).cast<String, Object?>()))));
    transferProgress
      ..clear()
      ..addAll(
          asMap(m['prog']).map((k, v) => MapEntry(k, (v as num).toDouble())));

    final rev = (m['rev'] as num?)?.toInt() ?? 0;
    if (rev != _rev) {
      _rev = rev;
      final open = _openPeer;
      if (open != null) {
        unawaited(_reloadConversation(open));
      }
    }

    final firstSnap = _firstSnap;
    if (firstSnap != null && !firstSnap.isCompleted) firstSnap.complete();
    notifyListeners();
  }

  Future<void> _reloadConversation(String peerHex) async {
    final loaded = await db.messagesFor(peerHex, limit: 200);
    conversationCache[peerHex] = loaded;
    notifyListeners();
  }

  // ---- MeshFrontend: 신원 / 프로필 ----

  @override
  String get displayName => _displayName;

  @override
  PeerId get myId => identity.peerId;

  @override
  String get myQrPayload => QrPayload.encode(identity.publicBundle, _displayName);

  @override
  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _displayName = trimmed;
    _send({'c': Bridge.cmdSetName, 'v': trimmed});
    notifyListeners();
  }

  // ---- MeshFrontend: 상태 ----

  @override
  bool get started => _started;
  @override
  int get linkCount => _linkCount;

  @override
  int get peerCount => _peerCount;
  @override
  String? get lastError => _lastError;
  @override
  RadioStatus get radioStatus =>
      (_blePermMissing && !_started) ? RadioStatus.unauthorized : _radio;
  @override
  bool get powerSaver => _powerSaver;

  @override
  void setPowerSaver(bool saver) {
    _powerSaver = saver;
    _send({'c': Bridge.cmdSetSaver, 'v': saver});
    notifyListeners();
  }

  // ---- MeshFrontend: 프레즌스 / 연락처 ----

  @override
  Future<Contact> addContactFromBundle(Uint8List bundle,
      {String? name, bool verified = true}) async {
    _send({
      'c': Bridge.cmdAddContact,
      'b': base64Encode(bundle),
      'name': name,
      'v': verified,
    });
    // 스캔 화면이 snapshot 왕복을 기다리지 않고 확인할 수 있도록 즉시
    // 미러링한다; 권위 있는 행은 다음 snap과 함께 도착한다.
    final ci = ContactIdentity.fromBundle(bundle, displayName: name);
    final existing = contactByHex(ci.peerId.hex);
    // 서비스와 동일한 규칙: 사용자가 이름을 바꾼 연락처는 그 이름을 유지한다.
    final nameLocked = existing?.nameLocked ?? false;
    final contact = Contact(
      peerHex: ci.peerId.hex,
      signingPublicB64: b64(ci.signingPublic),
      kexPublicB64: b64(ci.kexPublic),
      displayName: nameLocked
          ? existing!.displayName
          : name ?? existing?.displayName ?? ci.peerId.short,
      verified: verified,
      nameLocked: nameLocked,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
    );
    replaceContact(contact);
    notifyListeners();
    return contact;
  }

  @override
  Future<void> deleteContact(String peerHex) async {
    _send({'c': Bridge.cmdDeleteContact, 'p': peerHex});
    contactList.removeWhere((c) => c.peerHex == peerHex);
    conversationCache.remove(peerHex);
    lastMessages.remove(peerHex);
    unreadCounts.remove(peerHex);
    lastSeenAt.remove(peerHex);
    if (_openPeer == peerHex) _openPeer = null;
    notifyListeners();
  }

  @override
  Future<void> renameContact(String peerHex, String name) async {
    _send({'c': Bridge.cmdRenameContact, 'p': peerHex, 'name': name});
    final existing = contactByHex(peerHex);
    if (existing != null) {
      replaceContact(existing.copyWith(displayName: name, nameLocked: true));
    }
    notifyListeners();
  }

  // ---- MeshFrontend: 릴레이 저장소 ----

  @override
  int get relayStoreCount => _relayCount;
  @override
  int get relayStoreBytes => _relayBytes;

  @override
  Future<void> clearRelayStore() async {
    _send({'c': Bridge.cmdClearRelay});
    _relayCount = 0;
    _relayBytes = 0;
    notifyListeners();
  }

  // ---- MeshFrontend: 웨이크 비콘 (iOS 전용 개념; 여기선 no-op 미러) ----

  @override
  bool get beaconMonitoring => false;

  @override
  bool get beaconNeedsAlways => false; // Android: iOS 비콘 웨이크 권한 없음

  @override
  Future<void> setBeaconMonitoring(bool on) async {}

  // ---- MeshFrontend: 수신함 / 대화 ----

  @override
  Future<void> openConversation(String peerHex) async {
    _openPeer = peerHex;
    unreadCounts.remove(peerHex);
    NotificationService.cancelFor(peerHex);
    _send({'c': Bridge.cmdOpen, 'p': peerHex});
    await _reloadConversation(peerHex);
  }

  @override
  void closeConversation() {
    _openPeer = null;
    _send({'c': Bridge.cmdClose});
  }

  // ---- MeshFrontend: 메시징 ----

  @override
  Future<void> sendText(String peerHex, String text) async {
    _send({'c': Bridge.cmdSendText, 'p': peerHex, 'x': text});
  }

  @override
  Future<void> retryText(ChatMessage failed) async {
    _send({'c': Bridge.cmdRetryText, 'p': failed.peerHex, 'id': failed.msgId});
  }

  @override
  Future<void> sendFile(String peerHex,
      {required Uint8List bytes,
      required String name,
      required String mime}) async {
    // 바이트는 절대 isolate 포트를 건너가지 않는다: 대신 공유 앱 컨테이너의
    // 임시 파일을 서비스에 넘긴다 (전송이 끝나면 outbox 파일을 정리한다).
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(dir.path, 'outbox'));
    if (!await folder.exists()) await folder.create(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[/\\]'), '_');
    final path = p.join(folder.path,
        '${DateTime.now().millisecondsSinceEpoch}_$safeName');
    await File(path).writeAsBytes(bytes);
    await sendFilePath(peerHex, path: path, name: name, mime: mime);
  }

  @override
  Future<void> sendFilePath(String peerHex,
      {required String path,
      required String name,
      required String mime}) async {
    // 같은 샌드박스이므로 서비스 isolate가 경로를 직접 읽는다; 디스크에서
    // 스트리밍하기 전에 sent/ 아래에 자체 영구 복사본을 만든다.
    _send({
      'c': Bridge.cmdSendFile,
      'p': peerHex,
      'path': path,
      'name': name,
      'mime': mime,
    });
  }

  @override
  Future<void> cancelFile(ChatMessage msg) async {
    transferProgress.remove(msg.msgId);
    _send({'c': Bridge.cmdCancelFile, 'id': msg.msgId});
    notifyListeners();
  }

  @override
  Future<void> retryFile(ChatMessage failed) async {
    _send({'c': Bridge.cmdRetryFile, 'p': failed.peerHex, 'id': failed.msgId});
  }

  @override
  Future<void> deleteMessage(ChatMessage msg) async {
    _send({'c': Bridge.cmdDeleteMessage, 'p': msg.peerHex, 'id': msg.msgId});
    conversationCache[msg.peerHex]?.removeWhere((m) => m.msgId == msg.msgId);
    if (lastMessages[msg.peerHex]?.msgId == msg.msgId) {
      lastMessages.remove(msg.peerHex);
    }
    notifyListeners();
  }

  // ---- 로컬 파일 액션: LocalFileActions 참조 ----

  // ---- 생명주기 ----

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _send({'c': Bridge.cmdForeground, 'v': _foreground});
    if (_foreground) {
      unawaited(BeaconWake.startTx());
      // 복귀할 때마다 BLE 권한을 재검증한다: 설정에서 권한이 부여되었거나
      // (권한 누락으로 Android가 차단했던 서비스를 복구) 자리를 비운 사이
      // 자동 회수되었을 수 있다.
      unawaited(_ensureBlePermission());
      if (_openPeer != null) NotificationService.cancelFor(_openPeer!);
    } else if (state == AppLifecycleState.paused) {
      // 백그라운드 전환 = jetsam 대상 후보: 재구성 가능한 상태를 지금 버린다.
      _trimMemory();
    }
  }

  @override
  void didHaveMemoryPressure() => _trimMemory();

  void _trimMemory() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    conversationCache.removeWhere((hex, _) => hex != _openPeer);
  }

  void _teardownWiring() {
    if (_wired) {
      FlutterForegroundTask.removeTaskDataCallback(_onData);
      _wired = false;
    }
    WidgetsBinding.instance.removeObserver(this);
    _keepalive?.cancel();
    _keepalive = null;
  }

  @override
  void dispose() {
    _send({'c': Bridge.cmdBye});
    _teardownWiring();
    super.dispose(); // MeshFrontendState가 에러 스트림을 닫는다
  }
}
