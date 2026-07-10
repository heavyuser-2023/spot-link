import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../core/model/peer_id.dart';
import '../data/models.dart';
import 'mesh_frontend.dart';

/// Shared in-memory state and derived queries for BOTH [MeshFrontend]
/// implementations — the real [MeshController] (iOS UI isolate / Android
/// service isolate) and the [RemoteMeshController] UI mirror.
///
/// Presence, contact-roster and inbox behaviour lives here exactly once:
/// a change is automatically identical on every platform, instead of two
/// hand-kept copies drifting apart.
mixin MeshFrontendState on MeshFrontend {
  /// A peer is considered "nearby" if it has announced within this window.
  static const Duration presenceTtl = Duration(seconds: 40);

  /// An RSSI reading older than this no longer says anything about proximity.
  static const Duration rssiTtl = Duration(seconds: 40);

  // Mutable state, written by the owning controller (announce events on the
  // real controller, snapshot application on the mirror). @protected: this is
  // implementation plumbing — the UI reads through the MeshFrontend getters.
  @protected
  final List<Contact> contactList = [];
  @protected
  final Map<String, int> lastSeenAt = {}; // peerHex -> epoch ms of announce
  @protected
  final Map<String, int> lastHopCount = {}; // peerHex -> mesh distance
  @protected
  final Map<String, double> rssiSmoothed = {}; // peerHex -> EMA dBm
  @protected
  final Map<String, int> rssiSeenAt = {}; // peerHex -> epoch ms of sample
  @protected
  final Map<String, int> unreadCounts = {}; // peerHex -> unread count
  @protected
  final Map<String, ChatMessage> lastMessages = {}; // peerHex -> latest msg
  @protected
  final Map<String, List<ChatMessage>> conversationCache = {};

  /// Transient, user-facing errors (surfaced as snackbars).
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

  /// Insert-or-replace by peerHex.
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

  /// Smoothed RSSI (dBm) for a direct neighbour, or null when we have no
  /// fresh reading (multihop peers, or the radio went quiet).
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

  /// The inbox: everyone we have a conversation with OR who is a contact,
  /// most-recent-message first, then nearby, then name.
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
      if (at != bt) return bt - at; // most recent first
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

/// Local file actions shared verbatim by both frontends. They act on paths in
/// the shared app container — no mesh involved.
mixin LocalFileActions on MeshFrontend {
  /// Error sink, provided by [MeshFrontendState].
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

  /// Save a received image/video into the device photo gallery.
  /// Returns false (and surfaces an error) when the file kind can't go there.
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
        return false; // not a media file — use share/Files instead
      }
      return true;
    } catch (e) {
      reportError('갤러리 저장 실패: $e');
      notifyListeners();
      return false;
    }
  }

  /// System share sheet — covers "파일 앱에 저장", AirDrop, other apps.
  @override
  Future<void> shareFile(ChatMessage msg) async {
    final path = msg.filePath;
    if (path == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }
}
