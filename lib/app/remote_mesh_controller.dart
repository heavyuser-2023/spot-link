import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path/path.dart' as p;

import '../core/ble/mesh_transport.dart' show RadioStatus;
import '../core/crypto/identity.dart';
import '../core/model/peer_id.dart';
import '../core/model/qr_payload.dart';
import '../data/app_database.dart';
import '../data/identity_store.dart';
import '../data/models.dart';
import '../l10n/l10n.dart';
import 'background_service.dart';
import 'beacon_wake.dart';
import 'bridge_protocol.dart';
import 'mesh_frontend.dart';
import 'mesh_frontend_state.dart';
import 'notification_service.dart';
import 'permissions.dart';
import 'app_paths.dart';

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

  /// 서비스 isolate로부터 마지막으로 **어떤** 브리지 메시지든 받은 시각.
  /// 살아 있는 메시는 프레즌스 틱(10초)마다 notifyListeners → snapshot을
  /// 보내므로, 이것이 이만큼 오래 침묵하면 isolate가 죽은 것이다 —
  /// Java 서비스 껍데기는 계속 "실행 중"으로 보고돼 [BackgroundService.start]
  /// 재시도가 전부 no-op이 되는 좀비 상태([BackgroundService.restart] 참고).
  DateTime? _lastServiceData;
  DateTime? _lastRevive;
  static const Duration _serviceSilence = Duration(seconds: 45);
  static const Duration _reviveCooldown = Duration(seconds: 60);

  /// keepalive 틱마다: 좀비 서비스(껍데기 생존 + isolate 침묵)를 감지하면
  /// 강제 재시작한다. 2026-07-30 확진 사건 — 안드로이드 메시가 죽은 채
  /// 프로세스만 살아 토치를 쏘고, 사용자가 옆에서 앱을 열어도(=이 컨트롤러가
  /// 붙어도) 아무것도 메시를 되살리지 못했다 — 의 UI측 회생 경로.
  Future<void> _maybeReviveService() async {
    final last = _lastServiceData;
    // 첫 snapshot 전은 기존 start()+hello 재시도 경로가 다루되, 그 경로가
    // 좀비에 막혀 있으면(= init부터 침묵) 여기로 넘어온다.
    final silentFor = DateTime.now()
        .difference(last ?? _bootAt);
    if (silentFor < _serviceSilence) return;
    final lastTry = _lastRevive;
    if (lastTry != null &&
        DateTime.now().difference(lastTry) < _reviveCooldown) {
      return;
    }
    _lastRevive = DateTime.now();
    try {
      await BackgroundService.restart();
    } catch (_) {} // 재시작 실패 — 다음 쿨다운 후 재시도
  }

  final DateTime _bootAt = DateTime.now();

  /// 브리지를 올린다: 소유 서비스가 실행 중인지 확인한 뒤 그 첫 상태
  /// snapshot을 기다린다. 타임아웃 시 예외를 던져 호출자의 재시도 루프
  /// (부트스트랩 스플래시)가 계속 주도권을 갖게 한다.
  Future<void> init() async {
    _firstSnap = Completer<void>();
    // UI isolate도 공유 DB에서 직접 메시지를 읽는다 — 경로 재해석 기준 주입.
    try {
      AppDatabase.documentsDir =
          (await AppPaths.dataDir()).path;
    } catch (_) {}
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
      _lastError ??= systemS.errServiceConnecting;
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
      // 좀비 서비스 회생 — start()/hello가 전부 no-op이 되는 "껍데기 생존 +
      // isolate 사망"을 감지해 강제 재시작한다([_maybeReviveService]).
      unawaited(_maybeReviveService());
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
    // 유효한 브리지 메시지 = 서비스 isolate 생존 증거([_maybeReviveService]).
    _lastServiceData = DateTime.now();
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
    _myAvatar = m['meAvatar'] as String? ?? _myAvatar;
    _avatarCustomized = m['meAvCustom'] as bool? ?? _avatarCustomized;

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
    lastViaHex
      ..clear()
      ..addAll(asMap(m['via']).map((k, v) => MapEntry(k, v as String)));
    liveLanes
      ..clear()
      ..addAll(asMap(m['lanes']).map((k, v) => MapEntry(k, v as String)));
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
    reactionCache
      ..clear()
      ..addAll(await db.reactionsFor(peerHex));
    notifyListeners();
  }

  @override
  Future<void> toggleReaction(
      String peerHex, String msgId, String emoji) async {
    // 낙관적 미러: 서비스가 DB에 확정하면 rev 갱신으로 다시 읽는다.
    final list = reactionCache[msgId] ??= [];
    final had = list.any((r) => r.fromMe && r.emoji == emoji);
    if (had) {
      list.removeWhere((r) => r.fromMe && r.emoji == emoji);
    } else {
      list.add(Reaction(msgId: msgId, emoji: emoji, fromMe: true));
    }
    notifyListeners();
    _send({
      'c': Bridge.cmdToggleReaction,
      'p': peerHex,
      'id': msgId,
      'e': emoji,
    });
  }

  // ---- MeshFrontend: 신원 / 프로필 ----

  @override
  String get displayName => _displayName;

  @override
  PeerId get myId => identity.peerId;

  /// QR 상호 인증 논스 — 여기(UI isolate)서 만들고 브리지로 서비스에 등록한다:
  /// 되돌아오는 verify 프레임은 서비스 isolate에 도착하기 때문이다.
  Uint8List? _qrNonce;
  DateTime? _qrNonceAt;

  @override
  String get myQrPayload {
    final now = DateTime.now();
    if (_qrNonce == null ||
        _qrNonceAt == null ||
        now.difference(_qrNonceAt!) > const Duration(minutes: 5)) {
      final rng = Random.secure();
      _qrNonce =
          Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
      _qrNonceAt = now;
      _send({'c': Bridge.cmdArmQrNonce, 'n': base64Encode(_qrNonce!)});
    }
    return QrPayload.encode(identity.publicBundle, _displayName,
        nonce: _qrNonce);
  }

  @override
  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _displayName = trimmed;
    _send({'c': Bridge.cmdSetName, 'v': trimmed});
    notifyListeners();
  }

  String? _myAvatar;
  bool _avatarCustomized = true; // 첫 snapshot 전에는 넛지를 띄우지 않는다

  @override
  String? get myAvatar => _myAvatar;

  @override
  bool get avatarCustomized => _avatarCustomized;

  @override
  Future<void> setAvatarRecipe(String recipe) async {
    _myAvatar = recipe; // 낙관적 미러 — 권위 값은 다음 snapshot으로 도착
    _avatarCustomized = true;
    _send({'c': Bridge.cmdSetAvatar, 'v': recipe});
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

  final DateTime _createdAt = DateTime.now();

  @override
  bool get radioVerdictSettled =>
      started ||
      radioStatus == RadioStatus.poweredOff ||
      DateTime.now().difference(_createdAt) > const Duration(seconds: 8);
  @override
  bool get powerSaver => _powerSaver;

  @override
  Future<void> boostDiscovery() async {
    _send({'c': Bridge.cmdBoostDiscovery});
  }

  @override
  void setPowerSaver(bool saver) {
    _powerSaver = saver;
    _send({'c': Bridge.cmdSetSaver, 'v': saver});
    notifyListeners();
  }

  // ---- MeshFrontend: 프레즌스 / 연락처 ----

  @override
  Future<Contact> addContactFromBundle(Uint8List bundle,
      {String? name, bool verified = true, Uint8List? verifyNonce}) async {
    _send({
      'c': Bridge.cmdAddContact,
      'b': base64Encode(bundle),
      'name': name,
      'v': verified,
      if (verifyNonce != null) 'n': base64Encode(verifyNonce),
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
    final dir = await AppPaths.dataDir();
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
