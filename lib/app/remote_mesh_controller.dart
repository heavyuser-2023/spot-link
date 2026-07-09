import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:gal/gal.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/ble/mesh_transport.dart' show RadioStatus;
import '../core/crypto/identity.dart';
import '../core/model/peer_id.dart';
import '../data/app_database.dart';
import '../data/identity_store.dart';
import '../data/models.dart';
import 'background_service.dart';
import 'beacon_wake.dart';
import 'mesh_frontend.dart';
import 'notification_service.dart';
import 'permissions.dart';

/// Android UI-side [MeshFrontend]: a thin client of the mesh that the
/// foreground service owns (see headless_mesh.dart). Holds NO BLE stack —
/// state arrives as JSON snapshots over the task port, commands go back the
/// same way, and chat history is read straight from the shared SQLite file
/// (WAL) whenever the snapshot's `rev` counter moves.
class RemoteMeshController extends MeshFrontend with WidgetsBindingObserver {
  final Identity identity;
  final AppDatabase db;
  final IdentityStore identityStore;

  RemoteMeshController({
    required this.identity,
    required String displayName,
    required this.db,
    required this.identityStore,
  }) : _displayName = displayName;

  // ---- mirrored state (authoritative copy lives in the service) ----
  String _displayName;
  bool _started = false;
  int _linkCount = 0;
  String? _lastError;
  RadioStatus _radio = RadioStatus.unknown;
  // Android runtime BLE permission missing (checked in the UI isolate, which
  // — unlike the service — has an Activity to prompt from). When true and the
  // mesh isn't up, we surface the actionable "권한 없음" banner instead of the
  // vague `unknown` default: without the permission, Android blocks the
  // connectedDevice foreground service, so the service never boots and never
  // sends a real radio status — the UI would otherwise sit on the ambiguous
  // fallback with no hint that permission is the fix.
  bool _blePermMissing = false;
  bool _powerSaver = false;
  int _relayCount = 0;
  int _relayBytes = 0;
  int _rev = -1;

  final List<Contact> _contacts = [];
  final Map<String, int> _lastSeen = {};
  final Map<String, int> _lastHops = {};
  final Map<String, double> _rssi = {};
  final Map<String, int> _rssiAt = {};
  final Map<String, int> _unread = {};
  final Map<String, ChatMessage> _lastMessage = {};
  final Map<String, List<ChatMessage>> _conversations = {};

  @override
  final Map<String, double> transferProgress = {};

  String? _openPeer;
  bool _foreground = true;
  Timer? _keepalive;
  Completer<void>? _firstSnap;
  bool _wired = false;

  final _errors = StreamController<String>.broadcast();

  static const Duration presenceTtl = Duration(seconds: 40);
  static const Duration _rssiTtl = Duration(seconds: 40);

  /// Bring the bridge up: make sure the owning service runs, then wait for
  /// its first state snapshot. Throws on timeout so the caller's retry loop
  /// (bootstrap splash) stays in charge.
  Future<void> init() async {
    _firstSnap = Completer<void>();
    FlutterForegroundTask.addTaskDataCallback(_onData);
    _wired = true;
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed ||
        WidgetsBinding.instance.lifecycleState == null;

    // Instant first paint from the shared DB while the service answers.
    _contacts
      ..clear()
      ..addAll(await db.allContacts());
    for (final hex in await db.conversationPeers()) {
      final last = await db.lastMessageFor(hex);
      if (last != null) _lastMessage[hex] = last;
    }
    notifyListeners();

    // Bring the owning service up. NEVER fatal: if the service can't start
    // (e.g. Android 14+ blocks the connectedDevice foreground service until
    // Bluetooth is granted) we still enter the app in a connecting/offline
    // state and keep retrying in the background. Bricking the splash on a
    // service hiccup — with a 30s hard timeout — was strictly worse: the user
    // couldn't even reach the screens that fix it. (Seen on a fresh S23:
    // "mesh service unreachable: TimeoutException after 0:00:30".)
    try {
      await BackgroundService.start();
    } catch (e) {
      _lastError = 'mesh service start failed: $e';
    }
    _sayHello();

    // Give the happy path a short window to deliver the first snapshot, then
    // proceed regardless. On S21 the snapshot lands in well under a second.
    try {
      await _firstSnap!.future.timeout(const Duration(seconds: 12));
    } catch (_) {
      _lastError ??= '메시 서비스 연결 중…';
      notifyListeners();
    }

    // Persistent bridge keepalive + reconnect. While no snapshot has arrived
    // it re-attempts startService (covers a service that never came up —
    // permission just granted, OEM kill) and nudges a running-but-still-
    // booting service (its onReceiveData re-kicks a stalled mesh boot). Once
    // connected it settles into the plain foreground ping the service uses as
    // its UI-alive heartbeat (>35s silence → service resumes notifying).
    _keepalive = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_firstSnap?.isCompleted ?? true) {
        _send({'c': 'fg', 'v': _foreground});
      } else {
        try {
          await BackgroundService.start();
        } catch (_) {}
        _sayHello();
      }
      notifyListeners();
    });
    // The wake torch (iBeacon TX) is a UI-engine plugin; light it from here.
    unawaited(BeaconWake.startTx());
    // Verify the BLE permission the service needs (it can't prompt itself).
    unawaited(_ensureBlePermission());
  }

  void _sayHello() {
    _send({'c': 'hello'});
    _send({'c': 'fg', 'v': _foreground});
  }

  /// Re-check the runtime BLE permission and, if missing, re-request it (the
  /// UI isolate has an Activity, so the OS prompt can appear — unlike the
  /// headless service). Runs at init and whenever the app returns to the
  /// foreground, so a permission that was denied or auto-revoked (Samsung
  /// "unused-app" cleanup) can recover the moment the user reopens the app.
  /// The `unauthorized` banner + its "설정 열기" button covers the
  /// permanently-denied case where no prompt shows.
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
    // Newly granted: poke the service so it (re)starts now instead of waiting
    // for the keepalive tick — the 'fg' command retries a down mesh.
    if (granted) _send({'c': 'fg', 'v': _foreground});
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
      case 'snap':
        _applySnapshot(m);
      case 'err':
        final msg = m['m'] as String? ?? 'unknown error';
        _lastError = msg;
        _errors.add(msg);
        notifyListeners();
    }
  }

  void _applySnapshot(Map<String, Object?> m) {
    _started = m['started'] == true;
    _linkCount = (m['links'] as num?)?.toInt() ?? 0;
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

    _contacts
      ..clear()
      ..addAll([
        for (final c in (m['contacts'] as List? ?? const []))
          Contact.fromMap((c as Map).cast<String, Object?>()),
      ]);
    _lastSeen
      ..clear()
      ..addAll(asMap(m['seen']).map((k, v) => MapEntry(k, (v as num).toInt())));
    _lastHops
      ..clear()
      ..addAll(asMap(m['hops']).map((k, v) => MapEntry(k, (v as num).toInt())));
    _rssi.clear();
    _rssiAt.clear();
    asMap(m['rssi']).forEach((k, v) {
      final pair = v as List;
      _rssi[k] = (pair[0] as num).toDouble();
      _rssiAt[k] = (pair[1] as num).toInt();
    });
    _unread
      ..clear()
      ..addAll(
          asMap(m['unread']).map((k, v) => MapEntry(k, (v as num).toInt())));
    // The UI suppresses its open conversation's unread locally too — the
    // 'open' command races the next snapshot otherwise.
    if (_openPeer != null) _unread.remove(_openPeer);
    _lastMessage
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
    _conversations[peerHex] = loaded;
    notifyListeners();
  }

  // ---- MeshFrontend: identity / profile ----

  @override
  String get displayName => _displayName;

  @override
  PeerId get myId => identity.peerId;

  @override
  String get myQrPayload {
    final b = b64(identity.publicBundle);
    final n = b64(utf8.encode(_displayName));
    return 'SPOTLINK1:$b:$n';
  }

  @override
  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _displayName = trimmed;
    _send({'c': 'name', 'v': trimmed});
    notifyListeners();
  }

  // ---- MeshFrontend: status ----

  @override
  bool get started => _started;
  @override
  int get linkCount => _linkCount;
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
    _send({'c': 'saver', 'v': saver});
    notifyListeners();
  }

  @override
  Stream<String> get errorEvents => _errors.stream;

  // ---- MeshFrontend: presence / contacts ----

  @override
  List<Contact> get contacts => List.unmodifiable(_contacts);

  @override
  Contact? contactByHex(String peerHex) {
    for (final c in _contacts) {
      if (c.peerHex == peerHex) return c;
    }
    return null;
  }

  @override
  bool isNearby(String peerHex) {
    final seen = _lastSeen[peerHex];
    if (seen == null) return false;
    return DateTime.now().millisecondsSinceEpoch - seen <
        presenceTtl.inMilliseconds;
  }

  @override
  int get nearbyCount => _contacts.where((c) => isNearby(c.peerHex)).length;

  @override
  int hopsTo(String peerHex) => _lastHops[peerHex] ?? 1;

  @override
  int? rssiOf(String peerHex) {
    final at = _rssiAt[peerHex];
    if (at == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - at > _rssiTtl.inMilliseconds) {
      return null;
    }
    return _rssi[peerHex]?.round();
  }

  @override
  Future<Contact> addContactFromBundle(Uint8List bundle,
      {String? name, bool verified = true}) async {
    _send({
      'c': 'addContact',
      'b': base64Encode(bundle),
      'name': name,
      'v': verified,
    });
    // Mirror immediately so the scan screen can confirm without waiting a
    // snapshot round-trip; the authoritative row arrives with the next snap.
    final ci = ContactIdentity.fromBundle(bundle, displayName: name);
    final contact = Contact(
      peerHex: ci.peerId.hex,
      signingPublicB64: b64(ci.signingPublic),
      kexPublicB64: b64(ci.kexPublic),
      displayName: name ?? contactByHex(ci.peerId.hex)?.displayName ??
          ci.peerId.short,
      verified: verified,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
    );
    _contacts.removeWhere((x) => x.peerHex == contact.peerHex);
    _contacts.add(contact);
    notifyListeners();
    return contact;
  }

  @override
  Future<void> deleteContact(String peerHex) async {
    _send({'c': 'delContact', 'p': peerHex});
    _contacts.removeWhere((c) => c.peerHex == peerHex);
    _conversations.remove(peerHex);
    _lastMessage.remove(peerHex);
    _unread.remove(peerHex);
    _lastSeen.remove(peerHex);
    if (_openPeer == peerHex) _openPeer = null;
    notifyListeners();
  }

  @override
  Future<void> renameContact(String peerHex, String name) async {
    _send({'c': 'renameContact', 'p': peerHex, 'name': name});
    final existing = contactByHex(peerHex);
    if (existing != null) {
      _contacts.removeWhere((x) => x.peerHex == peerHex);
      _contacts.add(existing.copyWith(displayName: name));
    }
    notifyListeners();
  }

  // ---- MeshFrontend: relay store ----

  @override
  int get relayStoreCount => _relayCount;
  @override
  int get relayStoreBytes => _relayBytes;

  @override
  Future<void> clearRelayStore() async {
    _send({'c': 'clearRelay'});
    _relayCount = 0;
    _relayBytes = 0;
    notifyListeners();
  }

  // ---- MeshFrontend: wake beacon (iOS-only concept; no-op mirror here) ----

  @override
  bool get beaconMonitoring => false;

  @override
  Future<void> setBeaconMonitoring(bool on) async {}

  // ---- MeshFrontend: inbox / conversations ----

  @override
  List<ConversationSummary> conversations() {
    final hexes = <String>{
      ..._lastMessage.keys,
      ..._contacts.map((c) => c.peerHex),
    };
    final list = hexes.map((hex) {
      final contact = contactByHex(hex);
      return ConversationSummary(
        peerHex: hex,
        displayName: contact?.displayName ?? PeerId.fromHex(hex).short,
        verified: contact?.verified ?? false,
        nearby: isNearby(hex),
        lastMessage: _lastMessage[hex],
        unread: unreadFor(hex),
      );
    }).toList();
    list.sort((a, b) {
      final at = a.lastMessage?.timestamp ?? 0;
      final bt = b.lastMessage?.timestamp ?? 0;
      if (at != bt) return bt - at;
      final an = a.nearby ? 0 : 1;
      final bn = b.nearby ? 0 : 1;
      if (an != bn) return an - bn;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return list;
  }

  @override
  List<ChatMessage> conversation(String peerHex) =>
      List.unmodifiable(_conversations[peerHex] ?? const []);

  @override
  int unreadFor(String peerHex) => _unread[peerHex] ?? 0;

  @override
  int get totalUnread => _unread.values.fold(0, (a, b) => a + b);

  @override
  Future<void> openConversation(String peerHex) async {
    _openPeer = peerHex;
    _unread.remove(peerHex);
    NotificationService.cancelFor(peerHex);
    _send({'c': 'open', 'p': peerHex});
    await _reloadConversation(peerHex);
  }

  @override
  void closeConversation() {
    _openPeer = null;
    _send({'c': 'close'});
  }

  // ---- MeshFrontend: messaging ----

  @override
  Future<void> sendText(String peerHex, String text) async {
    _send({'c': 'send', 'p': peerHex, 'x': text});
  }

  @override
  Future<void> retryText(ChatMessage failed) async {
    _send({'c': 'retryText', 'p': failed.peerHex, 'id': failed.msgId});
  }

  @override
  Future<void> sendFile(String peerHex,
      {required Uint8List bytes,
      required String name,
      required String mime}) async {
    // Bytes never cross the isolate port: hand the service a temp file in
    // the shared app container instead (it cleans up outbox files once sent).
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
    // Same sandbox, so the service isolate reads the path directly; it makes
    // its own durable copy under sent/ before streaming from disk.
    _send({
      'c': 'sendFile',
      'p': peerHex,
      'path': path,
      'name': name,
      'mime': mime,
    });
  }

  @override
  Future<void> cancelFile(ChatMessage msg) async {
    transferProgress.remove(msg.msgId);
    _send({'c': 'cancelFile', 'id': msg.msgId});
    notifyListeners();
  }

  @override
  Future<void> retryFile(ChatMessage failed) async {
    _send({'c': 'retryFile', 'p': failed.peerHex, 'id': failed.msgId});
  }

  @override
  Future<void> deleteMessage(ChatMessage msg) async {
    _send({'c': 'delMsg', 'p': msg.peerHex, 'id': msg.msgId});
    _conversations[msg.peerHex]?.removeWhere((m) => m.msgId == msg.msgId);
    if (_lastMessage[msg.peerHex]?.msgId == msg.msgId) {
      _lastMessage.remove(msg.peerHex);
    }
    notifyListeners();
  }

  // ---- MeshFrontend: local file actions (no mesh involved) ----

  @override
  Future<void> openFile(ChatMessage msg) async {
    if (msg.filePath == null) return;
    final result = await OpenFilex.open(msg.filePath!);
    if (result.type != ResultType.done) {
      _errors.add('Could not open file: ${result.message}');
    }
  }

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
        return false;
      }
      return true;
    } catch (e) {
      _errors.add('갤러리 저장 실패: $e');
      notifyListeners();
      return false;
    }
  }

  @override
  Future<void> shareFile(ChatMessage msg) async {
    final path = msg.filePath;
    if (path == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }

  // ---- lifecycle ----

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _send({'c': 'fg', 'v': _foreground});
    if (_foreground) {
      unawaited(BeaconWake.startTx());
      // Re-verify the BLE permission on every return: it may have been granted
      // in Settings (recovering a service Android blocked for missing it) or
      // auto-revoked while away.
      unawaited(_ensureBlePermission());
      if (_openPeer != null) NotificationService.cancelFor(_openPeer!);
    } else if (state == AppLifecycleState.paused) {
      // Backgrounded = jetsam candidacy: shed rebuildable state now.
      _trimMemory();
    }
  }

  @override
  void didHaveMemoryPressure() => _trimMemory();

  void _trimMemory() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    _conversations.removeWhere((hex, _) => hex != _openPeer);
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
    _send({'c': 'bye'});
    _teardownWiring();
    _errors.close();
    super.dispose();
  }
}
