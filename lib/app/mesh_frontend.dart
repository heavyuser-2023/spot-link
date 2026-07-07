import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/ble/mesh_transport.dart' show RadioStatus;
import '../core/model/peer_id.dart';
import '../data/models.dart';

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

/// Everything the Flutter UI needs from "the mesh", independent of where the
/// mesh actually runs.
///
/// Two implementations:
/// - [MeshController] — the real brain (BLE node + persistence). Used on iOS,
///   and inside the Android foreground-service isolate.
/// - [RemoteMeshController] — Android UI: a thin client that mirrors the
///   service-owned mesh over the foreground-task message port and NEVER
///   touches BLE itself. The mesh must live in exactly one isolate — every
///   two-mesh coordination scheme eventually raced and doubled the GATT
///   server (see headless_mesh.dart history).
abstract class MeshFrontend extends ChangeNotifier {
  // ---- identity / profile ----
  String get displayName;
  PeerId get myId;
  String get myQrPayload;
  Future<void> setDisplayName(String name);

  // ---- status ----
  bool get started;
  int get linkCount;
  String? get lastError;
  RadioStatus get radioStatus;
  bool get powerSaver;
  void setPowerSaver(bool saver);

  /// Transient, user-facing errors (for snackbars).
  Stream<String> get errorEvents;

  // ---- presence / contacts ----
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

  // ---- relay mailbox (settings UI) ----
  int get relayStoreCount;
  int get relayStoreBytes;
  Future<void> clearRelayStore();

  // ---- wake beacon (iOS-only toggle; meaningless on Android) ----
  bool get beaconMonitoring;
  Future<void> setBeaconMonitoring(bool on);

  // ---- inbox / conversations ----
  List<ConversationSummary> conversations();
  List<ChatMessage> conversation(String peerHex);
  int unreadFor(String peerHex);
  int get totalUnread;
  Future<void> openConversation(String peerHex);
  void closeConversation();

  // ---- messaging ----
  Future<void> sendText(String peerHex, String text);
  Future<void> retryText(ChatMessage failed);
  Future<void> sendFile(String peerHex,
      {required Uint8List bytes, required String name, required String mime});

  /// Preferred over [sendFile] whenever a path exists: the file is hashed
  /// and chunked straight from disk, so a large transfer never pins the whole
  /// payload in RAM (jetsam bait on iOS).
  Future<void> sendFilePath(String peerHex,
      {required String path, required String name, required String mime});
  Future<void> cancelFile(ChatMessage msg);
  Future<void> retryFile(ChatMessage failed);
  Future<void> deleteMessage(ChatMessage msg);
  Map<String, double> get transferProgress;

  // ---- local file actions (operate on paths in the shared app container) --
  Future<void> openFile(ChatMessage msg);
  Future<bool> saveToGallery(ChatMessage msg);
  Future<void> shareFile(ChatMessage msg);
}
