import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'ble/mesh_transport.dart';
import 'crypto/identity.dart';
import 'crypto/session.dart';
import 'model/announce.dart';
import 'model/frame.dart';
import 'model/peer_id.dart';
import 'router/router.dart';
import 'router/seen_cache.dart';
import 'router/store_forward.dart';
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
  TextReceived(this.from, this.text, this.msgId);
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

class FileReceived extends NodeEvent {
  final PeerId from;
  final FileMeta meta;
  final Uint8List bytes;
  FileReceived(this.from, this.meta, this.bytes);
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

  /// Active transfers.
  final Map<String, FileSender> _senders = {};
  final Map<String, FileReceiver> _receivers = {};
  final Map<String, PeerId> _receiverPeers = {};

  /// Receiver-side recovery timers: while a transfer is incomplete they
  /// periodically re-ACK the missing seqs so a lost tail can't stall forever.
  final Map<String, Timer> _rxTimers = {};

  /// Sender-side watchdogs: retire a transfer that never completes.
  final Map<String, Timer> _senderTimers = {};

  /// Transfers we finished receiving — kept briefly so a lost final ACK (which
  /// would otherwise strand the sender) is re-sent when a duplicate chunk lands.
  final Set<String> _completedTransfers = {};

  /// Reasonable ceiling for a single file over BLE (see docs §8).
  static const int maxFileBytes = 20 * 1024 * 1024;
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
  static const Duration announceInterval = Duration(seconds: 15);

  /// Presence floods this many hops so peers reachable via relays show up as
  /// "주변 · n홉". Deliberately smaller than [Router.defaultTtl]: presence is
  /// chatty (every node, every 15s) and its privacy blast-radius should stay
  /// small, while messages can still travel the full 7 hops.
  static const int announceTtl = 3;
  Timer? _announceTimer;

  /// Text messages awaiting an end-to-end ACK, retransmitted until confirmed.
  final Map<String, _PendingText> _awaitingAck = {};
  Timer? _retransmitTimer;
  final Duration retransmitInterval;
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

  final _events = StreamController<NodeEvent>.broadcast();
  final List<StreamSubscription> _subs = [];

  MeshNode({
    required this.identity,
    required this.displayName,
    int Function()? clock,
    MeshTransportInterface? transport,
    this.retransmitInterval = const Duration(seconds: 4),
    this.maxTextAttempts = 5,
  })  : seen = SeenCache(nowMs: clock ?? _wallClock),
        store = StoreForward(nowMs: clock ?? _wallClock) {
    router = Router(myId: identity.peerId, seen: seen);
    crypto = SessionCrypto(identity);
    this.transport = transport ??
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

  /// Register a contact so we can encrypt to / decrypt from them even before
  /// an ANNOUNCE (e.g. added by QR scan).
  void addContact(ContactIdentity contact) {
    _knownKex[contact.peerId.hex] = contact.kexPublic;
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
    _announceTimer =
        Timer.periodic(announceInterval, (_) => _broadcastAnnounce());
    _retransmitTimer =
        Timer.periodic(retransmitInterval, (_) => _retransmitPending());
    return true;
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
        store.remove(entry.key);
        // Don't report failure if a late ACK already confirmed delivery.
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

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _retransmitTimer?.cancel();
    _retransmitTimer = null;
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
    await transport.stop();
  }

  /// Toggle battery-saver (duty-cycled scanning) on the real BLE transport.
  void setPowerSaver(bool saver) {
    final t = transport;
    if (t is MeshTransport) {
      t.setPowerMode(saver ? PowerMode.saver : PowerMode.active);
    }
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
  Future<String?> sendText(PeerId dst, String text) async {
    final kex = _knownKex[dst.hex];
    if (kex == null) {
      _events.add(NodeError('Unknown recipient key: ${dst.short}'));
      return null;
    }
    final cipher = await crypto.encrypt(
        Uint8List.fromList(utf8.encode(text)), kex);
    final frame = router.originate(
      type: FrameType.text,
      dst: dst,
      payload: cipher,
      flags: FrameFlags.encrypted | FrameFlags.ackRequested,
    );
    _awaitingAck[frame.msgIdHex] = _PendingText(frame);
    await _dispatch(frame);
    return frame.msgIdHex;
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
      _events.add(NodeError(
          'File too large (${bytes.length} bytes, max $maxFileBytes)'));
      return null;
    }
    final sender = FileSender.forFile(
        bytes: bytes, name: name, mime: mime, chunkSize: chunkSize);
    final tid = sender.meta.transferIdHex;
    bleLogSink?.call(
        'FT send start: $name ${bytes.length}B chunks=${sender.meta.totalChunks}');
    _senders[tid] = sender;
    // Watchdog: if no completion ACK arrives, retire the sender so it can't
    // leak forever (e.g. recipient went away, or the final ACK was lost).
    _armSenderWatchdog(tid, name);

    // 1. Send META.
    final metaCipher = await crypto.encrypt(sender.meta.encode(), kex);
    await _dispatch(router.originate(
      type: FrameType.fileMeta,
      dst: dst,
      payload: metaCipher,
      flags: FrameFlags.encrypted,
    ));

    // 2. Stream the chunks in the background (gaps are recovered via file
    // ACK). With BLE backpressure a large file takes a while — the caller
    // needs the transferId immediately so the UI can show the outgoing
    // bubble and live progress instead of freezing until the burst ends.
    _streaming.add(tid);
    unawaited(_streamChunks(sender, dst, kex));
    return tid;
  }

  /// Keep the sender watchdog fed. It is (re)armed on send start and on every
  /// ACK from the receiver — so a transfer dies only after real silence.
  void _armSenderWatchdog(String tid, String name) {
    _senderTimers[tid]?.cancel();
    _senderTimers[tid] = Timer(_transferIdleTimeout, () {
      if (_senders.remove(tid) != null) {
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
    if (_senders.remove(transferIdHex) != null) {
      _senderTimers.remove(transferIdHex)?.cancel();
      _streaming.remove(transferIdHex);
      bleLogSink?.call('FT send cancelled: $transferIdHex');
    }
  }

  Future<void> _streamChunks(
      FileSender sender, PeerId dst, Uint8List kex) async {
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
      bleLogSink?.call('FT send burst done: ${sender.meta.name} ($sent chunks)');
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
    }
  }

  /// Build a presence frame through the router so our own msgId is marked
  /// seen — a flooded announce that loops back to us must be dropped, not
  /// delivered or re-relayed.
  Frame _announceFrame() {
    final ann = Announce(
        publicBundle: identity.publicBundle, displayName: displayName);
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

      if (frame.type.isLinkLocal) {
        await _handleLinkLocal(frame, pkt.link.id);
        return;
      }

      final decision = router.handleIncoming(frame);
      if (decision.duplicate) {
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
        await transport.broadcast(decision.relay!.encode(),
            exceptLinkId: pkt.link.id);
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
        final wanted = store.selectWanted(remoteHave,
            alreadySeen: (hex) => seen.contains(hex));
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
        _events.add(NodeError('No key to decrypt from ${frame.src.short}'));
        return;
      }
      try {
        payload = await crypto.decrypt(frame.payload, kex);
      } catch (_) {
        _events.add(NodeError('Decrypt failed from ${frame.src.short}'));
        return;
      }
    }

    switch (frame.type) {
      case FrameType.announce:
        if (frame.src == myId) break; // our own flood echoed back
        try {
          final ann = Announce.decode(payload);
          final contact = ContactIdentity.fromBundle(ann.publicBundle,
              displayName: ann.displayName);
          _knownKex[contact.peerId.hex] = contact.kexPublic;
          // TTL is decremented once per relay: direct = announceTtl, one
          // relay = announceTtl-1, … Clamp against frames from peers with a
          // different origin TTL (older versions announce with ttl 1).
          final hops = (announceTtl - frame.ttl + 1).clamp(1, announceTtl);
          _events.add(PeerAnnounced(contact, hops: hops));
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
        final text = utf8.decode(payload, allowMalformed: true);
        _events.add(TextReceived(frame.src, text, frame.msgIdHex));
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
        bleLogSink?.call(
            'FT recv meta: ${meta.name} chunks=${meta.totalChunks}');
        _receivers[meta.transferIdHex] = FileReceiver(meta);
        _receiverPeers[meta.transferIdHex] = frame.src;
        _startReceiverRecovery(meta.transferIdHex, frame.src);
        _events.add(FileOffered(frame.src, meta));
        break;
      case FrameType.fileChunk:
        await _handleFileChunk(frame.src, payload);
        break;
      case FrameType.receipt:
        store.remove(MsgId.hex(payload.length >= 16
            ? Uint8List.fromList(payload.sublist(0, 16))
            : payload));
        break;
      default:
        break;
    }
  }

  Future<void> _sendMessageAck(PeerId dst, Uint8List ackedMsgId) async {
    final payload = Uint8List(1 + 16)
      ..[0] = _AckKind.message
      ..setRange(1, 17, ackedMsgId);
    final kex = _knownKex[dst.hex];
    final flags = kex != null ? FrameFlags.encrypted : 0;
    final body = kex != null ? await crypto.encrypt(payload, kex) : payload;
    await _dispatch(router.originate(
      type: FrameType.ack,
      dst: dst,
      payload: body,
      flags: flags,
    ));
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
      // The initial burst is still streaming: everything "missing" is already
      // on the way. Resending now would duplicate the whole transfer.
      if (_streaming.contains(ack.transferIdHex)) return;
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
    _senders.remove(transferIdHex);
    _senderTimers.remove(transferIdHex)?.cancel();
    _streaming.remove(transferIdHex);
  }

  Future<void> _handleFileChunk(PeerId from, Uint8List payload) async {
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
        await _sendFileAck(
            from, FileAck(chunk.transferId, true, const []));
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

    if (receiver.isComplete) {
      try {
        final bytes = receiver.assemble();
        bleLogSink?.call('FT recv complete: ${receiver.meta.name}');
        _events.add(FileReceived(from, receiver.meta, bytes));
        _completeReceiver(tidHex);
        _rememberCompleted(tidHex);
        await _sendFileAck(from, receiver.buildAck());
      } catch (_) {
        // All chunks present but the file hash mismatched. Per-chunk GCM makes
        // this near-impossible; treat as an unrecoverable failure rather than
        // falsely ACKing "complete" (which would stop the sender).
        _completeReceiver(tidHex);
        _events.add(NodeError('File integrity check failed; discarded'));
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
        _completeReceiver(tidHex);
        _events.add(FileFailed(tidHex, receiver.meta.name, incoming: true));
        _events.add(NodeError('Incoming file timed out: ${receiver.meta.name}'));
        return;
      }
      final sinceAck = now.difference(_rxLastAck[tidHex] ?? now);
      if (idle >= _ackIdleGap || sinceAck >= _ackHeartbeat) {
        _rxLastAck[tidHex] = now;
        await _sendFileAck(
            from, receiver.buildAck(maxMissing: _ackMaxMissing));
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
