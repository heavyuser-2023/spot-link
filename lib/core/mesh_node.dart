import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'ble/mesh_transport.dart';
import 'crypto/identity.dart';
import 'crypto/session.dart';
import 'model/announce.dart';
import 'model/frame.dart';
import 'model/peer_id.dart';
import 'model/text_envelope.dart';
import 'router/router.dart';
import 'router/seen_cache.dart';
import 'router/store_forward.dart';
import 'transfer/fast_lane.dart';
import 'transfer/file_transfer.dart';

/// ACK payload kinds (first byte of an ACK frame's decrypted-agnostic payload).
class _AckKind {
  static const int message = 0; // followed by 16-byte acked msgId
  static const int file = 1; // followed by FileAck bytes
}

/// Base class for events surfaced to the application/UI layer.
sealed class NodeEvent {}

class PeerAnnounced extends NodeEvent {
  final ContactIdentity contact;

  /// Mesh distance: 1 = direct neighbour, 2 = one relay between us, …
  final int hops;
  PeerAnnounced(this.contact, {this.hops = 1});
}

class LinksChanged extends NodeEvent {
  final int count;
  LinksChanged(this.count);
}

class TextReceived extends NodeEvent {
  final PeerId from;
  final String text;
  final String msgId;

  /// Sender's send time (their clock), null for legacy peers. Lets the UI
  /// show "sent at / arrived at" — meaningful for store-and-forward texts
  /// that land long after they were written.
  final DateTime? sentAt;
  TextReceived(this.from, this.text, this.msgId, {this.sentAt});
}

/// A locally originated message was delivered end-to-end (ACK returned).
class DeliveryConfirmed extends NodeEvent {
  final String msgId;
  DeliveryConfirmed(this.msgId);
}

/// A locally originated text message was not acknowledged after all retries.
class TextDeliveryFailed extends NodeEvent {
  final String msgId;
  TextDeliveryFailed(this.msgId);
}

class FileOffered extends NodeEvent {
  final PeerId from;
  final FileMeta meta;
  FileOffered(this.from, this.meta);
}

class FileProgress extends NodeEvent {
  final String transferId;
  final double progress;
  final bool outgoing;
  FileProgress(this.transferId, this.progress, this.outgoing);
}

/// A file transfer gave up (send watchdog or receive recovery timed out).
class FileFailed extends NodeEvent {
  final String transferIdHex;
  final String name;
  final bool incoming;
  FileFailed(this.transferIdHex, this.name, {required this.incoming});
}

/// A file finished arriving. The payload stays ON DISK ([path], the
/// receiver's part file, hash-verified) — the app layer moves it into place.
/// Handing bytes here used to spike RAM by 2× the file size at completion.
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

/// The heart of the app: turns raw BLE packets into an encrypted, multi-hop,
/// store-and-forward messaging service. Platform BLE lives entirely in
/// [MeshTransport]; routing/crypto/transfer are the tested pure modules.
class MeshNode {
  final Identity identity;

  /// Our advertised display name. Mutable so the user can rename live; a change
  /// re-announces to current neighbours (see [updateDisplayName]).
  String displayName;

  late final MeshTransportInterface transport;
  late final Router router;
  late final SessionCrypto crypto;
  final SeenCache seen;
  final StoreForward store;

  /// Known kex public keys by peer id hex (learned via ANNOUNCE or contacts).
  final Map<String, Uint8List> _knownKex = {};

  /// Known Ed25519 signing keys by peer id hex. Safe to learn from ANNOUNCE:
  /// the peer id is SHA-256(bundle), so keys and id are cryptographically
  /// bound. Used to verify delivery receipts.
  final Map<String, Uint8List> _knownSigning = {};

  /// Tombstones: msgIds proven delivered by a signed receipt. Never stored,
  /// relayed, or re-pulled again (prevents "zombie" revival by a phone that
  /// was offline during the cleanup). Rebuilt from persisted receipts on
  /// restart via [rebuildReceipts].
  final _receipted = <String>{};
  static const int _receiptedCap = 4096;

  /// Active transfers.
  final Map<String, FileSender> _senders = {};
  final Map<String, FileReceiver> _receivers = {};
  final Map<String, PeerId> _receiverPeers = {};

  /// Where an incoming transfer's partial file lives while chunks arrive.
  /// The app layer points this at its documents dir; the default keeps tests
  /// and headless use working without setup.
  String Function(String tidHex) incomingPartPath = (tid) =>
      '${Directory.systemTemp.path}/spotlink_incoming_$tid.part';

  /// Receiver-side recovery timers: while a transfer is incomplete they
  /// periodically re-ACK the missing seqs so a lost tail can't stall forever.
  final Map<String, Timer> _rxTimers = {};

  /// Sender-side watchdogs: retire a transfer that never completes.
  final Map<String, Timer> _senderTimers = {};

  /// Transfers we finished receiving — kept briefly so a lost final ACK (which
  /// would otherwise strand the sender) is re-sent when a duplicate chunk lands.
  final Set<String> _completedTransfers = {};

  /// Transfers whose completion (streaming hash verify + finalize) is in
  /// flight. finalize() awaits disk I/O of up to [maxFileBytes], during which
  /// the receiver is still in [_receivers]; a stray/duplicate chunk (BLE) or
  /// the other path (fast lane) arriving in that window would otherwise
  /// re-enter finalize and double-emit FileReceived / spuriously report an
  /// integrity failure. Both completion sites gate on this.
  final Set<String> _finalizing = {};

  /// Reasonable ceiling for a single file over BLE (see docs §8).
  static const int maxFileBytes = 100 * 1024 * 1024;
  static const Duration _fileAckInterval = Duration(milliseconds: 700);

  /// A transfer fails only when it makes NO progress for this long — an
  /// absolute deadline is wrong for BLE, where a large file legitimately
  /// takes many minutes.
  static const Duration _transferIdleTimeout = Duration(seconds: 60);

  /// Receiver ACK policy: ask for missing chunks when the sender has gone
  /// quiet for [_ackIdleGap] (burst done / stall), plus a slow heartbeat every
  /// [_ackHeartbeat] during an active burst so the sender knows we're alive.
  static const Duration _ackIdleGap = Duration(seconds: 2);
  static const Duration _ackHeartbeat = Duration(seconds: 5);

  /// Cap the missing-list in one ACK: 4B per seq, so this keeps the ACK frame
  /// small; later ACKs report the remaining gaps iteratively.
  static const int _ackMaxMissing = 64;

  /// Transfers whose initial chunk burst is still streaming out. Resend
  /// requests are ignored meanwhile — the requested chunks are already on the
  /// way, and honoring them would duplicate the whole burst.
  final Set<String> _streaming = {};

  /// Receiver-side liveness/ack bookkeeping per transfer.
  final Map<String, DateTime> _rxLastChunk = {};
  final Map<String, DateTime> _rxLastAck = {};
  final Map<String, int> _rxLastPct = {};

  /// How often we re-announce presence to neighbours so a peer that walks away
  /// can be aged out of "nearby". Also refreshes contact metadata.
  static const Duration announceInterval = Duration(seconds: 8);

  /// Presence floods this many hops so peers reachable via relays show up as
  /// "주변 · n홉". Deliberately smaller than [Router.defaultTtl]: presence is
  /// chatty (every node, every 15s) and its privacy blast-radius should stay
  /// small, while messages can still travel the full 7 hops.
  static const int announceTtl = 3;

  /// TTL for text messages, their end-to-end ACKs and delivery receipts.
  /// Effectively unbounded for human-scale meshes (six-degrees diameters):
  /// with duplicate suppression a frame is sent once per link regardless of
  /// TTL, so a large value costs nothing extra — it only lets a
  /// store-and-forwarded frame keep travelling ("언젠가 전달") across many
  /// encounters. Kept below the u8 max as the anti-zombie backstop. Files
  /// keep the default 7 (bulky payloads).
  static const int durableTtl = 64;
  Timer? _announceTimer;

  /// Text messages awaiting an end-to-end ACK, retransmitted until confirmed.
  final Map<String, _PendingText> _awaitingAck = {};
  Timer? _retransmitTimer;
  final Duration retransmitInterval;

  /// Periodic HAVE re-sync on LIVE links. Link-up HAVE alone leaves a hole:
  /// on A—R—B, if the R→B relay hop drops a frame, A's retransmits (same
  /// msgId) are absorbed by R's seen-cache as duplicates and never re-relayed
  /// — with all links stable, nothing ever re-offers R's stored copy to B, so
  /// the text sits undelivered until some link happens to bounce. Re-sending
  /// our store inventory on a timer lets a neighbour WANT anything it missed,
  /// closing the loss window without waiting for a reconnect.
  Timer? _haveTimer;
  final Duration haveInterval;
  final int maxTextAttempts;

  /// Msg ids that have reached a terminal delivery state, so we never emit both
  /// DeliveryConfirmed and TextDeliveryFailed for the same message (a late ACK
  /// can race the give-up tick). Delivery always wins.
  final _confirmedText = <String>{};

  /// Bounded dedup of locally-delivered messages. The routing seen-cache
  /// expires after 10 min (for loop prevention); this longer-lived guard stops
  /// a re-pulled store-and-forward frame from being delivered to the app twice.
  final _deliveredIncoming = <String>{};
  static const int _deliveredIncomingCap = 2048;

  /// Messages addressed to US that the router marked seen (loop prevention) but
  /// that FAILED to reach the app — decryption threw (a corrupt payload from a
  /// flaky link), or the sender's key wasn't known yet. Without this they were
  /// lost forever: the seen-cache made [selectWanted] stop requesting them AND
  /// made the router drop any resend as a "duplicate", so a single garbled
  /// delivery could silently swallow a message (observed: 3 sent, middle one
  /// never arrived). Tracked here so we keep WANTing a fresh copy and re-run
  /// delivery when it (or a retransmit) arrives, until it actually lands.
  final _pendingLocalDelivery = <String>{};
  static const int _pendingLocalDeliveryCap = 512;

  /// Persistence hook for [_pendingLocalDelivery] (app layer writes a tiny
  /// table): `present` true = add, false = remove. Lets an undelivered
  /// message survive a restart instead of being re-stranded behind the
  /// in-memory routing seen-cache.
  void Function(String msgIdHex, bool present)? onPendingLocalChanged;

  /// Reload persisted pending-delivery ids at startup.
  void seedPendingLocalDelivery(Iterable<String> ids) {
    for (final id in ids) {
      if (_deliveredIncoming.contains(id)) continue;
      _pendingLocalDelivery.add(id);
    }
  }

  final _events = StreamController<NodeEvent>.broadcast();
  final List<StreamSubscription> _subs = [];

  /// Optional Wi-Fi bulk accelerator. Null ⇒ every transfer uses BLE chunking
  /// (unchanged behaviour). When present, large files upgrade to a direct
  /// Wi-Fi channel with automatic BLE fallback. See docs/WIFI_HYBRID_DESIGN.md.
  final FastLaneInterface? fastLane;

  /// Only files at/above this size attempt the fast lane — below it, BLE's
  /// ~1s setup-free start beats Wi-Fi's multi-second handshake.
  static const int fastLaneMinBytes = 256 * 1024;

  /// How long the sender waits for a fast-lane ACCEPT before falling back to
  /// BLE chunking.
  static const Duration fastLaneNegotiateWindow = Duration(seconds: 5);

  /// Pending fast-lane accepts, keyed by transferId, completed when the
  /// receiver's ACCEPT frame arrives (sender side).
  final Map<String, Completer<_FastAccept>> _fastAcceptWaiters = {};

  /// TransferIds currently being delivered over the fast lane (sender or
  /// receiver) — suppresses the parallel BLE chunk path for them.
  final Set<String> _fastActive = {};

  MeshNode({
    required this.identity,
    required this.displayName,
    int Function()? clock,
    MeshTransportInterface? transport,
    this.fastLane,
    this.retransmitInterval = const Duration(seconds: 4),
    this.haveInterval = const Duration(seconds: 15),
    this.maxTextAttempts = 5,
  }) : seen = SeenCache(nowMs: clock ?? _wallClock),
       store = StoreForward(nowMs: clock ?? _wallClock) {
    router = Router(myId: identity.peerId, seen: seen);
    crypto = SessionCrypto(identity);
    this.transport =
        transport ??
        MeshTransport(
          myShortId: identity.peerId,
          infoValue: identity.publicBundle,
        );
    // We always know our own key.
    _knownKex[identity.peerId.hex] = identity.kexPublic;
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  Stream<NodeEvent> get events => _events.stream;
  PeerId get myId => identity.peerId;
  int get linkCount => transport.linkCount;
  int get peerCount => transport.peerCount;

  /// Signal-strength readings for direct neighbours (proximity UI).
  Stream<RssiSample> get rssiSamples => transport.rssiSamples;

  /// Register a contact so we can encrypt to / decrypt from them even before
  /// an ANNOUNCE (e.g. added by QR scan).
  void addContact(ContactIdentity contact) {
    _knownKex[contact.peerId.hex] = contact.kexPublic;
    _knownSigning[contact.peerId.hex] = contact.signingPublic;
  }

  /// Forget a peer's keys (user deleted the contact). If they are still
  /// nearby their next ANNOUNCE re-teaches us — deletion is not a block.
  void removeContact(PeerId peerId) {
    _knownKex.remove(peerId.hex);
    _knownSigning.remove(peerId.hex);
  }

  Future<bool> start() async {
    final ready = await transport.ensureReady();
    if (!ready) {
      _events.add(NodeError('Bluetooth not available/authorized'));
      return false;
    }
    _subs.add(transport.inbound.listen(_onPacket));
    _subs.add(transport.linkEvents.listen(_onLinkEvent));
    await transport.start();
    _announceTimer = Timer.periodic(
      announceInterval,
      (_) => _broadcastAnnounce(),
    );
    _retransmitTimer = Timer.periodic(
      retransmitInterval,
      (_) => _retransmitPending(),
    );
    _haveTimer = Timer.periodic(haveInterval, (_) => _broadcastHave());
    return true;
  }

  /// See [_haveTimer]. One HAVE frame broadcast to every live link; each
  /// neighbour WANTs whatever it lacks and we answer per-link. Skipped while
  /// the store is empty or we're linkless (nothing to offer / no one to hear).
  Future<void> _broadcastHave() async {
    if (transport.linkCount == 0) return;
    var inv = store.inventory();
    if (inv.isEmpty) return;
    // Bound the periodic offer: a big relay store (durable cap 4096 × 16B =
    // 64KB) is too heavy to rebroadcast every tick. Newest entries are the
    // likeliest to still need delivery (map iteration follows insertion
    // order); the full inventory still goes out on every link-up.
    const cap = 512;
    if (inv.length > cap) inv = inv.sublist(inv.length - cap);
    final frame = Frame.create(
      type: FrameType.have,
      ttl: 1,
      src: myId,
      dst: PeerId.broadcast,
      payload: MsgIdList.encode(inv),
    );
    await transport.broadcast(frame.encode());
  }

  /// Re-broadcast unacked text frames (dropped L2 packets, or the recipient was
  /// out of range). Receivers dedup by msgId so re-sends are harmless. Gives up
  /// after [_maxTextAttempts], marking the message failed.
  Future<void> _retransmitPending() async {
    if (_awaitingAck.isEmpty) return;
    final done = <String>[];
    for (final entry in _awaitingAck.entries.toList()) {
      final pending = entry.value;
      pending.attempts++;
      if (pending.attempts > maxTextAttempts) {
        done.add(entry.key);
        // Live retransmits are over, but the frame STAYS in the durable
        // store: it keeps riding along to every device we meet until the
        // recipient's ACK comes back ("언젠가 전달"). The UI shows this as
        // queued, and flips to delivered when the late ACK arrives.
        if (!_confirmedText.contains(entry.key)) {
          _events.add(TextDeliveryFailed(entry.key));
        }
        continue;
      }
      await transport.broadcast(pending.frame.encode());
    }
    for (final k in done) {
      _awaitingAck.remove(k);
    }
  }

  Future<void> _broadcastAnnounce() async {
    if (transport.linkCount == 0) return;
    await transport.broadcast(_announceFrame().encode());
  }

  /// Immediately re-announce presence and (re)kick discovery. Called when the
  /// app returns to the foreground: iOS suspends the 15s presence timer while
  /// backgrounded, so on resume we'd otherwise wait up to a full interval
  /// before peers see us again. This makes online-status / reachability
  /// recover instantly.
  Future<void> wakeUp() async {
    await _broadcastAnnounce();
    transport.wake();
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _retransmitTimer?.cancel();
    _retransmitTimer = null;
    _haveTimer?.cancel();
    _haveTimer = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final t in _rxTimers.values) {
      t.cancel();
    }
    _rxTimers.clear();
    for (final t in _senderTimers.values) {
      t.cancel();
    }
    _senderTimers.clear();
    for (final w in _fastAcceptWaiters.values) {
      if (!w.isCompleted) w.completeError(StateError('node stopped'));
    }
    _fastAcceptWaiters.clear();
    _fastActive.clear();
    for (final s in _senders.values) {
      s.close();
    }
    _senders.clear();
    for (final r in _receivers.values) {
      r.discard();
    }
    _receivers.clear();
    await transport.stop();
  }

  /// Toggle battery-saver (duty-cycled scanning) on the real BLE transport.
  void setPowerSaver(bool saver) {
    final t = transport;
    if (t is MeshTransport) {
      t.setPowerMode(saver ? PowerMode.saver : PowerMode.active);
    }
  }

  bool get powerSaver {
    final t = transport;
    return t is MeshTransport && t.powerMode == PowerMode.saver;
  }

  /// Android BLE scan mode (0=low-power, 1=balanced, 2=low-latency). No-op
  /// elsewhere. See [MeshTransport.setScanMode].
  Future<void> setScanMode(int code) async {
    final t = transport;
    if (t is MeshTransport) await t.setScanMode(code);
  }

  /// iOS: swaps the scan between the wide foreground mode (the only mode
  /// that reliably finds another iPhone on iOS 27) and the filtered
  /// background mode. No-op elsewhere.
  void setForeground(bool foreground) {
    final t = transport;
    if (t is MeshTransport) t.setForeground(foreground);
  }

  /// Rename this node and re-announce to current neighbours so their contact
  /// list updates without waiting for a reconnect.
  Future<void> updateDisplayName(String name) async {
    displayName = name;
    await transport.broadcast(_announceFrame().encode());
  }

  // ---------------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------------

  /// Send a text message to [dst]. Returns the msgId, or null if we don't know
  /// the recipient's key yet.
  /// [sentAt] defaults to now; a user-initiated RESEND passes the original
  /// compose time so the receiver's "sent at" stays truthful (resending after
  /// the undelivered warning is exactly the delayed-delivery case where the
  /// stamp matters most).
  Future<String?> sendText(PeerId dst, String text, {DateTime? sentAt}) async {
    final kex = _knownKex[dst.hex];
    if (kex == null) {
      _events.add(NodeError('Unknown recipient key: ${dst.short}'));
      return null;
    }
    final cipher = await crypto.encrypt(
      // Carries sentAt for the receiver's UI.
      TextEnvelope.encode(text, sentAt: sentAt),
      kex,
    );
    final frame = router.originate(
      type: FrameType.text,
      dst: dst,
      payload: cipher,
      flags: FrameFlags.encrypted | FrameFlags.ackRequested,
      ttl: durableTtl,
    );
    _awaitingAck[frame.msgIdHex] = _PendingText(frame);
    await _dispatch(frame);
    return frame.msgIdHex;
  }

  /// Abandon a previously-sent text so a user-initiated resend (which mints a
  /// NEW msgId) can't be double-delivered by a late store-and-forward copy of
  /// the original. Drops it from the live retransmit set and the durable
  /// store; the recipient never sees the stale id again.
  void forgetText(String msgIdHex) {
    _awaitingAck.remove(msgIdHex);
    store.remove(msgIdHex);
  }

  /// Begin sending a file to [dst]. Returns the transferId.
  ///
  /// [chunkSize] 4 KiB keeps per-chunk overhead (crypto + frame header + routing)
  /// to ~2% and halves the number of frames vs. 2 KiB, which is the dominant
  /// fixed cost per chunk over BLE.
  Future<String?> sendFile(
    PeerId dst, {
    required Uint8List bytes,
    required String name,
    required String mime,
    int chunkSize = 4096,
  }) async {
    final kex = _knownKex[dst.hex];
    if (kex == null) {
      _events.add(NodeError('Unknown recipient key: ${dst.short}'));
      return null;
    }
    if (bytes.length > maxFileBytes) {
      _events.add(
        NodeError('File too large (${bytes.length} bytes, max $maxFileBytes)'),
      );
      return null;
    }
    final sender = FileSender.forFile(
      bytes: bytes,
      name: name,
      mime: mime,
      chunkSize: chunkSize,
    );
    return _startSend(sender, dst, kex);
  }

  /// Like [sendFile] but disk-backed: the file is hashed and chunked straight
  /// from [path], so a large transfer never pins the whole file in RAM.
  Future<String?> sendFilePath(
    PeerId dst, {
    required String path,
    required String name,
    required String mime,
    int chunkSize = 4096,
  }) async {
    final kex = _knownKex[dst.hex];
    if (kex == null) {
      _events.add(NodeError('Unknown recipient key: ${dst.short}'));
      return null;
    }
    final size = await File(path).length();
    if (size > maxFileBytes) {
      _events.add(NodeError('File too large ($size bytes, max $maxFileBytes)'));
      return null;
    }
    final sender = await FileSender.forPath(
      path: path,
      name: name,
      mime: mime,
      chunkSize: chunkSize,
    );
    return _startSend(sender, dst, kex);
  }

  Future<String?> _startSend(FileSender sender, PeerId dst, Uint8List kex) async {
    final tid = sender.meta.transferIdHex;
    bleLogSink?.call(
      'FT send start: ${sender.meta.name} ${sender.meta.fileSize}B '
      'chunks=${sender.meta.totalChunks}',
    );
    _senders[tid] = sender;
    // Watchdog: if no completion ACK arrives, retire the sender so it can't
    // leak forever (e.g. recipient went away, or the final ACK was lost).
    _armSenderWatchdog(tid, sender.meta.name);

    // 1. Send META.
    final metaCipher = await crypto.encrypt(sender.meta.encode(), kex);
    await _dispatch(
      router.originate(
        type: FrameType.fileMeta,
        dst: dst,
        payload: metaCipher,
        flags: FrameFlags.encrypted,
      ),
    );

    // 2. Deliver the bytes. Try the Wi-Fi fast lane for large files; on any
    // failure (no fast lane, no shared capability, connect/stream error) fall
    // back to BLE chunking. The caller gets the transferId immediately so the
    // UI shows the bubble + progress regardless of path.
    unawaited(_deliverFile(sender, dst, kex));
    return tid;
  }

  /// Choose the fast lane when possible, else BLE chunking. Always ends up on
  /// exactly one path per transfer.
  Future<void> _deliverFile(
    FileSender sender,
    PeerId dst,
    Uint8List kex,
  ) async {
    final tid = sender.meta.transferIdHex;
    if (fastLane != null &&
        fastLane!.capabilities.isNotEmpty &&
        sender.meta.fileSize >= fastLaneMinBytes) {
      final ok = await _trySendFast(sender, dst, kex);
      if (ok) return; // fast lane carried it (delivery ACK arrives via BLE)
      if (!_senders.containsKey(tid)) return; // cancelled/retired meanwhile
      bleLogSink?.call(
        'FT fast lane unavailable → BLE fallback: ${sender.meta.name}',
      );
    }
    _streaming.add(tid);
    await _streamChunks(sender, dst, kex);
  }

  /// Sender fast path: offer over BLE, await ACCEPT, dial Wi-Fi, stream the
  /// whole ciphertext. Returns true only if the peer confirmed the bytes.
  Future<bool> _trySendFast(
    FileSender sender,
    PeerId dst,
    Uint8List kex,
  ) async {
    final tid = sender.meta.transferIdHex;
    final caps = fastLane!.capabilities;
    // Offer: transferId(16) + capsBitmask(1).
    var bitmask = 0;
    for (final k in caps) {
      bitmask |= 1 << k.code;
    }
    final offerPlain = Uint8List(17)
      ..setRange(0, 16, sender.meta.transferId)
      ..[16] = bitmask;
    final waiter = _fastAcceptWaiters[tid] = Completer<_FastAccept>();
    await _dispatch(
      router.originate(
        type: FrameType.fileFastOffer,
        dst: dst,
        payload: await crypto.encrypt(offerPlain, kex),
        flags: FrameFlags.encrypted,
      ),
      persist: false,
    );

    _FastAccept accept;
    try {
      accept = await waiter.future.timeout(fastLaneNegotiateWindow);
    } catch (_) {
      _fastAcceptWaiters.remove(tid);
      return false; // no ACCEPT in time → BLE
    } finally {
      _fastAcceptWaiters.remove(tid);
    }

    bleLogSink?.call('FT fast accept: ${accept.offer.kind.name}');
    FastLaneSession? session;
    Timer? feeder;
    try {
      session = await fastLane!.connect(tid, accept.offer);
      if (session == null) {
        bleLogSink?.call('FT fast connect null → BLE');
        return false;
      }
      _fastActive.add(tid);
      // While the fast lane owns the transfer there are no BLE ACKs to feed
      // the idle watchdog, so feed it ourselves for the duration.
      feeder = Timer.periodic(const Duration(seconds: 20),
          (_) => _armSenderWatchdog(tid, sender.meta.name));
      bleLogSink?.call('FT fast connected: ${accept.offer.kind.name}');
      // Send the whole file as one encrypted, length-prefixed blob. Whole-file
      // GCM means the plaintext+ciphertext live in RAM for this call only —
      // transient by design; the BLE path never loads the file at all.
      final cipher = await crypto.encrypt(await sender.readAll(), kex);
      final header = ByteData(4)..setUint32(0, cipher.length, Endian.big);
      session.add(header.buffer.asUint8List());
      session.add(cipher);
      await session.finishSending();
      // The transport may still be flushing queued bytes — Multipeer queues
      // .reliable sends asynchronously, and disconnecting now would drop
      // whatever hasn't left the radio yet. The receiver closes its side once
      // it has assembled the file, so wait for that EOF before closing ours —
      // or for the completion ACK (authoritative; MC's disconnect notice can
      // lag ~30s when two sessions share the same peer pair). Budget scales
      // with size (floor ~512KB/s) so big files aren't cut off.
      try {
        await Future.any([
          session.incoming.drain<void>(),
          _senderRetired(tid),
        ]).timeout(
            Duration(seconds: 30 + sender.meta.fileSize ~/ (512 * 1024)));
      } catch (_) {}
      bleLogSink?.call('FT fast send done: ${sender.meta.name} '
          '(${sender.meta.fileSize}B via ${accept.offer.kind.name})');
      // Wait for the receiver's completion ACK (arrives over BLE) — the
      // watchdog already fails the transfer if it never comes.
      _events.add(FileProgress(tid, 1.0, true));
      return true;
    } catch (e) {
      bleLogSink?.call('FT fast send error: $e');
      return false;
    } finally {
      feeder?.cancel();
      _fastActive.remove(tid);
      await session?.close();
    }
  }

  /// Completes once the sender is retired (complete ACK arrived or it was
  /// cancelled/timed out) — used to end the post-send flush wait early.
  Future<void> _senderRetired(String tid) async {
    while (_senders.containsKey(tid)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// Keep the sender watchdog fed. It is (re)armed on send start and on every
  /// ACK from the receiver — so a transfer dies only after real silence.
  void _armSenderWatchdog(String tid, String name) {
    _senderTimers[tid]?.cancel();
    _senderTimers[tid] = Timer(_transferIdleTimeout, () {
      final sender = _senders.remove(tid);
      if (sender != null) {
        sender.close();
        _senderTimers.remove(tid);
        _streaming.remove(tid);
        bleLogSink?.call('FT send timeout: $name');
        _events.add(FileFailed(tid, name, incoming: false));
        _events.add(NodeError('File transfer timed out: $name'));
      }
    });
  }

  /// User-initiated cancel of an outgoing transfer (stops the chunk stream).
  void cancelSend(String transferIdHex) {
    final sender = _senders.remove(transferIdHex);
    if (sender != null) {
      sender.close();
      _senderTimers.remove(transferIdHex)?.cancel();
      _streaming.remove(transferIdHex);
      bleLogSink?.call('FT send cancelled: $transferIdHex');
    }
  }

  Future<void> _streamChunks(
    FileSender sender,
    PeerId dst,
    Uint8List kex,
  ) async {
    final tid = sender.meta.transferIdHex;
    var sent = 0;
    var lastPct = -1;
    try {
      for (final chunk in sender.allChunks()) {
        // Retired mid-burst (completed early, timed out, cancelled, stopped).
        if (!_senders.containsKey(tid)) return;
        final cipher = await crypto.encrypt(chunk.encode(), kex);
        await _dispatch(
          router.originate(
            type: FrameType.fileChunk,
            dst: dst,
            payload: cipher,
            flags: FrameFlags.encrypted,
          ),
          persist: false,
        );
        sent++;
        // Throttle progress events: one per percent, not one per chunk.
        final pct = sent * 100 ~/ sender.meta.totalChunks;
        if (pct != lastPct || sent == sender.meta.totalChunks) {
          lastPct = pct;
          _events.add(FileProgress(tid, sent / sender.meta.totalChunks, true));
        }
      }
      bleLogSink?.call(
        'FT send burst done: ${sender.meta.name} ($sent chunks)',
      );
    } catch (e) {
      bleLogSink?.call('FT send burst error: $e');
    } finally {
      _streaming.remove(tid);
    }
  }

  /// Route a locally originated frame: send to neighbours and (by default) keep
  /// a copy for store-and-forward so peers we meet later still receive it.
  ///
  /// [persist] is false for high-volume file chunks: they are only useful to the
  /// direct recipient during an active transfer (recovered via ACK/resend, not
  /// store-and-forward), and adding thousands of them would thrash the bounded
  /// store — the main throughput killer for large files.
  Future<void> _dispatch(Frame frame, {bool persist = true}) async {
    if (persist) store.add(frame);
    await transport.broadcast(frame.encode());
  }

  // ---------------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------------

  void _onLinkEvent(LinkEvent e) async {
    _events.add(LinksChanged(transport.linkCount));
    if (e.up) {
      // Introduce ourselves and sync our store-and-forward inventory.
      await _sendAnnounce(e.link.id);
      await _sendHave(e.link.id);
      // A fresh link is the best moment to retry unacked texts — push them
      // down the new pipe right now instead of waiting for the retransmit
      // tick or the HAVE/WANT round-trip. Receivers dedup, and this is a
      // free shot: it doesn't count against maxTextAttempts.
      for (final pending in _awaitingAck.values.toList()) {
        await transport.sendToLink(e.link.id, pending.frame.encode());
      }
    }
  }

  /// Build a presence frame through the router so our own msgId is marked
  /// seen — a flooded announce that loops back to us must be dropped, not
  /// delivered or re-relayed.
  Frame _announceFrame() {
    final ann = Announce(
      publicBundle: identity.publicBundle,
      displayName: displayName,
    );
    return router.originate(
      type: FrameType.announce,
      dst: PeerId.broadcast,
      payload: ann.encode(),
      ttl: announceTtl,
    );
  }

  Future<void> _sendAnnounce(String linkId) async {
    await transport.sendToLink(linkId, _announceFrame().encode());
  }

  Future<void> _sendHave(String linkId) async {
    final inv = store.inventory();
    final frame = Frame.create(
      type: FrameType.have,
      ttl: 1,
      src: myId,
      dst: PeerId.broadcast,
      payload: MsgIdList.encode(inv),
    );
    await transport.sendToLink(linkId, frame.encode());
  }

  void _onPacket(InboundPacket pkt) async {
    // Everything here runs on attacker-influenced bytes. A single malformed
    // frame must never crash the receive pipeline, so the whole body is
    // guarded (individual decoders below can throw on hostile input).
    try {
      final Frame frame;
      try {
        frame = Frame.decode(pkt.frameBytes);
      } catch (_) {
        return; // malformed header/length
      }

      // A full-TTL announce came straight from this link's peer: remember who
      // sits on the other end so RSSI polls can attribute their readings
      // (iOS advertisements carry no id, so this is how the mapping happens).
      if (frame.type == FrameType.announce &&
          frame.ttl == announceTtl &&
          pkt.link.remoteShortId == null) {
        pkt.link.remoteShortId = frame.src;
      }

      if (frame.type.isLinkLocal) {
        await _handleLinkLocal(frame, pkt.link.id);
        return;
      }

      // Proven delivered (signed receipt): don't deliver, relay or re-store —
      // this is what keeps a long-offline phone from resurrecting it. But if
      // the sender is still retransmitting at us, its ACK was lost: re-ACK so
      // it can stop (mirrors the duplicate branch below).
      if (_receipted.contains(frame.msgIdHex)) {
        if (frame.type == FrameType.text &&
            frame.ackRequested &&
            frame.dst == myId &&
            _deliveredIncoming.contains(frame.msgIdHex)) {
          await _sendMessageAck(frame.src, frame.msgId);
        }
        return;
      }

      final decision = router.handleIncoming(frame);
      if (decision.duplicate) {
        // Seen before by the router (loop prevention) — but "seen" ≠
        // "delivered". If this frame is addressed to us and we saw it yet
        // never got it to the app (decrypt failed / no key at the time), a
        // resend/re-pull is our chance to deliver it: re-run delivery instead
        // of dropping. This is what stops a single garbled copy from losing
        // the message for good.
        if (frame.dst == myId &&
            !_deliveredIncoming.contains(frame.msgIdHex) &&
            _pendingLocalDelivery.contains(frame.msgIdHex)) {
          await _deliverLocal(frame);
          return;
        }
        // A retransmit of a text we already delivered: the sender's first ACK
        // was likely lost. Re-ACK so it can stop. (The seen-cache drops the
        // frame before _deliverLocal, so this is the only place to recover.)
        if (frame.type == FrameType.text &&
            frame.ackRequested &&
            frame.dst == myId &&
            _deliveredIncoming.contains(frame.msgIdHex)) {
          await _sendMessageAck(frame.src, frame.msgId);
        }
        return;
      }

      if (decision.relay != null) {
        // Presence is ephemeral: relay it live but never store-and-forward it
        // (a stale "nearby" delivered hours later would be a lie).
        if (frame.type != FrameType.announce) {
          store.add(decision.relay!);
        }
        await transport.broadcast(
          decision.relay!.encode(),
          exceptLinkId: pkt.link.id,
        );
      }
      if (decision.deliverLocal) {
        await _deliverLocal(frame);
      }
    } catch (e) {
      _events.add(NodeError('Dropped malformed frame: $e'));
    }
  }

  Future<void> _handleLinkLocal(Frame frame, String linkId) async {
    switch (frame.type) {
      case FrameType.have:
        final remoteHave = MsgIdList.decode(frame.payload);
        final wanted = store.selectWanted(
          remoteHave,
          // "Seen" prevents re-pulling relayed/delivered frames — EXCEPT a
          // message addressed to us that we saw but never delivered (decrypt
          // failed / no key). We must keep requesting a fresh copy of those,
          // or one garbled delivery loses the message for good.
          alreadySeen: (hex) =>
              !_pendingLocalDelivery.contains(hex) &&
              (seen.contains(hex) || _receipted.contains(hex)),
        );
        if (wanted.isNotEmpty) {
          final want = Frame.create(
            type: FrameType.want,
            ttl: 1,
            src: myId,
            dst: PeerId.broadcast,
            payload: MsgIdList.encode(wanted),
          );
          await transport.sendToLink(linkId, want.encode());
        }
        break;
      case FrameType.want:
        final wanted = MsgIdList.decode(frame.payload);
        for (final f in store.framesForWanted(wanted)) {
          await transport.sendToLink(linkId, f.encode());
        }
        break;
      default:
        break;
    }
  }

  Future<void> _deliverLocal(Frame frame) async {
    Uint8List payload = frame.payload;
    if (frame.isEncrypted) {
      final kex = _knownKex[frame.src.hex];
      if (kex == null) {
        // Sender's key not learned yet (e.g. the message travelled further
        // than their ANNOUNCE). Don't burn the frame — park it and retry
        // when their ANNOUNCE arrives ([redeliverParked]).
        if (frame.dst == myId && !store.contains(frame.msgIdHex)) {
          store.add(frame);
          _events.add(NodeError('No key to decrypt from ${frame.src.short}'));
        }
        if (frame.dst == myId) _markPendingLocalDelivery(frame.msgIdHex);
        return;
      }
      try {
        payload = await crypto.decrypt(frame.payload, kex);
      } catch (_) {
        _events.add(NodeError('Decrypt failed from ${frame.src.short}'));
        // A corrupt payload (e.g. a lost fragment on a flaky link): keep
        // wanting a FRESH copy instead of dropping it forever. We hold no
        // copy here (this one is bad), so [selectWanted] can re-request it.
        if (frame.dst == myId) _markPendingLocalDelivery(frame.msgIdHex);
        return;
      }
    }

    switch (frame.type) {
      case FrameType.announce:
        if (frame.src == myId) break; // our own flood echoed back
        try {
          final ann = Announce.decode(payload);
          final contact = ContactIdentity.fromBundle(
            ann.publicBundle,
            displayName: ann.displayName,
          );
          _knownKex[contact.peerId.hex] = contact.kexPublic;
          _knownSigning[contact.peerId.hex] = contact.signingPublic;
          // TTL is decremented once per relay: direct = announceTtl, one
          // relay = announceTtl-1, … Clamp against frames from peers with a
          // different origin TTL (older versions announce with ttl 1).
          final hops = (announceTtl - frame.ttl + 1).clamp(1, announceTtl);
          _events.add(PeerAnnounced(contact, hops: hops));
          // Their key may unlock messages we parked before we knew them.
          unawaited(redeliverParked(from: contact.peerId));
        } catch (_) {}
        break;
      case FrameType.text:
        // Always re-ACK so a retransmitting sender can stop, but only surface a
        // given message to the app once (a re-pulled store-and-forward frame
        // must not create a duplicate).
        if (frame.ackRequested) {
          await _sendMessageAck(frame.src, frame.msgId);
        }
        if (_deliveredIncoming.contains(frame.msgIdHex)) break;
        _rememberDelivered(frame.msgIdHex);
        _clearPendingLocalDelivery(frame.msgIdHex); // finally landed
        final envelope = TextEnvelope.decode(payload);
        // sentAt=none marks a LEGACY sender (pre-v1.5.16 payload) — the
        // field-diagnosis signature for "왜 전송 시각이 안 떠?".
        bleLogSink?.call('MSG recv ${frame.msgIdHex.substring(0, 8)} '
            '(${envelope.text.length} chars, '
            'sentAt=${envelope.sentAt?.toIso8601String() ?? 'none'})');
        _events.add(TextReceived(frame.src, envelope.text, frame.msgIdHex,
            sentAt: envelope.sentAt));
        // Tell the whole mesh this text arrived so relays can drop their
        // copies, and never accept it back ourselves.
        _tombstone(frame.msgIdHex);
        unawaited(_broadcastReceipt(frame.msgId));
        break;
      case FrameType.ack:
        await _handleAck(frame.src, payload);
        break;
      case FrameType.fileMeta:
        final meta = FileMeta.decode(payload);
        // Ignore a re-offer of a transfer already in progress or done.
        if (_receivers.containsKey(meta.transferIdHex) ||
            _completedTransfers.contains(meta.transferIdHex)) {
          break;
        }
        // Trust nothing in a peer-supplied manifest: the sender caps at
        // [maxFileBytes], so a larger fileSize is malformed/hostile. Reject
        // before FileReceiver preallocates the part file to that size.
        if (meta.fileSize < 0 || meta.fileSize > maxFileBytes) {
          bleLogSink?.call('FT recv rejected oversize meta: ${meta.fileSize}');
          break;
        }
        bleLogSink?.call(
          'FT recv meta: ${meta.name} chunks=${meta.totalChunks}',
        );
        _receivers[meta.transferIdHex] =
            FileReceiver(meta, incomingPartPath(meta.transferIdHex));
        _receiverPeers[meta.transferIdHex] = frame.src;
        _startReceiverRecovery(meta.transferIdHex, frame.src);
        _events.add(FileOffered(frame.src, meta));
        break;
      case FrameType.fileChunk:
        await _handleFileChunk(frame.src, payload);
        break;
      case FrameType.fileFastOffer:
        await _handleFastOffer(frame.src, payload);
        break;
      case FrameType.fileFastAccept:
        _handleFastAccept(payload);
        break;
      case FrameType.receipt:
        await _handleReceipt(frame, payload);
        break;
      default:
        break;
    }
  }

  /// Domain-separated bytes the recipient signs to prove delivery of [msgId].
  static Uint8List receiptSignedBytes(Uint8List msgId) =>
      Uint8List.fromList([...utf8.encode('SL-RECEIPT-v1'), ...msgId]);

  /// Flood a signed delivery receipt so every relay still carrying a copy of
  /// the delivered text can drop it ("전파 삭제"). Durable-stored like texts,
  /// so the cleanup itself also reaches long-offline phones eventually.
  Future<void> _broadcastReceipt(Uint8List msgId) async {
    final sig = await identity.sign(receiptSignedBytes(msgId));
    final payload = Uint8List(16 + 64)
      ..setRange(0, 16, msgId)
      ..setRange(16, 80, sig);
    await _dispatch(
      router.originate(
        type: FrameType.receipt,
        dst: PeerId.broadcast,
        ttl: durableTtl,
        payload: payload,
      ),
    );
  }

  /// Verify and apply a delivery receipt: only the message's addressee can
  /// produce a valid signature, so third parties cannot censor-by-receipt.
  Future<void> _handleReceipt(Frame frame, Uint8List payload) async {
    if (payload.length < 80) return; // malformed
    final msgId = Uint8List.fromList(payload.sublist(0, 16));
    final sig = Uint8List.fromList(payload.sublist(16, 80));
    final hex = MsgId.hex(msgId);
    if (_receipted.contains(hex)) return;
    final signer = _knownSigning[frame.src.hex];
    if (signer == null) return; // can't verify → keep relaying, don't delete
    if (!await Identity.verify(receiptSignedBytes(msgId), sig, signer)) {
      return; // forged/corrupt
    }
    // If we still hold the message, the receipt must come from its addressee.
    final held = store.frameFor(hex);
    if (held != null && held.dst != frame.src) return;
    _tombstone(hex);
  }

  /// Bury a delivered msgId: drop our stored copy and refuse to store, relay
  /// or re-pull it ever again.
  void _tombstone(String hex) {
    store.remove(hex);
    _receipted.add(hex);
    while (_receipted.length > _receiptedCap) {
      _receipted.remove(_receipted.first);
    }
  }

  /// Re-apply persisted receipts after the store is seeded (app restart), so
  /// tombstones survive restarts without a table of their own.
  Future<void> rebuildReceipts() async {
    for (final f in store.allFrames()) {
      if (f.type == FrameType.receipt) await _handleReceipt(f, f.payload);
    }
  }

  /// Retry frames addressed to us that were parked because the sender's key
  /// was unknown at the time (delivery removes them via the tombstone).
  Future<void> redeliverParked({PeerId? from}) async {
    for (final f in store.allFrames()) {
      if (f.dst != myId) continue;
      if (from != null && f.src != from) continue;
      await _deliverLocal(f);
    }
  }

  Future<void> _sendMessageAck(PeerId dst, Uint8List ackedMsgId) async {
    final payload = Uint8List(1 + 16)
      ..[0] = _AckKind.message
      ..setRange(1, 17, ackedMsgId);
    final kex = _knownKex[dst.hex];
    final flags = kex != null ? FrameFlags.encrypted : 0;
    final body = kex != null ? await crypto.encrypt(payload, kex) : payload;
    await _dispatch(
      router.originate(
        type: FrameType.ack,
        // The ACK must be able to travel back as far as the text came from,
        // including over store-and-forward hops.
        ttl: durableTtl,
        dst: dst,
        payload: body,
        flags: flags,
      ),
    );
  }

  Future<void> _handleAck(PeerId from, Uint8List payload) async {
    if (payload.isEmpty) return;
    final kind = payload[0];
    if (kind == _AckKind.message) {
      if (payload.length < 17) return; // malformed: ignore
      final ackedId = Uint8List.fromList(payload.sublist(1, 17));
      final hex = MsgId.hex(ackedId);
      store.remove(hex);
      _awaitingAck.remove(hex); // stop retransmitting
      if (_confirmedText.add(hex)) {
        if (_confirmedText.length > _deliveredIncomingCap) {
          _confirmedText.remove(_confirmedText.first);
        }
        bleLogSink?.call('MSG delivered ${hex.substring(0, 8)}');
        _events.add(DeliveryConfirmed(hex));
      }
    } else if (kind == _AckKind.file) {
      if (payload.length < 1 + 19) return; // min FileAck (id16+flag+count2)
      final FileAck ack;
      try {
        ack = FileAck.decode(Uint8List.fromList(payload.sublist(1)));
      } catch (_) {
        return; // malformed file ack
      }
      final sender = _senders[ack.transferIdHex];
      if (sender == null) return;
      final kex = _knownKex[from.hex];
      if (kex == null) return;
      // Any ACK is proof the receiver is alive — keep the transfer going.
      _armSenderWatchdog(ack.transferIdHex, sender.meta.name);
      if (ack.complete) {
        bleLogSink?.call('FT delivered: ${sender.meta.name}');
        _retireSender(ack.transferIdHex);
        _events.add(FileProgress(ack.transferIdHex, 1, true));
        _events.add(DeliveryConfirmed(ack.transferIdHex));
        return;
      }
      // The initial burst is still streaming (BLE) or the fast lane owns the
      // wire: everything "missing" is already on the way. Resending now would
      // duplicate the whole transfer over BLE.
      if (_streaming.contains(ack.transferIdHex) ||
          _fastActive.contains(ack.transferIdHex)) {
        return;
      }
      bleLogSink?.call('FT resend requested: ${ack.missing.length} chunks');
      for (final chunk in sender.chunksToResend(ack)) {
        if (!_senders.containsKey(ack.transferIdHex)) return; // retired
        final cipher = await crypto.encrypt(chunk.encode(), kex);
        await _dispatch(
          router.originate(
            type: FrameType.fileChunk,
            dst: from,
            payload: cipher,
            flags: FrameFlags.encrypted,
          ),
          persist: false,
        );
      }
    }
  }

  void _retireSender(String transferIdHex) {
    _senders.remove(transferIdHex)?.close();
    _senderTimers.remove(transferIdHex)?.cancel();
    _streaming.remove(transferIdHex);
  }

  // ---------------------------------------------------------------------------
  // Wi-Fi fast lane (receiver side). Negotiation rides the BLE mesh; only the
  // file bytes move over Wi-Fi. Any failure leaves the BLE receiver + recovery
  // timer intact, so the transfer completes over BLE instead.
  // ---------------------------------------------------------------------------

  /// Higher = preferred. Native AP-less P2P over the LAN socket.
  static int _lanePreference(FastLaneKind k) =>
      k == FastLaneKind.lanSocket ? 1 : 2;

  Future<void> _handleFastOffer(PeerId from, Uint8List payload) async {
    if (fastLane == null || fastLane!.capabilities.isEmpty) return; // → BLE
    if (payload.length < 17) return;
    final transferId = Uint8List.fromList(payload.sublist(0, 16));
    final tid = MsgId.hex(transferId);
    // Only act if we're actually expecting this transfer and haven't finished.
    final receiver = _receivers[tid];
    if (receiver == null || _completedTransfers.contains(tid)) return;
    if (_fastActive.contains(tid)) return; // already negotiating

    // Intersect capabilities and pick by preference: native AP-less P2P
    // (Wi-Fi Aware/Direct/Multipeer) beats the LAN socket, since it works
    // without a shared access point and is the "purer" direct link.
    final senderMask = payload[16];
    FastLaneKind? chosen;
    for (final k in fastLane!.capabilities) {
      if ((senderMask & (1 << k.code)) != 0) {
        if (chosen == null || _lanePreference(k) > _lanePreference(chosen)) {
          chosen = k;
        }
      }
    }
    if (chosen == null) return; // no shared transport → BLE
    bleLogSink?.call('FT fast offer accepted: ${chosen.name} (tid $tid)');

    final kex = _knownKex[from.hex];
    if (kex == null) return;

    FastLaneInbound? inbound;
    try {
      inbound = await fastLane!.prepareInbound(tid, chosen);
    } catch (_) {
      inbound = null;
    }
    if (inbound == null) return; // couldn't listen → BLE

    _fastActive.add(tid);
    // ACCEPT: transferId(16) + chosenKind(1) + offerLen(2) + offerBlob.
    final blob = inbound.offer.blob;
    final accept = Uint8List(16 + 1 + 2 + blob.length);
    accept.setRange(0, 16, transferId);
    accept[16] = chosen.code;
    ByteData.view(accept.buffer).setUint16(17, blob.length, Endian.big);
    accept.setRange(19, 19 + blob.length, blob);
    await _dispatch(
      router.originate(
        type: FrameType.fileFastAccept,
        dst: from,
        payload: await crypto.encrypt(accept, kex),
        flags: FrameFlags.encrypted,
      ),
      persist: false,
    );

    // Read the file over the fast lane in the background.
    unawaited(_receiveFast(from, tid, kex, inbound));
  }

  Future<void> _receiveFast(
    PeerId from,
    String tid,
    Uint8List kex,
    FastLaneInbound inbound,
  ) async {
    FastLaneSession? session;
    try {
      session = await inbound.session;
      if (session == null) {
        bleLogSink?.call('FT fast recv: no session (peer never connected) → BLE');
        _fastActive.remove(tid);
        return; // sender never connected → BLE recovery timer handles it
      }
      bleLogSink?.call('FT fast recv connected, reading…');
      // Read a 4-byte length prefix then that many ciphertext bytes. Parts are
      // only assembled twice (header parse + completion) so a 100MB transfer
      // isn't O(n²) in copying.
      final buf = BytesBuilder(copy: false);
      int? total; // 4 + ciphertext length, known once the header arrived
      var lastPct = 0;
      await for (final part in session.incoming) {
        buf.add(part);
        _rxLastChunk[tid] = DateTime.now(); // feed the idle watchdog
        if (total == null && buf.length >= 4) {
          final head = buf.takeBytes();
          total = ByteData.view(head.buffer, head.offsetInBytes)
                  .getUint32(0, Endian.big) +
              4;
          buf.add(head);
          bleLogSink?.call('FT fast recv expecting ${total}B');
        }
        if (total == null) continue;
        final pct = (buf.length * 100) ~/ total;
        if (pct >= lastPct + 5 && buf.length < total) {
          lastPct = pct;
          _events.add(FileProgress(tid, buf.length / total, false));
        }
        if (buf.length >= total) {
          final all = buf.takeBytes();
          final cipher = Uint8List.sublistView(all, 4, total);
          final receiver = _receivers[tid];
          // Skip if a BLE chunk already drove this transfer into finalize
          // (shared guard with [_handleFileChunk]); avoids double-finalize.
          if (receiver == null || !_finalizing.add(tid)) return;
          try {
            final bytes = await crypto.decrypt(cipher, kex);
            // Write the plaintext to the part file and verify the manifest
            // hash (finalize) so the ACK below is a genuine complete.
            receiver.seedAssembled(bytes);
            final path = await receiver.finalize();
            bleLogSink?.call('FT fast recv complete: ${receiver.meta.name}');
            _events.add(FileProgress(tid, 1.0, false));
            _events.add(FileReceived(from, receiver.meta, path));
            _completeReceiver(tid);
            _rememberCompleted(tid);
            // Reuse the exact BLE completion path: a signed "complete" ACK
            // stops the sender and flips its bubble to delivered.
            await _sendFileAck(from, receiver.buildAck());
          } finally {
            _finalizing.remove(tid);
          }
          return;
        }
      }
    } catch (e) {
      bleLogSink?.call('FT fast recv error: $e — falling back to BLE');
      // Leave the BLE receiver + recovery timer running: it will ACK the
      // missing chunks and the sender re-sends over BLE.
    } finally {
      _fastActive.remove(tid);
      await session?.close();
    }
  }

  void _handleFastAccept(Uint8List payload) {
    if (payload.length < 19) return;
    final tid = MsgId.hex(Uint8List.fromList(payload.sublist(0, 16)));
    final waiter = _fastAcceptWaiters[tid];
    if (waiter == null || waiter.isCompleted) return;
    final kind = FastLaneKind.fromCode(payload[16]);
    if (kind == null) return;
    final blobLen = ByteData.view(
      payload.buffer,
      payload.offsetInBytes,
    ).getUint16(17, Endian.big);
    if (payload.length < 19 + blobLen) return;
    final blob = Uint8List.fromList(payload.sublist(19, 19 + blobLen));
    waiter.complete(_FastAccept(FastLaneOffer(kind, blob)));
  }

  Future<void> _handleFileChunk(PeerId from, Uint8List payload) async {
    // The fast lane owns this transfer's bytes — ignore any stray BLE chunks.
    // (Both paths can momentarily race during fallback.)
    final FileChunk chunk;
    try {
      chunk = FileChunk.decode(payload);
    } catch (_) {
      return; // malformed chunk
    }
    final tidHex = MsgId.hex(chunk.transferId);
    final receiver = _receivers[tidHex];
    if (receiver == null) {
      // A stray chunk for a transfer we already completed: the sender never
      // got our completion ACK. Re-send it so the sender can stop.
      if (_completedTransfers.contains(tidHex)) {
        await _sendFileAck(from, FileAck(chunk.transferId, true, const []));
      }
      return; // META not seen yet (or already done)
    }
    final isNew = receiver.offer(chunk);
    _rxLastChunk[tidHex] = DateTime.now();
    // Throttle progress events: one per percent, not one per chunk.
    final pct = (receiver.progress * 100).floor();
    if (isNew && (pct != _rxLastPct[tidHex] || receiver.isComplete)) {
      _rxLastPct[tidHex] = pct;
      _events.add(FileProgress(tidHex, receiver.progress, false));
    }

    // `_finalizing.add` returns false if a finalize is already running for this
    // transfer (a duplicate chunk raced into the finalize await window, or the
    // fast lane is finishing it) — skip so we don't double-finalize.
    if (receiver.isComplete && _finalizing.add(tidHex)) {
      try {
        final path = await receiver.finalize();
        bleLogSink?.call('FT recv complete: ${receiver.meta.name}');
        _events.add(FileReceived(from, receiver.meta, path));
        _completeReceiver(tidHex);
        _rememberCompleted(tidHex);
        await _sendFileAck(from, receiver.buildAck());
      } catch (_) {
        // All chunks present but the file hash mismatched. Per-chunk GCM makes
        // this near-impossible; treat as an unrecoverable failure rather than
        // falsely ACKing "complete" (which would stop the sender).
        receiver.discard();
        _completeReceiver(tidHex);
        _events.add(NodeError('File integrity check failed; discarded'));
      } finally {
        _finalizing.remove(tidHex);
      }
    }
    // No in-band partial ACKs here: with a large file, ACKing every N chunks
    // floods the reverse path with huge missing-lists and triggers duplicate
    // resends of chunks that are still in flight. The recovery timer in
    // [_startReceiverRecovery] ACKs on idle/heartbeat instead.
  }

  /// Bounded record of app-delivered message ids (dedup across the routing
  /// seen-cache's shorter TTL).
  void _rememberDelivered(String msgIdHex) {
    _deliveredIncoming.add(msgIdHex);
    while (_deliveredIncoming.length > _deliveredIncomingCap) {
      _deliveredIncoming.remove(_deliveredIncoming.first);
    }
  }

  /// See [_pendingLocalDelivery]. Bounded.
  void _markPendingLocalDelivery(String msgIdHex) {
    if (_deliveredIncoming.contains(msgIdHex)) return;
    if (_pendingLocalDelivery.add(msgIdHex)) {
      onPendingLocalChanged?.call(msgIdHex, true);
    }
    while (_pendingLocalDelivery.length > _pendingLocalDeliveryCap) {
      final evicted = _pendingLocalDelivery.first;
      _pendingLocalDelivery.remove(evicted);
      onPendingLocalChanged?.call(evicted, false);
    }
  }

  void _clearPendingLocalDelivery(String msgIdHex) {
    if (_pendingLocalDelivery.remove(msgIdHex)) {
      onPendingLocalChanged?.call(msgIdHex, false);
    }
  }

  /// Remember a finished transfer so a lost final ACK can be re-sent, bounding
  /// the set so it can't grow without limit over a long-running session.
  void _rememberCompleted(String tidHex) {
    _completedTransfers.add(tidHex);
    const cap = 256;
    while (_completedTransfers.length > cap) {
      _completedTransfers.remove(_completedTransfers.first);
    }
  }

  /// Tear down all receiver-side state for a finished/aborted transfer.
  void _completeReceiver(String tidHex) {
    _receivers.remove(tidHex);
    _receiverPeers.remove(tidHex);
    _rxTimers.remove(tidHex)?.cancel();
    _rxLastChunk.remove(tidHex);
    _rxLastAck.remove(tidHex);
    _rxLastPct.remove(tidHex);
  }

  /// While a transfer is incomplete, ACK the missing seqs when the sender
  /// goes quiet (its burst finished or stalled) plus a slow heartbeat during
  /// an active burst. Gives up only after [_transferIdleTimeout] with NO
  /// incoming chunk — a big file that is still progressing never times out.
  void _startReceiverRecovery(String tidHex, PeerId from) {
    _rxTimers[tidHex]?.cancel();
    _rxLastChunk[tidHex] = DateTime.now();
    _rxLastAck[tidHex] = DateTime.now();
    _rxTimers[tidHex] = Timer.periodic(_fileAckInterval, (t) async {
      final receiver = _receivers[tidHex];
      if (receiver == null || receiver.isComplete) {
        t.cancel();
        return;
      }
      final now = DateTime.now();
      final idle = now.difference(_rxLastChunk[tidHex] ?? now);
      if (idle > _transferIdleTimeout) {
        t.cancel();
        bleLogSink?.call('FT recv timeout: ${receiver.meta.name}');
        receiver.discard();
        _completeReceiver(tidHex);
        _events.add(FileFailed(tidHex, receiver.meta.name, incoming: true));
        _events.add(
          NodeError('Incoming file timed out: ${receiver.meta.name}'),
        );
        return;
      }
      // While the fast lane is delivering, BLE chunks aren't expected — a
      // missing-list ACK now would just trigger a duplicate BLE resend. The
      // idle timeout above still applies (fast parts feed [_rxLastChunk]).
      if (_fastActive.contains(tidHex)) return;
      final sinceAck = now.difference(_rxLastAck[tidHex] ?? now);
      if (idle >= _ackIdleGap || sinceAck >= _ackHeartbeat) {
        _rxLastAck[tidHex] = now;
        await _sendFileAck(from, receiver.buildAck(maxMissing: _ackMaxMissing));
      }
    });
  }

  Future<void> _sendFileAck(PeerId dst, FileAck ack) async {
    final raw = ack.encode();
    final payload = Uint8List(1 + raw.length)
      ..[0] = _AckKind.file
      ..setRange(1, 1 + raw.length, raw);
    final kex = _knownKex[dst.hex];
    final flags = kex != null ? FrameFlags.encrypted : 0;
    final body = kex != null ? await crypto.encrypt(payload, kex) : payload;
    // File ACKs are frequent recovery traffic — no store-and-forward value.
    await _dispatch(
      router.originate(
        type: FrameType.ack,
        dst: dst,
        payload: body,
        flags: flags,
      ),
      persist: false,
    );
  }

  Future<void> dispose() async {
    await stop();
    final t = transport;
    if (t is MeshTransport) {
      await t.dispose();
    }
    await _events.close();
  }
}

/// A text frame awaiting an end-to-end ACK, with a retransmit attempt counter.
class _PendingText {
  final Frame frame;
  int attempts = 0;
  _PendingText(this.frame);
}

/// The receiver's fast-lane ACCEPT, delivered to the waiting sender.
class _FastAccept {
  final FastLaneOffer offer;
  _FastAccept(this.offer);
}
