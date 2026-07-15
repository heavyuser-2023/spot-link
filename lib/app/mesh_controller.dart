import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/ble/mesh_transport.dart'
    show RadioStatus, RssiSample, bleLogSink, knownPeersLoad, knownPeersSave;
import '../core/crypto/identity.dart';
import '../core/mesh_node.dart';
import '../core/model/frame.dart';
import '../core/model/peer_id.dart';
import '../core/model/qr_payload.dart';
import '../core/transfer/composite_fast_lane.dart';
import '../core/transfer/lan_socket_fast_lane.dart';
import '../core/transfer/platform_fast_lane.dart';
import '../core/transfer/file_transfer.dart';
import '../data/app_database.dart';
import '../data/identity_store.dart';
import '../data/models.dart';
import 'background_service.dart';
import 'beacon_wake.dart';
import 'mesh_frontend.dart';
import 'mesh_frontend_state.dart';
import 'notification_service.dart';

export 'mesh_frontend.dart' show ConversationSummary, MeshFrontend;

/// The application "brain": owns the [MeshNode], persists to [AppDatabase],
/// and exposes observable state via [MeshFrontend]. Runs in the UI isolate on
/// iOS, and in the Android foreground-service isolate (headless) where the
/// UI attaches through [RemoteMeshController] instead.
///
/// Presence / roster / inbox queries and local file actions live in the
/// shared [MeshFrontendState] / [LocalFileActions] mixins.
class MeshController extends MeshFrontend
    with MeshFrontendState, LocalFileActions, WidgetsBindingObserver {
  final Identity identity;
  @override
  String displayName;
  final AppDatabase db;
  final IdentityStore identityStore;
  final MeshNode node;

  @override
  int linkCount = 0;
  @override
  bool started = false;
  @override
  bool powerSaver = false;
  @override
  String? lastError;

  /// Status events (delivered/failed) that arrived before the message row
  /// was persisted; applied by [_persistAndCache] on insert.
  final Map<String, MsgStatus> _pendingStatus = {};
  String? _openPeer; // conversation currently on screen (suppresses unread)

  Timer? _presenceTimer;
  Timer? _bootFgRecheck;

  /// iOS background-relaunch escape hatch. After a swipe-kill, a relaunch
  /// rotates our BLE address, so every identifier the peer stored for us is
  /// instantly stale; a beacon-woken (background) app additionally can't be
  /// seen by scan at all on iOS 27 (overflow ad + broken UUID filter). Wake
  /// then reconnect is thus structurally impossible in the background — but
  /// foreground↔foreground links in seconds. So: relaunched in background and
  /// still linkless after 10s → nudge the user with a one-tap notification.
  Timer? _wakeNudgeTimer;

  /// Linkless-watchdog beacon pulse (iOS foreground torch). When we hold NO
  /// links for [_linklessPulseAfter], the wake torch may be stuck: a peer that
  /// was swipe-killed while "inside" our beacon region never re-enters while
  /// we keep transmitting, and the region rotation could be wedged. Since we
  /// have no links, briefly dropping TX costs nothing — do it to force a
  /// region EXIT+ENTER and re-light a possibly-stalled advertiser.
  DateTime? _linklessSince;
  bool _beaconPulsing = false;
  Timer? _beaconPulseTimer;

  /// Adaptive power (Android only — the 24/7 foreground-service drain). The
  /// expensive part is continuous BLE *scanning* at LOW_LATENCY; advertising
  /// and the beacon torch are cheap and others depend on them, so those stay
  /// on and only scanning is throttled. Tiers, evaluated every
  /// [_adaptiveInterval] and on every link change:
  ///   charging                      → active  + low-latency (spend freely)
  ///   battery ≤15% & unplugged      → saver   + low-power   (emergency thrift)
  ///   recent topology change (<60s) → active  + low-latency (fast (re)join)
  ///   unplugged, no links           → active  + balanced    (hunt at ½ power)
  ///   unplugged, has links (stable) → saver   + balanced    (sip)
  /// The manual "배터리 절약" toggle, when on, is a hard floor and disables
  /// this (the user asked for minimum drain explicitly).
  final Battery _battery = Battery();
  Timer? _adaptiveTimer;
  DateTime? _lastTopoChange;
  int _appliedScanCode = 2;
  bool? _appliedSaver;
  static const Duration _adaptiveInterval = Duration(seconds: 30);
  static const Duration _linklessPulseAfter = Duration(minutes: 3);
  // > iOS's ~30s region-exit debounce so a stuck peer actually EXITs.
  static const Duration _beaconPulseGap = Duration(seconds: 40);
  StreamSubscription? _sub;
  StreamSubscription? _rssiSub;
  StreamSubscription? _availabilitySub;

  /// Periodic fallback retry while the mesh hasn't started. [availabilityChanged]
  /// fires when the BLE ADAPTER powers on, but NOT when the runtime BLE
  /// PERMISSION is granted (no adapter-state change) — so a first-install user
  /// who enables Bluetooth / grants the permission after launch would sit on a
  /// stale "Bluetooth off" banner until an app restart. Re-attempting start on
  /// a slow tick recovers both cases without a restart.
  Timer? _startRetryTimer;
  bool _restarting = false;

  /// Whether the app is currently in the foreground. Incoming messages fire a
  /// local notification only when it is NOT (screen off / backgrounded).
  bool _foreground = true;

  /// Dispatches a background notification. Injectable so tests can observe it
  /// without a platform channel.
  final void Function(String conversationKey, String title, String body)
      _notify;

  /// True when running inside the Android foreground-service isolate with no
  /// UI attached (boot / swipe-kill recovery): skip widget lifecycle wiring,
  /// treat every incoming message as background (→ always notify), and never
  /// negotiate mesh ownership with ourselves.
  final bool headless;

  MeshController({
    required this.identity,
    required this.displayName,
    required this.db,
    required this.identityStore,
    MeshNode? node,
    void Function(String conversationKey, String title, String body)? notifier,
    this.headless = false,
  })  : node = node ??
            MeshNode(
              identity: identity,
              displayName: displayName,
              // Fast lanes, tried in capability order per transfer, all with
              // BLE fallback: (1) native AP-less P2P (Android Wi-Fi Direct /
              // iOS MultipeerConnectivity), (2) LAN TCP when on the same
              // Wi-Fi. Inert where unavailable → BLE carries everything.
              fastLane: CompositeFastLane([
                PlatformFastLane.instance,
                LanSocketFastLane(),
              ]),
            ),
        _notify = notifier ?? _defaultNotify;

  static void _defaultNotify(String key, String title, String body) =>
      NotificationService.showMessage(
          conversationKey: key, title: title, body: body);

  /// Why the radio is unusable (drives the home-screen banner wording).
  @override
  RadioStatus get radioStatus => node.transport.radioStatus;

  @override
  PeerId get myId => identity.peerId;

  /// Smoothed signal strength per peer: raw BLE RSSI jitters wildly, so an
  /// exponential moving average keeps the proximity UI from twitching.
  void _onRssi(RssiSample s) {
    final peer = s.peer;
    if (peer == null) return; // unattributable reading
    final hex = peer.hex;
    final old = rssiSmoothed[hex];
    rssiSmoothed[hex] =
        old == null ? s.rssi.toDouble() : old * 0.6 + s.rssi * 0.4;
    rssiSeenAt[hex] = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  /// Relay mailbox stats for the settings UI.
  @override
  int get relayStoreCount => node.store.durableCount;
  @override
  int get relayStoreBytes => node.store.durableBytes;

  /// User-initiated purge of messages we are carrying for others.
  @override
  Future<void> clearRelayStore() async {
    node.store.clearDurable();
    await db.clearRelayStore();
    notifyListeners();
  }

  Future<void> init() async {
    await _wireKnownPeersStore();
    // Incoming transfers assemble on disk in our container (not systemTemp,
    // which iOS may purge under pressure — mid-transfer that would corrupt
    // the part file).
    try {
      final docs = await getApplicationDocumentsDirectory();
      final incoming = Directory(p.join(docs.path, 'incoming'));
      if (!await incoming.exists()) {
        await incoming.create(recursive: true);
      } else {
        // Sweep .part files left by transfers that were interrupted by a
        // previous kill — no transfer is in flight yet at init, so any
        // leftover is dead. (Disk hygiene; these never leaked memory.)
        for (final f in incoming.listSync()) {
          if (f is File && f.path.endsWith('.part')) {
            try {
              f.deleteSync();
            } catch (_) {}
          }
        }
      }
      node.incomingPartPath = (tid) => p.join(incoming.path, '$tid.part');
    } catch (_) {} // node falls back to systemTemp
    // Wake-beacon TX: Android transmits always (background OK); iOS only
    // while foregrounded — re-asserted on every resume. This is what revives
    // nearby swipe-killed iPhones (they monitor this beacon's region).
    unawaited(BeaconWake.startTx());
    unawaited(_refreshBeaconStatus());
    // Detect native P2P fast-lane capabilities (Wi-Fi Direct / Multipeer).
    // Safe on every platform: no native handler → capabilities stays empty
    // and files use the LAN socket or BLE.
    await PlatformFastLane.instance.warmUp();
    bleLogSink?.call('FastLane caps: '
        '${PlatformFastLane.instance.capabilities.map((k) => k.name).toList()}');
    if (headless) {
      // No UI in this isolate: every incoming message should notify.
      _foreground = false;
    } else {
      WidgetsBinding.instance.addObserver(this);
      _foreground = WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed ||
          WidgetsBinding.instance.lifecycleState == null;
    }
    contactList
      ..clear()
      ..addAll(await db.allContacts());
    for (final c in contactList) {
      node.addContact(ContactIdentity(
        peerId: c.peerId,
        signingPublic: unb64(c.signingPublicB64),
        kexPublic: unb64(c.kexPublicB64),
        displayName: c.displayName,
        verified: c.verified,
      ));
    }
    // Transfers that were mid-flight when the app last died can never finish
    // now — fail them so no bubble is stuck on a spinner forever.
    await db.failStaleTransfers();

    // Reload the durable store-and-forward mailbox (undelivered texts we
    // carry for others survive restarts — "언젠가 전달"), then mirror every
    // change back to disk.
    final relayFrames = <Frame>[];
    for (final bytes in await db.loadRelayFrames()) {
      try {
        relayFrames.add(Frame.decode(bytes));
      } catch (_) {} // corrupt row: skip
    }
    node.store.seed(relayFrames);
    node.store.onDurableChanged = (msgIdHex, frame) {
      if (frame == null) {
        unawaited(db.deleteRelayFrame(msgIdHex));
      } else {
        unawaited(db.upsertRelayFrame(msgIdHex, frame.encode()));
      }
    };
    // Undelivered-to-me ids (seen but decrypt-failed / no-key): persist so a
    // restart before the clean copy arrives still re-requests them.
    node.seedPendingLocalDelivery(await db.loadPendingDeliveries());
    node.onPendingLocalChanged = (msgIdHex, present) {
      unawaited(present
          ? db.addPendingDelivery(msgIdHex)
          : db.removePendingDelivery(msgIdHex));
    };
    // Re-apply persisted signed receipts: tombstones for already-delivered
    // texts survive the restart (contacts above provide the signing keys).
    await node.rebuildReceipts();
    // And retry parked messages whose sender key we have since learned.
    await node.redeliverParked();
    // Seed the inbox with the last message of each known conversation.
    for (final hex in await db.conversationPeers()) {
      final last = await db.lastMessageFor(hex);
      if (last != null) lastMessages[hex] = last;
    }

    _sub = node.events.listen(_onEvent);
    _rssiSub = node.rssiSamples.listen(_onRssi);
    started = await node.start();
    // iOS scan mode follows the app's foreground state (a background
    // relaunch must use the filtered scan; a normal launch the wide one).
    // A normal launch passes through `inactive` on its way to `resumed`,
    // and that transition can complete BEFORE our lifecycle observer is
    // registered — reading it here as "background" left the scan filtered
    // (blind to iPhones) with nothing ever correcting it. Only an explicit
    // background state counts as background at boot.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    node.setForeground(lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.detached &&
        lifecycle != AppLifecycleState.hidden);
    // The optimistic default above misreads a BACKGROUND relaunch (beacon
    // wake / state restoration reports a null lifecycle at init, same as a
    // normal launch). By +3s the state has settled: a background relaunch
    // reads `paused` — flip to the filtered scan the OS requires there. A
    // foreground launch reads `resumed` and this is a no-op.
    if (!headless) {
      _bootFgRecheck = Timer(const Duration(seconds: 3), () {
        final s = WidgetsBinding.instance.lifecycleState;
        if (s == AppLifecycleState.paused ||
            s == AppLifecycleState.detached ||
            s == AppLifecycleState.hidden) {
          node.setForeground(false);
        }
      });
      if (Platform.isIOS) {
        _wakeNudgeTimer =
            Timer(const Duration(seconds: 10), _maybeWakeNudge);
      }
    }
    if (!started) {
      lastError = 'Bluetooth unavailable';
      // On a fresh install the first start fails because the OS permission
      // prompt is still on screen (or Bluetooth is simply off). Retry as soon
      // as the adapter becomes usable instead of requiring an app restart.
      _availabilitySub =
          node.transport.availabilityChanged.listen(_onTransportAvailable);
      // Event-only recovery misses the runtime-permission-granted case (no
      // adapter state change fires), leaving a stale banner until restart —
      // so also poll. Both stop the moment start() succeeds.
      _startRetryTimer = Timer.periodic(
          const Duration(seconds: 3), (_) => _onTransportAvailable(true));
    }

    // Refresh listeners periodically so "nearby" presence ages out.
    _presenceTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _maybeBeaconPulse();
      notifyListeners();
    });
    // Adaptive BLE power (Android only). Evaluate once now and on a slow tick.
    if (Platform.isAndroid) {
      unawaited(_evaluateAdaptivePower());
      _adaptiveTimer = Timer.periodic(
          _adaptiveInterval, (_) => unawaited(_evaluateAdaptivePower()));
    }
    notifyListeners();
  }

  /// See [_battery]. Android-only; a no-op when the manual saver toggle is on.
  Future<void> _evaluateAdaptivePower() async {
    if (!Platform.isAndroid || powerSaver) return;
    try {
      final state = await _battery.batteryState;
      final charging = state == BatteryState.charging ||
          state == BatteryState.full;
      final level = charging ? 100 : await _battery.batteryLevel;
      final recentChange = _lastTopoChange != null &&
          DateTime.now().difference(_lastTopoChange!) < const Duration(seconds: 60);

      final bool saver;
      final int scanCode; // 0=low-power, 1=balanced, 2=low-latency
      if (charging) {
        saver = false;
        scanCode = 2;
      } else if (level <= 15) {
        saver = true;
        scanCode = 0;
      } else if (recentChange) {
        saver = false;
        scanCode = 2;
      } else if (linkCount == 0) {
        saver = false;
        scanCode = 1;
      } else {
        saver = true;
        scanCode = 1;
      }

      final changed = saver != _appliedSaver || scanCode != _appliedScanCode;
      if (saver != _appliedSaver) {
        _appliedSaver = saver;
        node.setPowerSaver(saver); // drives transport only, not the UI flag
      }
      if (scanCode != _appliedScanCode) {
        _appliedScanCode = scanCode;
        await node.setScanMode(scanCode);
      }
      if (changed) {
        final line = 'adaptive power: charging=$charging level=$level '
            'links=$linkCount -> ${saver ? 'saver' : 'active'}+'
            '${const {0: 'low-power', 1: 'balanced', 2: 'low-latency'}[scanCode]}';
        bleLogSink?.call('${DateTime.now().toIso8601String()} $line');
        debugPrint('SpotLink $line'); // surfaces in logcat for field diag
      }
    } catch (_) {} // battery plugin unavailable / transient — keep last tier
  }

  /// See [_wakeNudgeTimer]. Fires once, 10s after boot: a BACKGROUND relaunch
  /// (beacon wake / BLE restoration) that is still linkless can never join
  /// silently — nudge with a tappable notification instead. A normal
  /// foreground launch, or a wake whose fresh identifiers connected within
  /// 10s, is a no-op. Cooldown persisted to disk: region-rotation wakes
  /// repeat every ~36s, and each is a fresh process.
  Future<void> _maybeWakeNudge() async {
    final s = WidgetsBinding.instance.lifecycleState;
    final background = s == AppLifecycleState.paused ||
        s == AppLifecycleState.detached ||
        s == AppLifecycleState.hidden;
    if (!background || !started || linkCount > 0) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stamp = File(p.join(dir.path, 'wake_nudge_at'));
      final now = DateTime.now().millisecondsSinceEpoch;
      if (stamp.existsSync()) {
        final last = int.tryParse(stamp.readAsStringSync().trim()) ?? 0;
        if (now - last < 15 * 60 * 1000) return;
      }
      stamp.writeAsStringSync('$now');
    } catch (_) {
      return; // no persisted cooldown → don't risk a notification storm
    }
    bleLogSink?.call('${DateTime.now().toIso8601String()} wake nudge shown '
        '(background relaunch, linkless 10s)');
    await NotificationService.showMessage(
      conversationKey: 'wake-nudge',
      title: '주변에 SpotLink 친구가 있어요',
      body: '탭해서 열면 바로 연결됩니다.',
    );
  }

  /// See [_linklessSince]. iOS foreground only: pulse the wake torch when we
  /// have held no links for [_linklessPulseAfter], to rescue a peer stuck
  /// inside our beacon region and unwedge a stalled advertiser. Free of
  /// downside precisely because we have no links to disrupt.
  void _maybeBeaconPulse() {
    if (!Platform.isIOS || headless || !_foreground || _beaconPulsing) return;
    final since = _linklessSince;
    if (since == null || linkCount > 0) return;
    if (DateTime.now().difference(since) < _linklessPulseAfter) return;
    _beaconPulsing = true;
    bleLogSink?.call('${DateTime.now().toIso8601String()} '
        'beacon wake pulse (linkless ${_linklessPulseAfter.inMinutes}m)');
    unawaited(BeaconWake.stopTx().then((_) {
      _beaconPulseTimer?.cancel();
      _beaconPulseTimer = Timer(_beaconPulseGap, () {
        unawaited(BeaconWake.startTx());
        // Restart the linkless clock so we don't machine-gun pulses.
        _linklessSince = linkCount == 0 ? DateTime.now() : null;
        _beaconPulsing = false;
      });
    }));
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
        _startRetryTimer?.cancel();
        _startRetryTimer = null;
        // iOS/macOS scan mode follows the app's current foreground state.
        node.setForeground(_foreground);
        if (Platform.isAndroid) unawaited(_evaluateAdaptivePower());
        notifyListeners();
      }
    } finally {
      _restarting = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !wasForeground) {
      // Returning to the foreground after iOS suspended us: immediately
      // re-announce presence and re-kick discovery so we (and peers) recover
      // online-status without waiting for the next 15s cycle.
      node.setForeground(true); // wide scan first, then the wake re-kick
      if (started) unawaited(node.wakeUp());
      // iOS kills beacon TX in the background — re-light the torch.
      unawaited(BeaconWake.startTx());
      // Re-read the location grant: the user may have just flipped it to
      // "Always" in Settings, and without this the "needs Always" banner
      // lingers until an app restart (it's only checked at boot otherwise).
      unawaited(_refreshBeaconStatus());
      unawaited(NotificationService.cancelFor('wake-nudge'));
      if (_openPeer != null) NotificationService.cancelFor(_openPeer!);
    } else if (state == AppLifecycleState.paused) {
      node.setForeground(false); // back to the OS-required filtered scan
      // Heading to the background = jetsam candidacy. Shed everything
      // rebuildable NOW so our suspended footprint is as small as possible.
      _trimMemory();
    }
  }

  @override
  void didHaveMemoryPressure() => _trimMemory();

  /// Drop rebuildable state: decoded images and cached conversations (they
  /// reload from SQLite on open). Keeps the open conversation so the visible
  /// chat doesn't blank out.
  void _trimMemory() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    conversationCache.removeWhere((hex, _) => hex != _openPeer);
  }

  /// Fire a local notification for an incoming message when the app isn't in
  /// the foreground (screen off / backgrounded). Suppressed for the chat the
  /// user currently has open.
  void _notifyIncoming(PeerId from, String body) {
    // Only when the app is not in the foreground (screen off / backgrounded).
    if (_foreground) return;
    final name = contactByHex(from.hex)?.displayName ?? from.short;
    _notify(from.hex, name, body);
  }

  /// Test hook: drive the app-foreground flag without a real lifecycle event.
  @visibleForTesting
  void setForegroundForTest(bool value) => _foreground = value;

  // ---- cross-isolate bridge hooks (headless mode; see MeshHost) ----

  /// Monotonic revision of the messages table. The remote UI reloads its open
  /// conversation from the (shared) DB whenever this changes — cheaper and
  /// simpler than serializing message lists over the isolate port.
  int msgRev = 0;

  void _bumpRev() => msgRev++;

  /// The remote UI's app-lifecycle state, mirrored over the bridge so the
  /// headless brain routes notifications exactly like a local one would
  /// (suppressed while the user is looking at the app).
  void setRemoteForeground(bool foreground) {
    final wasForeground = _foreground;
    _foreground = foreground;
    if (foreground && !wasForeground) {
      // Same re-kick a local controller does on resume: re-assert
      // advertising and restart discovery so presence recovers immediately
      // instead of waiting for the next self-heal/duty cycle.
      if (started) {
        unawaited(node.wakeUp());
      } else {
        // Mesh never came up (e.g. BLE permission was missing at boot, so
        // ensureReady failed). The UI just came to the foreground and may
        // have granted it — re-attempt now instead of waiting on an adapter
        // event that a permission grant doesn't always emit.
        unawaited(_onTransportAvailable(true));
      }
      if (_openPeer != null) NotificationService.cancelFor(_openPeer!);
    }
  }

  /// Serializable state snapshot for the cross-isolate UI mirror. Everything
  /// here is JSON-safe (numbers/strings/bools/maps/lists only).
  Map<String, Object?> snapshotForRemote() => {
        'started': started,
        'links': linkCount,
        'err': lastError,
        'radio': radioStatus.index,
        'saver': powerSaver,
        'relayN': relayStoreCount,
        'relayB': relayStoreBytes,
        'name': displayName,
        'rev': msgRev,
        'contacts': [for (final c in contactList) c.toMap()],
        'seen': lastSeenAt,
        'hops': lastHopCount,
        'rssi': {
          for (final e in rssiSmoothed.entries)
            e.key: [e.value, rssiSeenAt[e.key] ?? 0],
        },
        'unread': unreadCounts,
        'last': {
          for (final e in lastMessages.entries) e.key: e.value.toMap(),
        },
        'prog': transferProgress,
      };

  Future<ChatMessage?> _messageIn(String peerHex, String msgId) async {
    for (final m in await db.messagesFor(peerHex)) {
      if (m.msgId == msgId) return m;
    }
    return null;
  }

  /// Id-based command variants for the bridge: the remote UI holds plain
  /// ChatMessage copies, so commands cross the port as (peerHex, msgId) and
  /// are re-anchored to the authoritative DB row here.
  Future<void> retryTextById(String peerHex, String msgId) async {
    final m = await _messageIn(peerHex, msgId);
    if (m != null) await retryText(m);
  }

  Future<void> retryFileById(String peerHex, String msgId) async {
    final m = await _messageIn(peerHex, msgId);
    if (m != null) await retryFile(m);
  }

  Future<void> deleteMessageById(String peerHex, String msgId) async {
    final m = await _messageIn(peerHex, msgId);
    if (m != null) await deleteMessage(m);
  }

  Future<void> cancelFileById(String msgId) async {
    node.cancelSend(msgId);
    transferProgress.remove(msgId);
    await _applyStatus(msgId, MsgStatus.failed);
  }

  Future<void> _onEvent(NodeEvent e) async {
    switch (e) {
      case LinksChanged(:final count):
        linkCount = count;
        _linklessSince = count == 0 ? (_linklessSince ?? DateTime.now()) : null;
        // A topology change earns a brief low-latency burst for fast (re)join.
        _lastTopoChange = DateTime.now();
        if (Platform.isAndroid) unawaited(_evaluateAdaptivePower());
        BackgroundService.updateStatus(count);
        notifyListeners();
      case PeerAnnounced(:final contact, :final hops):
        lastSeenAt[contact.peerId.hex] =
            DateTime.now().millisecondsSinceEpoch;
        lastHopCount[contact.peerId.hex] = hops;
        await _rememberAnnounced(contact);
        notifyListeners();
      case TextReceived(:final from, :final text, :final msgId, :final sentAt):
        await _onText(from, text, msgId, sentAt: sentAt);
      case DeliveryConfirmed(:final msgId):
        await _applyStatus(msgId, MsgStatus.delivered);
      case TextDeliveryFailed(:final msgId):
        // Live retries are exhausted but the text stays parked in the durable
        // relay store — show "전달 대기", not a scary failure. A late ACK
        // arrives as DeliveryConfirmed and flips it to delivered.
        await _applyStatus(msgId, MsgStatus.queued);
      case FileOffered(:final from, :final meta):
        await _onFileOffered(from, meta);
      case FileProgress(:final transferId, :final progress):
        transferProgress[transferId] = progress;
        notifyListeners();
      case FileReceived(:final from, :final meta, :final path):
        await _onFileReceived(from, meta, path);
      case FileFailed(:final transferIdHex):
        transferProgress.remove(transferIdHex);
        await _applyStatus(transferIdHex, MsgStatus.failed);
      case NodeError(:final message):
        lastError = message;
        reportError(message);
        notifyListeners();
    }
  }

  /// Apply a delivery-status change to a message. A tiny transfer can be
  /// acknowledged before the outgoing bubble is even persisted — remember the
  /// status and let [_persistAndCache] apply it on insert.
  Future<void> _applyStatus(String msgId, MsgStatus status) async {
    final updated = await db.updateStatusByMsgId(msgId, status);
    if (updated == 0) _pendingStatus[msgId] = status;
    _patchStatus(msgId, status);
    _bumpRev();
    notifyListeners();
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
      replaceContact(contact);
    } else {
      // Keep a verified or user-renamed name; otherwise adopt the announced
      // name. Without the nameLocked guard the peer's next ANNOUNCE (every
      // ~15s) silently reverted a user rename of an unverified contact.
      if (!existing.verified &&
          !existing.nameLocked &&
          c.displayName != null &&
          c.displayName!.isNotEmpty &&
          c.displayName != existing.displayName) {
        final updated = existing.copyWith(displayName: c.displayName, lastSeen: now);
        await db.upsertContact(updated);
        replaceContact(updated);
      } else {
        await db.touchContact(c.peerId.hex, now);
      }
    }
  }

  @override
  Future<Contact> addContactFromBundle(Uint8List bundle,
      {String? name, bool verified = true}) async {
    final c = ContactIdentity.fromBundle(bundle, displayName: name);
    node.addContact(c);
    final existing = await db.contact(c.peerId.hex);
    // A user-renamed contact keeps its name across a QR re-scan.
    final nameLocked = existing?.nameLocked ?? false;
    final contact = Contact(
      peerHex: c.peerId.hex,
      signingPublicB64: b64(c.signingPublic),
      kexPublicB64: b64(c.kexPublic),
      displayName: nameLocked
          ? existing!.displayName
          : name ?? existing?.displayName ?? c.peerId.short,
      verified: verified,
      nameLocked: nameLocked,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
    );
    await db.upsertContact(contact);
    replaceContact(contact);
    notifyListeners();
    return contact;
  }

  /// Delete a contact: keys, conversation history and any received/sent file
  /// copies. Not a block — a nearby peer re-appears on their next ANNOUNCE
  /// (as a fresh, unverified contact).
  @override
  Future<void> deleteContact(String peerHex) async {
    // Best-effort cleanup of files referenced by this conversation.
    for (final m in await db.messagesFor(peerHex)) {
      final path = m.filePath;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      transferProgress.remove(m.msgId);
    }
    await db.deleteMessagesFor(peerHex);
    await db.deleteContact(peerHex);
    contactList.removeWhere((c) => c.peerHex == peerHex);
    conversationCache.remove(peerHex);
    lastMessages.remove(peerHex);
    unreadCounts.remove(peerHex);
    lastSeenAt.remove(peerHex);
    lastHopCount.remove(peerHex);
    rssiSmoothed.remove(peerHex);
    rssiSeenAt.remove(peerHex);
    if (_openPeer == peerHex) _openPeer = null;
    node.removeContact(PeerId.fromHex(peerHex));
    _bumpRev();
    notifyListeners();
  }

  @override
  Future<void> renameContact(String peerHex, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final existing = contactByHex(peerHex);
    if (existing == null) return;
    // nameLocked pins the user's choice against announce updates.
    final updated = existing.copyWith(displayName: trimmed, nameLocked: true);
    await db.upsertContact(updated);
    replaceContact(updated);
    notifyListeners();
  }

  // ---- identity ----

  @override
  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    displayName = trimmed;
    await identityStore.setDisplayName(trimmed);
    await node.updateDisplayName(trimmed);
    notifyListeners();
  }

  @override
  void setPowerSaver(bool saver) {
    powerSaver = saver;
    node.setPowerSaver(saver);
    if (saver) {
      // Manual saver is a hard floor: also drop to the cheapest scan and let
      // adaptive control stand down.
      _appliedSaver = true;
      _appliedScanCode = 0;
      unawaited(node.setScanMode(0));
    } else {
      // Hand back to adaptive control (re-derives the right tier now).
      _appliedSaver = null;
      unawaited(_evaluateAdaptivePower());
    }
    notifyListeners();
  }

  // ---- QR payload (format lives in QrPayload) ----

  @override
  String get myQrPayload => QrPayload.encode(identity.publicBundle, displayName);

  static (Uint8List, String)? parseQr(String payload) =>
      QrPayload.decode(payload);

  // ---- messaging ----

  @override
  Future<void> openConversation(String peerHex) async {
    _openPeer = peerHex;
    unreadCounts.remove(peerHex);
    NotificationService.cancelFor(peerHex);
    if (!conversationCache.containsKey(peerHex)) {
      // Install a placeholder list *before* the await so messages that arrive
      // during the DB load (via _persistAndCache) are captured, then merge them
      // with the DB snapshot without duplicating.
      final live = <ChatMessage>[];
      conversationCache[peerHex] = live;
      final loaded = await db.messagesFor(peerHex, limit: 200);
      final loadedIds = loaded.map((m) => m.id).whereType<int>().toSet();
      final extras =
          live.where((m) => m.id == null || !loadedIds.contains(m.id));
      final merged = [...loaded, ...extras]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      conversationCache[peerHex] = merged;
    }
    notifyListeners();
  }

  @override
  void closeConversation() {
    _openPeer = null;
  }

  @override
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

  @override
  Future<void> retryText(ChatMessage failed) async {
    if (failed.text == null) return;
    final peer = PeerId.fromHex(failed.peerHex);
    // Cancel the old attempt so a late store-and-forward copy of it can't
    // double-deliver alongside this fresh send (new msgId). Keep the ORIGINAL
    // compose time in the envelope — a resend is not a new message, and the
    // receiver's "HH:mm 전송" must reflect when it was written.
    node.forgetText(failed.msgId);
    final msgId = await node.sendText(peer, failed.text!,
        sentAt: DateTime.fromMillisecondsSinceEpoch(failed.timestamp));
    if (msgId == null) {
      reportError('Still unable to send — no route yet');
      return;
    }
    if (failed.id != null) {
      await db.updateMessageDelivery(failed.id!, msgId, MsgStatus.sent);
    }
    _patchMessage(failed.peerHex, failed.msgId,
        newMsgId: msgId, status: MsgStatus.sent);
    _bumpRev();
    notifyListeners();
  }

  @override
  Future<void> sendFile(String peerHex,
      {required Uint8List bytes,
      required String name,
      required String mime}) async {
    // Land the bytes on disk once, then send disk-backed so the transfer
    // never pins the payload in RAM. (Callers with a real path should use
    // [sendFilePath] and skip the byte round-trip entirely.)
    final path = await _saveLocalCopy(
        'out-${DateTime.now().millisecondsSinceEpoch}', name, bytes);
    if (path == null) {
      reportError('파일을 저장할 수 없어 보낼 수 없습니다');
      return;
    }
    await sendFilePath(peerHex, path: path, name: name, mime: mime);
  }

  @override
  Future<void> sendFilePath(String peerHex,
      {required String path,
      required String name,
      required String mime}) async {
    final peer = PeerId.fromHex(peerHex);
    final now = DateTime.now().millisecondsSinceEpoch;
    // Picker/outbox paths live in OS-cleanable caches — keep a durable copy
    // (native File.copy: streamed, no RAM cost) and send from that, so the
    // bubble stays openable and a failed transfer stays retryable. Skip when
    // the source is already our own sent/ copy (the sendFile byte path).
    if (!path.contains('${Platform.pathSeparator}sent${Platform.pathSeparator}')) {
      final copy = await _copyToSent(now.toString(), name, path);
      if (copy != null) path = copy;
    }
    final size = await File(path).length();
    // Returns as soon as the META frame is out; the chunks stream in the
    // background and report back via FileProgress / DeliveryConfirmed /
    // FileFailed events. The bubble must appear immediately.
    final tid =
        await node.sendFilePath(peer, path: path, name: name, mime: mime);
    final msgId = tid ?? 'local-$now';
    final msg = ChatMessage(
      peerHex: peerHex,
      msgId: msgId,
      direction: MsgDirection.outgoing,
      kind: MsgKind.file,
      fileName: name,
      filePath: path,
      fileSize: size,
      status: tid == null ? MsgStatus.failed : MsgStatus.sending,
      timestamp: now,
    );
    await _persistAndCache(msg);
  }

  /// Destination path for a durable copy under sent/, or null when the
  /// folder can't be prepared. The copy is best-effort everywhere: a null
  /// simply means "send without a local copy".
  Future<String?> _sentPathFor(String tid, String name) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(dir.path, 'sent'));
      if (!await folder.exists()) await folder.create(recursive: true);
      final safeName = name.replaceAll(RegExp(r'[/\\]'), '_');
      return p.join(folder.path, '${tid}_$safeName');
    } catch (_) {
      return null;
    }
  }

  Future<String?> _saveLocalCopy(
      String tid, String name, Uint8List bytes) async {
    final path = await _sentPathFor(tid, name);
    if (path == null) return null;
    try {
      await File(path).writeAsBytes(bytes);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Like [_saveLocalCopy] but from an existing file — native copy, no RAM.
  Future<String?> _copyToSent(String tid, String name, String srcPath) async {
    final path = await _sentPathFor(tid, name);
    if (path == null) return null;
    try {
      await File(srcPath).copy(path);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Cancel an in-progress outgoing transfer (stops the chunk stream).
  @override
  Future<void> cancelFile(ChatMessage msg) async {
    node.cancelSend(msg.msgId);
    transferProgress.remove(msg.msgId);
    await _applyStatus(msg.msgId, MsgStatus.failed);
  }

  /// Re-send a failed file transfer from the local copy saved at send time.
  @override
  Future<void> retryFile(ChatMessage failed) async {
    final path = failed.filePath;
    if (path == null || !await File(path).exists()) {
      reportError('원본 파일이 없어 다시 보낼 수 없습니다');
      return;
    }
    final name = failed.fileName ?? p.basename(path);
    final tid = await node.sendFilePath(
      PeerId.fromHex(failed.peerHex),
      path: path,
      name: name,
      mime: lookupMimeType(name) ?? 'application/octet-stream',
    );
    if (tid == null) {
      reportError('Still unable to send — no route yet');
      return;
    }
    if (failed.id != null) {
      await db.updateMessageDelivery(failed.id!, tid, MsgStatus.sending);
    }
    _patchMessage(failed.peerHex, failed.msgId,
        newMsgId: tid, status: MsgStatus.sending);
    _bumpRev();
    notifyListeners();
  }

  Future<void> _onText(PeerId from, String text, String msgId,
      {DateTime? sentAt}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      peerHex: from.hex,
      msgId: msgId,
      direction: MsgDirection.incoming,
      kind: MsgKind.text,
      text: text,
      status: MsgStatus.received,
      timestamp: now, // arrival time (this device's clock)
      sentTs: sentAt?.millisecondsSinceEpoch,
    );
    await _persistAndCache(msg, incoming: true);
    _notifyIncoming(from, text);
  }

  /// An incoming transfer just started (META received): show a progress
  /// bubble right away instead of staying silent until the file completes.
  Future<void> _onFileOffered(PeerId from, FileMeta meta) async {
    final msg = ChatMessage(
      peerHex: from.hex,
      msgId: meta.transferIdHex,
      direction: MsgDirection.incoming,
      kind: MsgKind.file,
      fileName: meta.name,
      fileSize: meta.fileSize,
      status: MsgStatus.receiving,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistAndCache(msg, incoming: true);
  }

  Future<void> _onFileReceived(
      PeerId from, FileMeta meta, String partPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(dir.path, 'received'));
    if (!await folder.exists()) await folder.create(recursive: true);
    final safeName = meta.name.replaceAll(RegExp(r'[/\\]'), '_');
    final path = p.join(folder.path, '${meta.transferIdHex}_$safeName');
    // The verified payload is already on disk (the receiver's part file) —
    // move it into place instead of writing bytes (rename on the same
    // volume; falls back to a native copy across volumes).
    try {
      await File(partPath).rename(path);
    } on FileSystemException {
      await File(partPath).copy(path);
      try {
        await File(partPath).delete();
      } catch (_) {}
    }

    transferProgress.remove(meta.transferIdHex);
    _notifyIncoming(from, '📎 ${meta.name}');

    // Normally the "receiving" placeholder from _onFileOffered exists —
    // complete it in place.
    final updated = await db.updateFileByMsgId(
        meta.transferIdHex, path, MsgStatus.received);
    if (updated > 0) {
      _patchFile(meta.transferIdHex, path, MsgStatus.received);
      _bumpRev();
      notifyListeners();
      return;
    }

    // No placeholder (edge case) — insert the complete message directly.
    final msg = ChatMessage(
      peerHex: from.hex,
      msgId: meta.transferIdHex,
      direction: MsgDirection.incoming,
      kind: MsgKind.file,
      fileName: meta.name,
      filePath: path,
      fileSize: meta.fileSize,
      status: MsgStatus.received,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistAndCache(msg, incoming: true);
  }

  Future<void> _persistAndCache(ChatMessage msg, {bool incoming = false}) async {
    // A status event (e.g. the completion ACK of a tiny file) may have raced
    // ahead of this insert — apply it now instead of losing it.
    final pending = _pendingStatus.remove(msg.msgId);
    if (pending != null) msg = msg.copyWith(status: pending);
    final id = await db.insertMessage(msg);
    final stored = msg.withId(id);
    conversationCache[msg.peerHex]?.add(stored);
    lastMessages[msg.peerHex] = stored;
    if (incoming && msg.peerHex != _openPeer) {
      unreadCounts[msg.peerHex] = (unreadCounts[msg.peerHex] ?? 0) + 1;
    }
    _bumpRev();
    notifyListeners();
  }

  // ---- wake beacon (iOS 재기동 트리거) ----

  /// True when iOS beacon-region monitoring is on (always-location granted
  /// and the user enabled the toggle). Meaningless on Android.
  @override
  bool beaconMonitoring = false;

  @override
  bool beaconNeedsAlways = false;

  Future<void> _refreshBeaconStatus() async {
    final s = await BeaconWake.status();
    beaconMonitoring = s['monitoring'] == true;
    // Surface a degraded grant to the UI: monitoring is on but iOS only gave
    // us "While Using", so nothing wakes us in the background. We still fire
    // the upgrade prompt below, but once the user has declined it iOS ignores
    // the call — the banner + Settings shortcut is then the only way out.
    beaconNeedsAlways =
        Platform.isIOS && beaconMonitoring && s['auth'] != 'always';
    // Monitoring defaults to ON (see BeaconPlugin.swift) but only works with
    // the "always" location grant — ask once on the first run.
    // Beacon-wake RX (relaunching a terminated app on region entry) requires
    // authorizedAlways. iOS often grants only When-In-Use on the first prompt
    // — monitoring is then useless in the background, and the old code never
    // asked again. Re-requesting from whenInUse shows the one-time "Change to
    // Always Allow?" upgrade prompt; if the user declines, iOS ignores
    // further calls, so this stays harmless to repeat.
    if (Platform.isIOS &&
        beaconMonitoring &&
        (s['auth'] == 'notDetermined' || s['auth'] == 'whenInUse')) {
      await BeaconWake.requestAlways();
    }
    notifyListeners();
  }

  /// Me-tab toggle: opt in/out of the "wake me via beacon" behaviour.
  @override
  Future<void> setBeaconMonitoring(bool on) async {
    if (on) {
      await BeaconWake.requestAlways(); // one-time permission prompt
      await BeaconWake.enableMonitoring();
    } else {
      await BeaconWake.disableMonitoring();
    }
    await _refreshBeaconStatus();
  }

  /// Known-peer peripheral identifiers live in a tiny JSON file so a fresh
  /// launch (or an iOS state-restoration relaunch) can re-arm pending
  /// connects to every friend without scanning.
  Future<void> _wireKnownPeersStore() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'known_peers.json'));
      knownPeersLoad = () async {
        try {
          if (!file.existsSync()) return const <String>[];
          return (jsonDecode(await file.readAsString()) as List)
              .cast<String>();
        } catch (_) {
          return const <String>[];
        }
      };
      knownPeersSave = (uuids) {
        try {
          file.writeAsStringSync(jsonEncode(uuids));
        } catch (_) {}
      };
    } catch (_) {} // diagnostics-grade persistence — never block startup
  }

  // ---- files (openFile / saveToGallery / shareFile: see LocalFileActions) --

  /// Delete one message bubble on this device (DB + memory), removing the
  /// stored file from disk for file messages. Purely local — the peer's copy
  /// is untouched.
  @override
  Future<void> deleteMessage(ChatMessage msg) async {
    await db.deleteMessage(msg.msgId);
    final path = msg.filePath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {} // already gone — fine
    }
    conversationCache[msg.peerHex]?.removeWhere((m) => m.msgId == msg.msgId);
    if (lastMessages[msg.peerHex]?.msgId == msg.msgId) {
      final rest = conversationCache[msg.peerHex];
      if (rest != null && rest.isNotEmpty) {
        lastMessages[msg.peerHex] = rest.last;
      } else {
        lastMessages.remove(msg.peerHex);
      }
    }
    _bumpRev();
    notifyListeners();
  }

  // ---- helpers ----

  /// Like [_patchStatus] but also attaches the saved file path (an incoming
  /// transfer completing in place).
  void _patchFile(String msgId, String filePath, MsgStatus status) {
    for (final list in conversationCache.values) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].msgId == msgId) {
          list[i] = list[i].copyWith(filePath: filePath, status: status);
        }
      }
    }
    for (final entry in lastMessages.entries.toList()) {
      if (entry.value.msgId == msgId) {
        lastMessages[entry.key] =
            entry.value.copyWith(filePath: filePath, status: status);
      }
    }
  }

  void _patchStatus(String msgId, MsgStatus status) {
    for (final list in conversationCache.values) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].msgId == msgId) {
          list[i] = list[i].copyWith(status: status);
        }
      }
    }
    for (final entry in lastMessages.entries.toList()) {
      if (entry.value.msgId == msgId) {
        lastMessages[entry.key] = entry.value.copyWith(status: status);
      }
    }
  }

  void _patchMessage(String peerHex, String oldMsgId,
      {required String newMsgId, required MsgStatus status}) {
    final list = conversationCache[peerHex];
    if (list != null) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].msgId == oldMsgId) {
          list[i] = list[i].copyWith(msgId: newMsgId, status: status);
        }
      }
    }
    // Keep the inbox summary in sync (it reads lastMessages), otherwise the
    // row stays stuck on the old failed msgId forever.
    final last = lastMessages[peerHex];
    if (last != null && last.msgId == oldMsgId) {
      lastMessages[peerHex] = last.copyWith(msgId: newMsgId, status: status);
    }
  }

  @override
  void dispose() {
    if (!headless) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _presenceTimer?.cancel();
    _bootFgRecheck?.cancel();
    _wakeNudgeTimer?.cancel();
    _beaconPulseTimer?.cancel();
    _startRetryTimer?.cancel();
    _adaptiveTimer?.cancel();
    _sub?.cancel();
    _rssiSub?.cancel();
    _availabilitySub?.cancel();
    node.dispose();
    super.dispose(); // MeshFrontendState closes the error stream
  }
}
