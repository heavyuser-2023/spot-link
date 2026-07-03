import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/ble/mesh_transport.dart' show RadioStatus;
import '../core/crypto/identity.dart';
import '../core/mesh_node.dart';
import '../core/model/peer_id.dart';
import '../core/transfer/file_transfer.dart';
import '../data/app_database.dart';
import '../data/identity_store.dart';
import '../data/models.dart';
import 'background_service.dart';

/// A row in the conversation (inbox) list.
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

/// The application "brain": owns the [MeshNode], persists to [AppDatabase],
/// and exposes observable state to the Flutter UI via [ChangeNotifier].
class MeshController extends ChangeNotifier {
  final Identity identity;
  String displayName;
  final AppDatabase db;
  final IdentityStore identityStore;
  final MeshNode node;

  int linkCount = 0;
  bool started = false;
  bool powerSaver = false;
  String? lastError;

  /// A peer is considered "nearby" if it has announced within this window.
  static const Duration presenceTtl = Duration(seconds: 40);

  final List<Contact> _contacts = [];
  final Map<String, int> _lastSeen = {}; // peerHex -> epoch ms of last announce
  final Map<String, int> _unread = {}; // peerHex -> unread count
  final Map<String, List<ChatMessage>> _conversations = {};
  final Map<String, ChatMessage> _lastMessage = {}; // peerHex -> latest msg
  final Map<String, double> transferProgress = {};
  String? _openPeer; // conversation currently on screen (suppresses unread)

  Timer? _presenceTimer;
  StreamSubscription? _sub;
  StreamSubscription? _availabilitySub;
  bool _restarting = false;
  final _errors = StreamController<String>.broadcast();

  MeshController({
    required this.identity,
    required this.displayName,
    required this.db,
    required this.identityStore,
    MeshNode? node,
  }) : node = node ??
            MeshNode(identity: identity, displayName: displayName);

  /// Transient, user-facing errors (for snackbars).
  Stream<String> get errorEvents => _errors.stream;

  /// Why the radio is unusable (drives the home-screen banner wording).
  RadioStatus get radioStatus => node.transport.radioStatus;

  List<Contact> get contacts => List.unmodifiable(_contacts);
  PeerId get myId => identity.peerId;

  bool isNearby(String peerHex) {
    final seen = _lastSeen[peerHex];
    if (seen == null) return false;
    return DateTime.now().millisecondsSinceEpoch - seen <
        presenceTtl.inMilliseconds;
  }

  int get nearbyCount =>
      _contacts.where((c) => isNearby(c.peerHex)).length;

  List<ChatMessage> conversation(String peerHex) =>
      List.unmodifiable(_conversations[peerHex] ?? const []);

  int unreadFor(String peerHex) => _unread[peerHex] ?? 0;
  int get totalUnread => _unread.values.fold(0, (a, b) => a + b);

  /// The inbox: everyone we have a conversation with OR who is a contact,
  /// most-recent-message first, then nearby, then name.
  List<ConversationSummary> conversations() {
    final hexes = <String>{..._lastMessage.keys, ..._contacts.map((c) => c.peerHex)};
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
      if (at != bt) return bt - at; // most recent first
      final an = a.nearby ? 0 : 1;
      final bn = b.nearby ? 0 : 1;
      if (an != bn) return an - bn;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return list;
  }

  Future<void> init() async {
    _contacts
      ..clear()
      ..addAll(await db.allContacts());
    for (final c in _contacts) {
      node.addContact(ContactIdentity(
        peerId: c.peerId,
        signingPublic: unb64(c.signingPublicB64),
        kexPublic: unb64(c.kexPublicB64),
        displayName: c.displayName,
        verified: c.verified,
      ));
    }
    // Seed the inbox with the last message of each known conversation.
    for (final hex in await db.conversationPeers()) {
      final last = await db.lastMessageFor(hex);
      if (last != null) _lastMessage[hex] = last;
    }

    _sub = node.events.listen(_onEvent);
    started = await node.start();
    if (!started) {
      lastError = 'Bluetooth unavailable';
      // On a fresh install the first start fails because the OS permission
      // prompt is still on screen (or Bluetooth is simply off). Retry as soon
      // as the adapter becomes usable instead of requiring an app restart.
      _availabilitySub =
          node.transport.availabilityChanged.listen(_onTransportAvailable);
    }

    // Refresh the UI periodically so "nearby" presence ages out.
    _presenceTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => notifyListeners());
    notifyListeners();
  }

  /// Late start: the initial [MeshNode.start] failed and the adapter just
  /// became usable (permission granted or Bluetooth switched on).
  Future<void> _onTransportAvailable(bool ok) async {
    if (!ok) {
      // Not usable yet, but the reason may have changed (off vs unauthorized)
      // — refresh the banner wording.
      notifyListeners();
      return;
    }
    if (started || _restarting) return;
    _restarting = true;
    try {
      started = await node.start();
      if (started) {
        lastError = null;
        await _availabilitySub?.cancel();
        _availabilitySub = null;
        await BackgroundService.start();
        notifyListeners();
      }
    } finally {
      _restarting = false;
    }
  }

  Future<void> _onEvent(NodeEvent e) async {
    switch (e) {
      case LinksChanged(:final count):
        linkCount = count;
        BackgroundService.updateStatus(count);
        notifyListeners();
      case PeerAnnounced(:final contact):
        _lastSeen[contact.peerId.hex] =
            DateTime.now().millisecondsSinceEpoch;
        await _rememberAnnounced(contact);
        notifyListeners();
      case TextReceived(:final from, :final text, :final msgId):
        await _onText(from, text, msgId);
      case DeliveryConfirmed(:final msgId):
        await db.updateStatusByMsgId(msgId, MsgStatus.delivered);
        _patchStatus(msgId, MsgStatus.delivered);
        notifyListeners();
      case TextDeliveryFailed(:final msgId):
        await db.updateStatusByMsgId(msgId, MsgStatus.failed);
        _patchStatus(msgId, MsgStatus.failed);
        notifyListeners();
      case FileOffered():
        break;
      case FileProgress(:final transferId, :final progress):
        transferProgress[transferId] = progress;
        notifyListeners();
      case FileReceived(:final from, :final meta, :final bytes):
        await _onFileReceived(from, meta, bytes);
      case NodeError(:final message):
        lastError = message;
        _errors.add(message);
        notifyListeners();
    }
  }

  // ---- contacts ----

  Future<void> _rememberAnnounced(ContactIdentity c) async {
    final existing = await db.contact(c.peerId.hex);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing == null) {
      final contact = Contact(
        peerHex: c.peerId.hex,
        signingPublicB64: b64(c.signingPublic),
        kexPublicB64: b64(c.kexPublic),
        displayName: c.displayName ?? c.peerId.short,
        verified: false,
        lastSeen: now,
      );
      await db.upsertContact(contact);
      _contacts.removeWhere((x) => x.peerHex == contact.peerHex);
      _contacts.add(contact);
    } else {
      // Keep a user-set (verified) name; otherwise adopt the announced name.
      if (!existing.verified &&
          c.displayName != null &&
          c.displayName!.isNotEmpty &&
          c.displayName != existing.displayName) {
        final updated = existing.copyWith(displayName: c.displayName, lastSeen: now);
        await db.upsertContact(updated);
        _replaceContact(updated);
      } else {
        await db.touchContact(c.peerId.hex, now);
      }
    }
  }

  void _replaceContact(Contact c) {
    _contacts.removeWhere((x) => x.peerHex == c.peerHex);
    _contacts.add(c);
  }

  Future<Contact> addContactFromBundle(Uint8List bundle,
      {String? name, bool verified = true}) async {
    final c = ContactIdentity.fromBundle(bundle, displayName: name);
    node.addContact(c);
    final existing = await db.contact(c.peerId.hex);
    final contact = Contact(
      peerHex: c.peerId.hex,
      signingPublicB64: b64(c.signingPublic),
      kexPublicB64: b64(c.kexPublic),
      displayName: name ?? existing?.displayName ?? c.peerId.short,
      verified: verified,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
    );
    await db.upsertContact(contact);
    _replaceContact(contact);
    notifyListeners();
    return contact;
  }

  Future<void> renameContact(String peerHex, String name) async {
    final existing = contactByHex(peerHex);
    if (existing == null) return;
    final updated = existing.copyWith(displayName: name);
    await db.upsertContact(updated);
    _replaceContact(updated);
    notifyListeners();
  }

  Contact? contactByHex(String peerHex) {
    for (final c in _contacts) {
      if (c.peerHex == peerHex) return c;
    }
    return null;
  }

  // ---- identity ----

  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    displayName = trimmed;
    await identityStore.setDisplayName(trimmed);
    await node.updateDisplayName(trimmed);
    notifyListeners();
  }

  void setPowerSaver(bool saver) {
    powerSaver = saver;
    node.setPowerSaver(saver);
    notifyListeners();
  }

  // ---- QR payload ----

  static const _qrPrefix = 'SPOTLINK1:';

  String get myQrPayload {
    final b = b64(identity.publicBundle);
    final n = b64(utf8.encode(displayName));
    return '$_qrPrefix$b:$n';
  }

  static (Uint8List, String)? parseQr(String payload) {
    if (!payload.startsWith(_qrPrefix)) return null;
    final body = payload.substring(_qrPrefix.length);
    final parts = body.split(':');
    if (parts.isEmpty) return null;
    try {
      final bundle = unb64(parts[0]);
      final name = parts.length > 1 ? utf8.decode(unb64(parts[1])) : '';
      if (bundle.length != 64) return null;
      return (bundle, name);
    } catch (_) {
      return null;
    }
  }

  // ---- messaging ----

  Future<void> openConversation(String peerHex) async {
    _openPeer = peerHex;
    _unread.remove(peerHex);
    if (!_conversations.containsKey(peerHex)) {
      // Install a placeholder list *before* the await so messages that arrive
      // during the DB load (via _persistAndCache) are captured, then merge them
      // with the DB snapshot without duplicating.
      final live = <ChatMessage>[];
      _conversations[peerHex] = live;
      final loaded = await db.messagesFor(peerHex);
      final loadedIds = loaded.map((m) => m.id).whereType<int>().toSet();
      final extras =
          live.where((m) => m.id == null || !loadedIds.contains(m.id));
      final merged = [...loaded, ...extras]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _conversations[peerHex] = merged;
    }
    notifyListeners();
  }

  void closeConversation() {
    _openPeer = null;
  }

  Future<void> sendText(String peerHex, String text) async {
    final peer = PeerId.fromHex(peerHex);
    final msgId = await node.sendText(peer, text);
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      peerHex: peerHex,
      msgId: msgId ?? 'local-$now',
      direction: MsgDirection.outgoing,
      kind: MsgKind.text,
      text: text,
      status: msgId == null ? MsgStatus.failed : MsgStatus.sent,
      timestamp: now,
    );
    await _persistAndCache(msg);
  }

  Future<void> retryText(ChatMessage failed) async {
    if (failed.text == null) return;
    final peer = PeerId.fromHex(failed.peerHex);
    final msgId = await node.sendText(peer, failed.text!);
    if (msgId == null) {
      _errors.add('Still unable to send — no route yet');
      return;
    }
    if (failed.id != null) {
      await db.updateMessageDelivery(failed.id!, msgId, MsgStatus.sent);
    }
    _patchMessage(failed.peerHex, failed.msgId,
        newMsgId: msgId, status: MsgStatus.sent);
    notifyListeners();
  }

  Future<void> sendFile(String peerHex,
      {required Uint8List bytes,
      required String name,
      required String mime}) async {
    final peer = PeerId.fromHex(peerHex);
    final now = DateTime.now().millisecondsSinceEpoch;
    final tid = await node.sendFile(peer, bytes: bytes, name: name, mime: mime);
    final msg = ChatMessage(
      peerHex: peerHex,
      msgId: tid ?? 'local-$now',
      direction: MsgDirection.outgoing,
      kind: MsgKind.file,
      fileName: name,
      fileSize: bytes.length,
      status: tid == null ? MsgStatus.failed : MsgStatus.sent,
      timestamp: now,
    );
    // Also keep a local copy of what we sent so it can be re-opened.
    await _persistAndCache(msg);
  }

  Future<void> _onText(PeerId from, String text, String msgId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      peerHex: from.hex,
      msgId: msgId,
      direction: MsgDirection.incoming,
      kind: MsgKind.text,
      text: text,
      status: MsgStatus.received,
      timestamp: now,
    );
    await _persistAndCache(msg, incoming: true);
  }

  Future<void> _onFileReceived(
      PeerId from, FileMeta meta, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(dir.path, 'received'));
    if (!await folder.exists()) await folder.create(recursive: true);
    final safeName = meta.name.replaceAll(RegExp(r'[/\\]'), '_');
    final path = p.join(folder.path, '${meta.transferIdHex}_$safeName');
    await File(path).writeAsBytes(bytes);

    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      peerHex: from.hex,
      msgId: meta.transferIdHex,
      direction: MsgDirection.incoming,
      kind: MsgKind.file,
      fileName: meta.name,
      filePath: path,
      fileSize: meta.fileSize,
      status: MsgStatus.received,
      timestamp: now,
    );
    transferProgress.remove(meta.transferIdHex);
    await _persistAndCache(msg, incoming: true);
  }

  Future<void> _persistAndCache(ChatMessage msg, {bool incoming = false}) async {
    final id = await db.insertMessage(msg);
    final stored = msg.withId(id);
    _conversations[msg.peerHex]?.add(stored);
    _lastMessage[msg.peerHex] = stored;
    if (incoming && msg.peerHex != _openPeer) {
      _unread[msg.peerHex] = (_unread[msg.peerHex] ?? 0) + 1;
    }
    notifyListeners();
  }

  // ---- files ----

  Future<void> openFile(ChatMessage msg) async {
    if (msg.filePath == null) return;
    final result = await OpenFilex.open(msg.filePath!);
    if (result.type != ResultType.done) {
      _errors.add('Could not open file: ${result.message}');
    }
  }

  // ---- helpers ----

  void _patchStatus(String msgId, MsgStatus status) {
    for (final list in _conversations.values) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].msgId == msgId) {
          list[i] = list[i].copyWith(status: status);
        }
      }
    }
    for (final entry in _lastMessage.entries.toList()) {
      if (entry.value.msgId == msgId) {
        _lastMessage[entry.key] = entry.value.copyWith(status: status);
      }
    }
  }

  void _patchMessage(String peerHex, String oldMsgId,
      {required String newMsgId, required MsgStatus status}) {
    final list = _conversations[peerHex];
    if (list != null) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].msgId == oldMsgId) {
          list[i] = list[i].copyWith(msgId: newMsgId, status: status);
        }
      }
    }
    // Keep the inbox summary in sync (it reads _lastMessage), otherwise the
    // row stays stuck on the old failed msgId forever.
    final last = _lastMessage[peerHex];
    if (last != null && last.msgId == oldMsgId) {
      _lastMessage[peerHex] = last.copyWith(msgId: newMsgId, status: status);
    }
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _sub?.cancel();
    _availabilitySub?.cancel();
    _errors.close();
    node.dispose();
    super.dispose();
  }
}
