import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart' show MethodChannel;

import '../model/peer_id.dart';
import 'ble_constants.dart';
import 'framing.dart';

/// BLE diagnostics logging: always on in debug builds; enable in release with
/// `flutter build ios --release --dart-define=BLE_LOG=true`.
const bool _logBle = kDebugMode || bool.fromEnvironment('BLE_LOG');

/// Diagnostic: scan UNFILTERED on iOS too (foreground-only builds). Splits
/// "scanner is dead" (sees nothing at all) from "peer's advertisement lacks
/// our UUID" (sees the world, not the peer). Never ship enabled — iOS
/// background scanning requires the service-UUID filter.
const bool _diagUnfilteredScan = bool.fromEnvironment('DIAG_UNFILTERED');

/// Optional extra sink for BLE diagnostics (e.g. a file logger wired up by the
/// app layer). Release builds drop console output on iOS, so this is the only
/// way to diagnose BLE behaviour on a real device without a debugger.
void Function(String line)? bleLogSink;

/// Persistence for known-peer peripheral identifiers, wired by the app layer
/// (a small JSON file). Lets a fresh launch — including an iOS
/// state-restoration relaunch — re-arm pending connects to known peers
/// without scanning.
Future<List<String>> Function()? knownPeersLoad;
void Function(List<String> uuids)? knownPeersSave;

void _log(String msg) {
  if (_logBle) debugPrint(msg);
  bleLogSink?.call(msg);
}

/// Whether this node acts as GATT central or peripheral on a given link.
enum LinkRole { central, peripheral }

/// A logical, bidirectional link to one neighbour over a single BLE connection.
class MeshLink {
  final String id;
  final LinkRole role;

  /// Short id learned from the advertisement (central role) or ANNOUNCE.
  PeerId? remoteShortId;

  /// Last time a packet arrived on this link. Peripheral-role links get no
  /// reliable disconnect callback on every stack — a link silent past the
  /// ANNOUNCE heartbeat for minutes is a zombie and gets dropped.
  DateTime lastActivity = DateTime.now();

  int maxPacketSize;
  final L2Reassembler reassembler = L2Reassembler();

  // Central-role handles (we connected to a remote peripheral).
  final Peripheral? peripheral;
  final GATTCharacteristic? remoteTx; // we write here
  final GATTCharacteristic? remoteRx; // we get notified here

  // Peripheral-role handle (a remote central connected to us).
  final Central? central;
  bool centralSubscribed = false;

  // Packets written since the last with-response flush (central role only).
  int txBurst = 0;

  MeshLink({
    required this.id,
    required this.role,
    this.maxPacketSize = BleConstants.defaultMaxPacketSize,
    this.peripheral,
    this.remoteTx,
    this.remoteRx,
    this.central,
  });

  @override
  String toString() => 'MeshLink($id ${role.name} mtu=$maxPacketSize '
      '${remoteShortId?.short ?? "?"})';
}

/// A packet reassembled from a link, ready to be parsed into a [Frame].
class InboundPacket {
  final MeshLink link;
  final Uint8List frameBytes;
  InboundPacket(this.link, this.frameBytes);
}

/// A link coming up or going down.
class LinkEvent {
  final MeshLink link;
  final bool up;
  LinkEvent(this.link, this.up);
}

/// A signal-strength reading for a direct neighbour, from an advertisement
/// or a connected-link RSSI poll. [peer] is null when the radio couldn't
/// tell who it was (e.g. an iOS advertisement carries no id).
class RssiSample {
  final PeerId? peer;
  final int rssi; // dBm, typically -30 (바로 옆) … -100 (수신 한계)
  RssiSample(this.peer, this.rssi);
}

/// The packet-oriented transport contract the [MeshNode] depends on. The real
/// implementation is [MeshTransport]; tests inject an in-memory fake.
/// Coarse adapter status, for user-facing diagnostics ("Bluetooth is off"
/// vs "permission missing" need different fixes by the user).
enum RadioStatus { ready, poweredOff, unauthorized, unknown }

abstract class MeshTransportInterface {
  Stream<InboundPacket> get inbound;
  Stream<LinkEvent> get linkEvents;
  int get linkCount;

  /// Why the radio is (un)usable right now.
  RadioStatus get radioStatus;

  /// Emits true when the radio becomes usable (permission granted / adapter
  /// powered on) and false when it stops being usable. Must be listenable
  /// before [start], so a failed first start can be retried.
  Stream<bool> get availabilityChanged;

  /// Signal-strength readings for direct neighbours (드러난 거리감의 원천).
  Stream<RssiSample> get rssiSamples;

  Future<bool> ensureReady();
  Future<void> start();
  Future<void> stop();

  /// Nudge the radio back to active discovery/advertising (e.g. the app just
  /// returned to the foreground). No-op if already running.
  void wake();

  Future<void> broadcast(Uint8List frameBytes, {String? exceptLinkId});
  Future<void> sendToLink(String linkId, Uint8List frameBytes);
}

/// Bridges the BLE central & peripheral managers into a single mesh transport:
/// discovers neighbours, manages one link per neighbour (role decided by id
/// comparison), and exposes a packet-oriented send/receive API.
///
/// The higher-level [MeshNode] sits on top and never touches BLE directly.
/// Power profile trading battery for responsiveness. See docs/ARCHITECTURE.md
/// §12.
enum PowerMode {
  /// Continuous scanning + advertising. Best reachability, highest drain.
  active,

  /// Duty-cycled scanning (scan for [_saverScanOn], idle for [_saverScanOff]).
  saver,
}

class MeshTransport implements MeshTransportInterface {
  final PeerId myShortId;

  /// The full public bundle to expose via the INFO characteristic.
  final Uint8List infoValue;

  /// Cap on concurrent links to bound battery/memory. Extra peers are ignored
  /// until a slot frees up.
  final int maxLinks;

  PowerMode _powerMode = PowerMode.active;
  Timer? _dutyTimer;
  bool _scanning = false;

  /// Android: scanning and connecting share one radio, and issuing
  /// connectGatt WHILE a (LOW_LATENCY) scan runs is the classic cause of
  /// `status 133` connect failures on Samsung — in a BLE-dense room every
  /// dial failed and the mesh never linked. We pause the scan for the
  /// duration of each connect handshake. [_connectDepth] refcounts concurrent
  /// connects; [_scanPausedForConnect] makes [_startScanning] a no-op so the
  /// self-heal / duty-cycle timers can't restart the scan mid-connect.
  int _connectDepth = 0;
  bool _scanPausedForConnect = false;

  static const Duration _saverScanOn = Duration(seconds: 6);
  static const Duration _saverScanOff = Duration(seconds: 20);

  /// iOS foreground scan-mode alternation. The unfiltered scan is the only
  /// mode that finds a FOREGROUND iPhone on iOS 27 (see [_startScanning]),
  /// but it cannot see a BACKGROUND iPhone at all — overflow-area
  /// advertisements are only delivered to a scan filtered on the service
  /// UUID. Neither mode covers both, so alternate: wide window for
  /// foreground peers/Androids, short filtered window for backgrounded
  /// iPhones (whose rotated address makes any standing pending-reconnect
  /// stale after a relaunch — a fresh discovery is the only way back in).
  Timer? _scanModeTimer;
  bool _overflowPhase = false;
  static const Duration _wideScanWindow = Duration(seconds: 12);
  static const Duration _overflowScanWindow = Duration(seconds: 6);

  final CentralManager _central = CentralManager();
  final PeripheralManager _peripheral = PeripheralManager();

  final _inbound = StreamController<InboundPacket>.broadcast();
  final _linkEvents = StreamController<LinkEvent>.broadcast();
  final _rssiSamples = StreamController<RssiSample>.broadcast();
  Timer? _rssiTimer;
  Timer? _selfHealTimer;
  int _linklessTicks = 0;
  static const Duration _rssiPollInterval = Duration(seconds: 5);

  /// Consecutive failed RSSI reads per central link — the zombie-link
  /// detector's evidence. Reset on any successful read or teardown.
  final Map<String, int> _rssiFails = {};
  static const int _staleRssiFailures = 3;

  /// Recently linked peer peripheral identifiers, most recent last. Persisted
  /// via [knownPeersLoad]/[knownPeersSave] so a fresh launch (including an
  /// iOS state-restoration relaunch) can re-arm pending connects to every
  /// known peer without needing to scan — a backgrounded peer's overflow
  /// advertisement is invisible to a scan, but a connect-by-identifier works.
  final Set<String> _knownPeers = {};
  static const int _maxKnownPeers = 6;

  void _rememberPeer(String uuid) {
    _knownPeers.remove(uuid);
    _knownPeers.add(uuid);
    while (_knownPeers.length > _maxKnownPeers) {
      _knownPeers.remove(_knownPeers.first);
    }
    knownPeersSave?.call(_knownPeers.toList());
  }

  /// Which known-peer ids to arm as pending reconnects, MOST-RECENT FIRST and
  /// capped at [_maxPendingReconnects] (further clamped by [budget]).
  ///
  /// [saved] is oldest→newest (see [_rememberPeer]). The cap matters: without
  /// it, arming all known peers overflows the pending set, and
  /// [_pendingReconnect] evicts the oldest-ARMED entry — which, arming
  /// newest-first, is the freshest peer. That dropped the peer we JUST linked
  /// with in favour of stale old ids, leaving the one connect-by-identifier
  /// that would actually succeed un-armed. iOS 27 can't rediscover a
  /// backgrounded peer by scan, so this pending connect is the only reconnect
  /// path — it must target the freshest ids. Pure + static for testability.
  static List<String> pendingReconnectOrder(List<String> saved, int budget) {
    final cap = budget < _maxPendingReconnects ? budget : _maxPendingReconnects;
    if (cap <= 0) return const [];
    return saved.reversed.take(cap).toList();
  }

  /// iOS: stand up pending connects to every persisted peer. Capped so the
  /// standing connects can't starve scan-driven links of [maxLinks] slots.
  Future<void> _reconnectKnownPeers() async {
    try {
      final saved = await knownPeersLoad?.call() ?? const <String>[];
      if (saved.isEmpty) return;
      _knownPeers.addAll(saved);
      final budget = maxLinks - _links.length - _connecting.length - 2;
      var armed = 0;
      for (final uuid in pendingReconnectOrder(saved, budget)) {
        try {
          final peripheral = await _central.getPeripheral(uuid);
          if (_links.containsKey('C:$uuid') || _connecting.contains(uuid)) {
            continue;
          }
          _pendingReconnect(peripheral);
          armed++;
        } catch (_) {} // malformed/unknown id — scan will find them instead
      }
      if (armed > 0) _log('BLE known-peer reconnect armed x$armed');
    } catch (_) {}
  }

  /// Standing pending-reconnect keys (subset of [_connecting]) and their
  /// peripherals. iOS pending connects never time out, and Android peers
  /// rotate their advertising address on every restart — so pendings to a
  /// dead address would otherwise pile up forever, eat the [maxLinks] slot
  /// budget, and silently block every NEW discovery (observed: killing the
  /// Android peer knocked the *other* iPhone offline too). Kept out of the
  /// discovery budget, capped, oldest-evicted.
  final Set<String> _pendingKeys = {};
  final Map<String, Peripheral> _pendingPeripherals = {};
  static const int _maxPendingReconnects = 4;

  /// Per-pending staleness watchdog + strike counter. A pending connect that
  /// produces no link within [_pendingStaleTimeout] is almost certainly aimed
  /// at a rotated/dead identifier (a peer in range links in seconds). We free
  /// the slot each time and, after two straight strikes, forget the identifier
  /// so deep-heal/boot stop resurrecting it — the peer's live address is still
  /// found by scan when it next appears. This is the leak fix: previously an
  /// identifier was dropped ONLY on an `illegalArgument` throw, but the common
  /// case is a connect that simply never completes and never throws.
  final Map<String, Timer> _pendingTimers = {};
  final Map<String, int> _pendingStaleStrikes = {};
  static const Duration _pendingStaleTimeout = Duration(seconds: 90);

  /// Failed (re)connect attempts per peripheral, driving retry backoff.
  /// A pending reconnect is one-shot on iOS: once it completes and our GATT
  /// setup fails (e.g. the peer was republishing its service that instant),
  /// nobody re-arms it — so we must, or the node sits link-less until the
  /// OS suspends it and messages stop flowing entirely.
  final Map<String, int> _reconnectAttempts = {};
  final Map<String, Timer> _reconnectTimers = {};

  /// Last discovery-triggered dial per key — a short cooldown that keeps a
  /// scan burst from becoming a fail storm without letting the long
  /// background backoff suppress a peer that is advertising right now.
  final Map<String, DateTime> _lastDialAt = {};

  bool _servicePublished = false;

  void _scheduleReconnect(Peripheral peripheral, String key) {
    if (!Platform.isIOS || _disposed || !_started) return;
    final attempt = (_reconnectAttempts[key] ?? 0) + 1;
    _reconnectAttempts[key] = attempt;
    final delay = switch (attempt) {
      1 => const Duration(seconds: 5),
      2 => const Duration(seconds: 15),
      3 => const Duration(seconds: 60),
      _ => const Duration(minutes: 5),
    };
    _log('BLE reconnect retry #$attempt in ${delay.inSeconds}s: $key');
    _reconnectTimers[key]?.cancel();
    _reconnectTimers[key] = Timer(delay, () {
      _reconnectTimers.remove(key);
      if (_disposed || !_started) return;
      _pendingReconnect(peripheral);
    });
  }

  final Map<String, MeshLink> _links = {};
  final Set<String> _connecting = {};

  // Our local mutable RX characteristic (peripheral role notifies on it).
  GATTCharacteristic? _localRx;

  final List<StreamSubscription> _subs = [];
  bool _started = false;

  MeshTransport({
    required this.myShortId,
    required this.infoValue,
    this.maxLinks = 8,
  });

  @override
  Stream<InboundPacket> get inbound => _inbound.stream;
  @override
  Stream<LinkEvent> get linkEvents => _linkEvents.stream;
  @override
  Stream<RssiSample> get rssiSamples => _rssiSamples.stream;
  Iterable<MeshLink> get links => _links.values;
  @override
  int get linkCount => _links.length;

  /// On iOS the very first launch reports `unauthorized`/`unknown` while the
  /// permission prompt is still on screen; once the user grants it the state
  /// flips to `poweredOn` and this emits true.
  @override
  RadioStatus get radioStatus => switch (_central.state) {
        BluetoothLowEnergyState.poweredOn => RadioStatus.ready,
        BluetoothLowEnergyState.poweredOff => RadioStatus.poweredOff,
        BluetoothLowEnergyState.unauthorized => RadioStatus.unauthorized,
        _ => RadioStatus.unknown,
      };

  @override
  Stream<bool> get availabilityChanged => _central.stateChanged.map((e) {
        _log('BLE state changed: ${e.state}');
        return e.state == BluetoothLowEnergyState.poweredOn;
      });

  /// Request permissions and power state; returns true if BLE is usable.
  @override
  Future<bool> ensureReady() async {
    // If the adapter already reports powered-on, permissions are granted and
    // the radio is on — skip the interactive authorize(). This is essential
    // for the Android HEADLESS service isolate: authorize() there calls
    // requestPermissions() on an Activity that doesn't exist and fails, which
    // would stop the mesh from ever starting. Permissions were already
    // granted in a prior UI session, so the state check (Context-based, no
    // Activity) is enough. Also spares the UI a redundant prompt.
    if (_central.state == BluetoothLowEnergyState.poweredOn) {
      _log('BLE ensureReady: already powered on');
      return true;
    }
    try {
      final a = await _central.authorize();
      final b = await _peripheral.authorize();
      return a && b;
    } on UnsupportedError {
      // authorize() is unsupported on Darwin/desktop: fall back to the cached
      // adapter state (updated via stateChanged events from the OS).
      _log('BLE ensureReady: state=${_central.state}');
      return _central.state == BluetoothLowEnergyState.poweredOn;
    } catch (e) {
      // Android in a headless isolate: authorize() throws (no Activity). Fall
      // back to whatever the Context-based state says.
      _log('BLE ensureReady: authorize failed ($e), state=${_central.state}');
      return _central.state == BluetoothLowEnergyState.poweredOn;
    }
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _wireCentral();
    _wirePeripheral();
    _wireAdapterState();
    _log('BLE start: central=${_central.state} peripheral=${_peripheral.state} '
        'me=${myShortId.short}');
    // The peripheral manager powers on independently of the central (on iOS
    // it often lags a beat behind). Publishing the service / advertising on a
    // not-yet-ready manager fails silently, leaving this node scanning but
    // invisible to everyone else — so only do it when it's ready, and let the
    // stateChanged listener pick it up otherwise.
    if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
      await _setupPeripheral();
      // Boot always REPLACES the advertisement. After iOS kills the app,
      // state restoration keeps a degraded background-class advertisement
      // alive on our behalf; a plain start then returns "already started"
      // and we'd keep running on that ghost — which (iOS 27) other iPhones'
      // filtered scans cannot see at all. Two phones in this state are
      // mutually invisible until one reinstalls (observed for hours).
      // On Android a fresh engine has no prior advertisement, so the extra
      // stop is a no-op — no address-rotation concern at boot.
      await _startAdvertising(restart: true);
    }
    await _startScanning();
    _beginScanModeCycle();
    // iOS: also stand up pending connects to every peer we've linked before —
    // a backgrounded iPhone is invisible to the scan but reachable by a
    // connect-by-identifier, and after a state-restoration relaunch this is
    // what stitches the mesh back together.
    if (Platform.isIOS) {
      unawaited(_reconnectKnownPeers());
    }
    // Poll connected links for signal strength so the UI can show how close
    // each neighbour is even after advertisements stop (connected peers
    // usually stop advertising).
    _rssiTimer = Timer.periodic(_rssiPollInterval, (_) => _pollRssi());
    // Self-heal: a start that failed mid-race (engine handoff, adapter busy)
    // used to leave the node running but mute. While we have no links at
    // all, periodically re-assert advertising + scanning — both calls are
    // idempotent ("already started" is harmless).
    _selfHealTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_started) return;
      // Zombie peripheral links: no stack fires a reliable "central left"
      // callback everywhere, and a dead P-link both lies to the UI and can
      // wedge the GATT server against NEW incoming connections (seen on
      // Samsung: fresh centrals time out with CBError 6 while a stale link
      // sits around). ANNOUNCE heartbeats land every ~15s, so minutes of
      // silence means the central is gone.
      for (final link in _links.values.toList()) {
        if (link.role == LinkRole.peripheral &&
            DateTime.now().difference(link.lastActivity) >
                const Duration(minutes: 3)) {
          _log('BLE peripheral link stale (silent 3m) — dropping ${link.id}');
          _tearDown(link.id);
        }
      }
      if (_links.isNotEmpty) {
        _linklessTicks = 0;
        return;
      }
      _linklessTicks++;
      _log('BLE self-heal: no links — re-asserting radio');
      // Deep heal: linkless for ~3 minutes straight → republish the GATT
      // service too. A wedged/stale server (engine handoff leftovers) makes
      // every incoming connect time out; removeAll+add gives the stack a
      // fresh one.
      // Light heal (advertise/scan re-kick) every 15s tick; the heavier GATT
      // republish only every ~2 min so it doesn't disrupt a peer mid-connect.
      final deep = _linklessTicks % 8 == 0;
      if (deep && _pendingKeys.isNotEmpty) {
        // Linkless for minutes with standing pendings: they're likely aimed
        // at dead rotated addresses. Cancel them all — scan/probe will find
        // the peers' live addresses instead.
        _log('BLE deep heal: cancelling ${_pendingKeys.length} stale '
            'pending reconnects');
        for (final k in _pendingKeys.toList()) {
          final p = _pendingPeripherals[k];
          if (p != null) {
            unawaited(_central.disconnect(p).then((_) {}, onError: (_) {}));
          }
        }
        // Re-arm from the persisted list once the cancels settle. Cancelling
        // alone left the node with NO standing connects at all — if the peer
        // came back on its old identifier (backgrounded, same session) there
        // was nothing waiting for it anymore.
        Timer(const Duration(seconds: 3), () {
          if (_started && Platform.isIOS) unawaited(_reconnectKnownPeers());
        });
      }
      if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
        if (_servicePublished && !deep) {
          unawaited(_startAdvertising());
        } else {
          if (deep) _log('BLE self-heal: republishing GATT service');
          unawaited(_setupPeripheral()
              .then((_) => _startAdvertising(restart: true)));
        }
      }
      if (_powerMode == PowerMode.active) {
        // Recycle, don't just re-assert: the OS can quietly stop delivering
        // scan results while our _scanning flag stays true (seen on iOS
        // after long foreground sessions — a fresh app instantly discovered
        // peers the old one had gone blind to). stop→start forces a real
        // new scan.
        unawaited(_stopScanning().then((_) => _startScanning()));
      }
      // Let a previously-missed Apple device be probed again sooner when we
      // have nothing at all.
      if (_linklessTicks >= 4) {
        _probeMisses.clear();
        _probeBackoff.clear();
      }
    });
  }

  @override
  void wake() {
    if (!_started) return;
    // Re-assert advertising and scanning. iOS suspends both while the app is
    // backgrounded; on resume this makes us visible / discovering again
    // without waiting for the next duty cycle. Do NOT republish the GATT
    // service here: removeAll+add tears the service down for a moment, and a
    // peer running discoverGATT in that window sees "service not found" and
    // fails its (re)connect. The service survives foreground/background — it
    // only needs publishing once per peripheral power-on.
    if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
      if (_servicePublished) {
        // Real restart: iOS advertising degrades while backgrounded and only
        // a stop+start restores the full foreground advertisement.
        unawaited(_startAdvertising(restart: true));
      } else {
        unawaited(
            _setupPeripheral().then((_) => _startAdvertising(restart: true)));
      }
    }
    if (_powerMode == PowerMode.active) {
      _beginScanModeCycle(); // reset to the wide phase before (re)scanning
      unawaited(_startScanning());
    } else {
      _beginDutyCycle();
    }
  }

  Future<void> _pollRssi() async {
    if (!_started) return;
    for (final link in _links.values.toList()) {
      if (link.role != LinkRole.central || link.peripheral == null) continue;
      try {
        final rssi = await _central.readRSSI(link.peripheral!);
        if (_disposed) return;
        _rssiFails.remove(link.id);
        if (link.remoteShortId != null) {
          _rssiSamples.add(RssiSample(link.remoteShortId, rssi));
        }
      } catch (_) {
        if (_disposed || !_links.containsKey(link.id)) return;
        // A half-dead GATT connection (peer walked away mid-suspend, stack
        // wedged) can eat frames for minutes without ever reporting a
        // disconnect. Three straight failed reads ≈ 15s of silence — cut the
        // link ourselves; the disconnect path re-arms the pending reconnect.
        final fails = (_rssiFails[link.id] ?? 0) + 1;
        _rssiFails[link.id] = fails;
        if (fails >= _staleRssiFailures) {
          _log('BLE link stale ($fails failed RSSI reads) — cutting ${link.id}');
          _rssiFails.remove(link.id);
          try {
            await _central.disconnect(link.peripheral!);
          } catch (_) {
            // The radio refused even the disconnect — tear down locally and
            // arm the reconnect by hand (no disconnect event will come).
            _tearDown(link.id);
            _pendingReconnect(link.peripheral!);
          }
        }
      }
    }
  }

  /// Recover automatically when the user toggles Bluetooth off and back on:
  /// re-publish the service, re-advertise and re-scan on power-on; drop stale
  /// links on power-off.
  void _wireAdapterState() {
    _subs.add(_central.stateChanged.listen((e) async {
      if (!_started) return;
      if (e.state == BluetoothLowEnergyState.poweredOn) {
        if (_powerMode == PowerMode.active) {
          _beginScanModeCycle();
          await _startScanning();
        } else {
          _beginDutyCycle();
        }
      } else if (e.state == BluetoothLowEnergyState.poweredOff) {
        // Stop the saver duty-cycle chain, otherwise it keeps re-flipping
        // _scanning and issuing doomed startDiscovery calls on a dead adapter.
        _dutyTimer?.cancel();
        _dutyTimer = null;
        _scanModeTimer?.cancel();
        _scanModeTimer = null;
        _scanning = false;
        for (final id in _links.keys.toList()) {
          _tearDown(id);
        }
        _connecting.clear();
      }
    }));

    // Publish the GATT service and advertise only once the peripheral manager
    // itself is powered on — its lifecycle is separate from the central's.
    _subs.add(_peripheral.stateChanged.listen((e) async {
      _log('BLE peripheral state: ${e.state}');
      if (!_started) return;
      if (e.state == BluetoothLowEnergyState.poweredOn) {
        await _setupPeripheral();
        // Same ghost-replacement as in start(): this is the boot path when
        // the peripheral manager powers on late (iOS state restoration).
        await _startAdvertising(restart: true);
      } else {
        // Power-off wipes the published GATT database.
        _servicePublished = false;
      }
    }));
  }

  @override
  Future<void> stop() async {
    _started = false;
    _rssiTimer?.cancel();
    _rssiTimer = null;
    _selfHealTimer?.cancel();
    _selfHealTimer = null;
    _dutyTimer?.cancel();
    _dutyTimer = null;
    _scanModeTimer?.cancel();
    _scanModeTimer = null;
    _overflowPhase = false;
    _scanning = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    try {
      await _peripheral.stopAdvertising();
      await _peripheral.removeAllServices();
    } catch (_) {}
    _servicePublished = false;
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    _reconnectTimers.clear();
    _reconnectAttempts.clear();
    for (final t in _pendingTimers.values) {
      t.cancel();
    }
    _pendingTimers.clear();
    _pendingStaleStrikes.clear();
    _rssiFails.clear();
    _links.clear();
    _connecting.clear();
    _pendingKeys.clear();
    _pendingPeripherals.clear();
    _probeMisses.clear();
    _lastDialAt.clear();
  }

  // ---------------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------------

  /// Send an encoded frame to every current neighbour except [exceptLinkId].
  @override
  Future<void> broadcast(Uint8List frameBytes, {String? exceptLinkId}) async {
    final targets = _links.values.where((l) => l.id != exceptLinkId).toList();
    // Per-link sends run CONCURRENTLY: a marginal long-range link whose
    // withResponse flushes crawl must not stall delivery to every other
    // neighbour (serially, one slow hop delayed the whole relay fan-out).
    // _sendTo never throws — failures tear down their own link.
    await Future.wait(targets.map((link) => _sendTo(link, frameBytes)));
  }

  /// Send an encoded frame to a single link.
  @override
  Future<void> sendToLink(String linkId, Uint8List frameBytes) async {
    final link = _links[linkId];
    if (link != null) await _sendTo(link, frameBytes);
  }

  Future<void> _sendTo(MeshLink link, Uint8List frameBytes) async {
    // Never let a too-small/negotiating MTU produce an invalid split.
    final size = link.maxPacketSize < BleConstants.minUsablePacketSize
        ? BleConstants.minUsablePacketSize
        : link.maxPacketSize;
    final List<Uint8List> packets;
    try {
      packets = L2Framing.split(frameBytes, size);
    } catch (_) {
      return; // frame too large to frame on this link
    }
    for (final p in packets) {
      try {
        if (link.role == LinkRole.central) {
          // iOS silently drops write-without-response packets once its queue
          // fills (the plugin completes immediately without checking
          // readiness), which evaporates long file-chunk bursts. Every few
          // packets write WITH response: the ATT round-trip drains the queue
          // before we continue.
          link.txBurst++;
          final flush = link.txBurst >= 6;
          if (flush) link.txBurst = 0;
          await _central.writeCharacteristic(
            link.peripheral!,
            link.remoteTx!,
            value: p,
            type: flush
                ? GATTCharacteristicWriteType.withResponse
                : GATTCharacteristicWriteType.withoutResponse,
          );
        } else {
          if (!link.centralSubscribed || _localRx == null) return;
          await _peripheral.notifyCharacteristic(
            link.central!,
            _localRx!,
            value: p,
          );
        }
      } catch (e) {
        // A failed write usually means the link died; tear it down.
        _tearDown(link.id);
        return;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Peripheral role setup
  // ---------------------------------------------------------------------------

  Future<void> _setupPeripheral() async {
    final rx = GATTCharacteristic.mutable(
      uuid: BleConstants.rxCharacteristicUuid,
      properties: [GATTCharacteristicProperty.notify],
      permissions: [GATTCharacteristicPermission.read],
      descriptors: [],
    );
    final tx = GATTCharacteristic.mutable(
      uuid: BleConstants.txCharacteristicUuid,
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );
    final info = GATTCharacteristic.immutable(
      uuid: BleConstants.infoCharacteristicUuid,
      value: infoValue,
      descriptors: [],
    );
    final service = GATTService(
      uuid: BleConstants.serviceUuid,
      isPrimary: true,
      includedServices: [],
      characteristics: [rx, tx, info],
    );
    _localRx = rx;
    try {
      await _peripheral.removeAllServices();
    } catch (_) {}
    try {
      await _peripheral.addService(service);
      _servicePublished = true;
      _log('BLE service published');
    } catch (e) {
      _servicePublished = false;
      _log('BLE addService failed: $e');
    }
  }

  /// "Already advertising" from either stack — the advertisement is alive,
  /// which is exactly what a re-assert wants; treat as success.
  /// (Darwin: "Advertising has already started"; Android: error code 3 =
  /// ADVERTISE_FAILED_ALREADY_STARTED.)
  static bool _isAlreadyAdvertising(Object e) {
    final s = e.toString();
    return s.contains('already started') || s.contains('error code: 3');
  }

  Future<void> _startAdvertising({bool restart = false}) async {
    // Restart ONLY on explicit request (foreground wake, GATT republish).
    // A stop+start is NOT a harmless refresh on Android: each start
    // allocates a fresh random address (RPA), and the linkless self-heal
    // re-asserts every 15s — restarting each time made this node hop
    // addresses faster than a *backgrounded* iPhone can finish a dial
    // (background discovery→connect loses the 15s race every time), so two
    // idle phones could never re-link until one was foregrounded. The
    // default path leaves a live advertisement untouched.
    if (restart) {
      try {
        await _peripheral.stopAdvertising();
      } catch (_) {}
    }
    // Advertise NAME + service UUID only. We used to also pack our short id
    // into manufacturer data, but a 128-bit service UUID (18B) + name (4B) +
    // flags (3B) already nearly fill a legacy 31-byte advertisement, so the
    // extra 12B of manufacturer data pushed Android over the limit and every
    // startAdvertising failed with DATA_TOO_LARGE (error code 1) — the node
    // then fell back to this exact packet anyway. Peers learn our short id
    // from the ANNOUNCE sent the instant a link comes up, so nothing is lost;
    // the service UUID stays because an iOS peer's BACKGROUND scan is filtered
    // on it (its only way to discover us), and the name drives iOS foreground
    // discovery. (Darwin never supported manufacturer-data advertising.)
    try {
      await _peripheral.startAdvertising(Advertisement(
        name: BleConstants.advertisedName,
        serviceUUIDs: [BleConstants.serviceUuid],
      ));
      _log('BLE advertising started (name + service uuid)');
    } catch (e) {
      if (_isAlreadyAdvertising(e)) return;
      _log('BLE startAdvertising failed: $e');
    }
  }

  void _wirePeripheral() {
    _subs.add(_peripheral.characteristicWriteRequested.listen((e) async {
      // A remote central wrote a packet to our TX characteristic.
      if (e.characteristic.uuid != BleConstants.txCharacteristicUuid) {
        try {
          await _peripheral.respondWriteRequestWithError(e.request,
              error: GATTError.writeNotPermitted);
        } catch (_) {}
        return;
      }
      try {
        await _peripheral.respondWriteRequest(e.request);
      } catch (_) {}
      final link = _peripheralLinkFor(e.central);
      _ingest(link, e.request.value);
    }));

    _subs.add(_peripheral.characteristicNotifyStateChanged.listen((e) async {
      if (e.characteristic.uuid != BleConstants.rxCharacteristicUuid) return;
      // Creates + emits link-up on first contact (see _peripheralLinkFor).
      final link = _peripheralLinkFor(e.central);
      link.centralSubscribed = e.state;
      if (e.state) {
        // Learn how much we can push per notification so peripheral-role links
        // don't stay stuck at the tiny default packet size.
        try {
          final maxNotify =
              await _peripheral.getMaximumNotifyLength(e.central);
          if (maxNotify > BleConstants.minUsablePacketSize) {
            link.maxPacketSize = maxNotify.clamp(
                BleConstants.minUsablePacketSize, 512);
          }
        } catch (_) {
          link.maxPacketSize = BleConstants.targetMaxPacketSize;
        }
      }
    }));

    // Android-only: track central disconnects to clean up links.
    try {
      _subs.add(_peripheral.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected) {
          _tearDown(_peripheralLinkId(e.central));
        }
      }));
    } on UnsupportedError {
      // iOS/macOS: no peripheral connection callbacks; links time out via
      // failed writes instead.
    }
  }

  MeshLink _peripheralLinkFor(Central central) {
    final id = _peripheralLinkId(central);
    final existing = _links[id];
    if (existing != null) return existing;
    // First contact from this central (subscribe OR write). Emit link-up so
    // the mesh sends its ANNOUNCE/HAVE back and — crucially — [_links] becomes
    // non-empty, which stops the linkless self-heal from republishing the
    // GATT service and tearing this very connection down (the "central is
    // attached but we think we're linkless" loop that left iPhone↔Android
    // one-directional).
    final link = MeshLink(id: id, role: LinkRole.peripheral, central: central);
    _links[id] = link;
    _emitUp(link);
    return link;
  }

  String _peripheralLinkId(Central central) => 'P:${central.uuid}';

  // ---------------------------------------------------------------------------
  // Central role setup
  // ---------------------------------------------------------------------------

  Future<void> _startScanning() async {
    // Held off while a connect handshake is in flight (Android 133 fix) — the
    // connect's finally-block resumes scanning.
    if (_scanPausedForConnect) return;
    if (_scanning) return;
    _scanning = true;
    try {
      // Scan UNFILTERED whenever the OS allows it, and match SpotLink in
      // software (see [_isSpotLink]):
      // - Android: its hardware service-UUID filter can't match an iPhone's
      //   overflow-area advertisement at all (Results=0).
      // - iOS FOREGROUND: on iOS 27 (beta 24A5380h) another iPhone's 128-bit
      //   service UUID is neither matched by the filter nor surfaced in the
      //   parsed advertisement (observed: unfiltered scan sees the peer as a
      //   name-'SL'-only packet while the filtered scan logs "0
      //   advertisements delivered" in bluetoothd). Name matching is what
      //   actually finds iPhone peers there.
      // - iOS BACKGROUND: an unfiltered scan delivers nothing (OS rule), so
      //   the UUID filter is required — [setForeground] swaps modes.
      final unfiltered = Platform.isAndroid ||
          _diagUnfilteredScan ||
          (Platform.isIOS && _foregroundScan && !_overflowPhase);
      await _central.startDiscovery(
        serviceUUIDs: unfiltered ? null : [BleConstants.serviceUuid],
      );
      _log('BLE scanning started (${unfiltered ? 'unfiltered' : 'filtered'})');
    } catch (e) {
      // Leave the flag down so the next attempt actually retries — a wedged
      // "true" here after a failed start (e.g. the adapter was mid-handoff
      // between the headless and UI engines) silenced the radio forever.
      _scanning = false;
      _log('BLE startDiscovery failed: $e');
    }
  }

  Future<void> _stopScanning() async {
    if (!_scanning) return;
    _scanning = false;
    try {
      await _central.stopDiscovery();
    } catch (_) {}
  }

  /// Android: stop the scan for the duration of a connect handshake so the
  /// radio isn't split between scanning and connecting (the `status 133`
  /// cause). Refcounted so overlapping connects pause once and resume once.
  Future<void> _pauseScanForConnect() async {
    _connectDepth++;
    if (_connectDepth == 1) {
      _scanPausedForConnect = true;
      await _stopScanning();
    }
  }

  void _resumeScanForConnect() {
    if (_connectDepth > 0) _connectDepth--;
    if (_connectDepth > 0 || !_scanPausedForConnect) return;
    _scanPausedForConnect = false;
    if (!_started) return;
    if (_powerMode == PowerMode.active) {
      unawaited(_startScanning());
    } else {
      _beginDutyCycle();
    }
  }

  /// Whether the app is foregrounded — gates the iOS unfiltered scan mode.
  /// Defaults true (normal launches are foreground); a background relaunch
  /// sets it false via [setForeground] right after start.
  bool _foregroundScan = true;

  /// iOS: swap between the wide foreground scan (unfiltered + software
  /// match — the only mode that reliably finds another iPhone on iOS 27)
  /// and the filtered background scan (required by the OS). No-op on
  /// Android, which always scans unfiltered.
  void setForeground(bool foreground) {
    if (_foregroundScan == foreground) return;
    _foregroundScan = foreground;
    if (!_started || !Platform.isIOS) return;
    _scanModeTimer?.cancel();
    _scanModeTimer = null;
    _overflowPhase = false;
    if (_powerMode == PowerMode.active) {
      unawaited(_stopScanning().then((_) => _startScanning()));
      if (foreground) _beginScanModeCycle();
    }
  }

  /// Switch power profile at runtime (e.g. user toggles "battery saver").
  void setPowerMode(PowerMode mode) {
    if (_powerMode == mode) return;
    _powerMode = mode;
    _dutyTimer?.cancel();
    _dutyTimer = null;
    _scanModeTimer?.cancel();
    _scanModeTimer = null;
    _overflowPhase = false;
    if (!_started) return;
    if (mode == PowerMode.active) {
      _beginScanModeCycle();
      _startScanning();
    } else {
      _beginDutyCycle();
    }
  }

  PowerMode get powerMode => _powerMode;

  /// Android scan mode: 0=LOW_POWER, 1=BALANCED, 2=LOW_LATENCY. LOW_LATENCY
  /// (the vendor default) scans near-continuously and is the single biggest
  /// battery drain; BALANCED still discovers within a few seconds at roughly
  /// half the power. Adaptive power (see MeshController) picks the tier.
  static const _scanPowerChannel = MethodChannel('spotlink/scan_power');
  int _scanModeCode = 2;

  /// Set the Android BLE scan mode and re-scan to apply it (no-op elsewhere).
  Future<void> setScanMode(int code) async {
    if (!Platform.isAndroid || _scanModeCode == code) return;
    _scanModeCode = code;
    try {
      await _scanPowerChannel.invokeMethod('setScanMode', code);
    } catch (_) {} // fork without the channel: keeps the vendor default
    _log('BLE scan mode -> ${const {
          0: 'low-power',
          1: 'balanced',
          2: 'low-latency'
        }[code]}');
    // The scanner reads the new mode on its next startScan, so bounce it.
    if (_started && _scanning) {
      await _stopScanning();
      await _startScanning();
    }
  }

  void _beginDutyCycle() {
    _dutyTimer?.cancel();
    // Scan window, then idle window, repeating.
    Future<void> onTick() async {
      await _startScanning();
      _dutyTimer = Timer(_saverScanOn, () async {
        await _stopScanning();
        _dutyTimer = Timer(_saverScanOff, onTick);
      });
    }

    onTick();
  }

  /// (Re)start the iOS foreground scan-mode alternation, beginning with the
  /// wide window. See [_scanModeTimer]. No-op outside iOS/foreground/active
  /// (the saver duty cycle and the background filtered scan cover the rest).
  void _beginScanModeCycle() {
    _scanModeTimer?.cancel();
    _scanModeTimer = null;
    _overflowPhase = false;
    if (!Platform.isIOS || _diagUnfilteredScan) return;
    if (!_started || !_foregroundScan || _powerMode != PowerMode.active) {
      return;
    }
    void schedule() {
      _scanModeTimer =
          Timer(_overflowPhase ? _overflowScanWindow : _wideScanWindow, () {
        if (!_started || !_foregroundScan || _powerMode != PowerMode.active) {
          return;
        }
        _overflowPhase = !_overflowPhase;
        unawaited(_stopScanning().then((_) => _startScanning()));
        schedule();
      });
    }

    schedule();
  }

  void _wireCentral() {
    _subs.add(_central.discovered.listen((e) => _onDiscovered(e)));

    _subs.add(_central.connectionStateChanged.listen((e) {
      if (e.state == ConnectionState.disconnected) {
        final key = e.peripheral.uuid.toString();
        final hadLink = _links.containsKey('C:$key');
        _tearDown('C:$key');
        _connecting.remove(key);
        // iOS: with both apps backgrounded, scan-based rediscovery is blind —
        // a backgrounded peripheral's advertisement moves to the overflow
        // area, which only *foreground* scanners can see. But a pending
        // connect() to a known peripheral never times out and completes in
        // the background as soon as the peer is back in range, so re-arm one
        // whenever an established link drops.
        if (hadLink) _pendingReconnect(e.peripheral);
      }
    }));

    _subs.add(_central.characteristicNotified.listen((e) {
      if (e.characteristic.uuid != BleConstants.rxCharacteristicUuid) return;
      final link = _links['C:${e.peripheral.uuid}'];
      if (link != null) _ingest(link, e.value);
    }));
  }

  /// An unfiltered Android scan surfaces every BLE device nearby — accept a
  /// peripheral only if it's actually SpotLink: our service UUID in the scan
  /// record, or (for iOS peers whose UUID hid in the overflow area) our
  /// advertised local name 'SL'.
  bool _isSpotLink(Advertisement adv) {
    if (adv.serviceUUIDs.contains(BleConstants.serviceUuid)) return true;
    if (adv.name == BleConstants.advertisedName) return true;
    // Deliberately NOT matching on manufacturer id: ours is 0xFFFF (the
    // reserved/test id), which random gadgets also emit — a KT GiGA Genie
    // speaker matched and got dialled as a "SpotLink peer" (observed). A real
    // SpotLink advertisement always carries the service UUID and/or name;
    // manufacturer data is only the shortId hint once already matched.
    return false;
  }

  /// A *backgrounded* iPhone hides both its service UUID (overflow area) and
  /// its local name, so nothing in the advertisement says "SpotLink". The one
  /// thing iOS can't hide is Apple's own continuity beacon (manufacturer id
  /// 0x004C). On Android we probe-connect to very-near Apple devices and let
  /// GATT discovery decide: SpotLink service present → real link; absent →
  /// remember the miss and leave it alone for a while.
  static const int _appleManufacturerId = 0x004C;
  static const Duration _probeMissTtl = Duration(minutes: 10);
  final Map<String, DateTime> _probeMisses = {};

  /// Short cooldown after a probe dial FAILS to connect (status 133 etc.). A
  /// dense room (office full of AirPods/Macs/iPhones) otherwise re-dials the
  /// same failing gadget every 12s, and each doomed connectGatt starves the
  /// real peer. Distinct from [_probeMisses] (10 min, "connected but not
  /// SpotLink") — this is kept short so a genuinely-SpotLink iPhone that hit a
  /// transient failure is retried soon.
  static const Duration _probeFailBackoff = Duration(seconds: 90);
  final Map<String, DateTime> _probeBackoff = {};

  /// Keys of probe dials currently in flight. Bounded so a room full of
  /// Apple gadgets (TV, AirPods, other iPhones) can't fire a storm of
  /// concurrent connectGatt calls that exhausts the Android GATT client pool
  /// and starves the ONE real peer we're trying to reach.
  final Set<String> _activeProbes = {};
  static const int _maxConcurrentProbes = 1;

  bool _isIosProbeCandidate(DiscoveredEventArgs e) {
    if (!Platform.isAndroid) return false;
    if (e.rssi < -70) return false; // only close-by devices are worth a dial
    if (_activeProbes.length >= _maxConcurrentProbes) return false;
    final uuid = e.peripheral.uuid.toString();
    final missedAt = _probeMisses[uuid];
    if (missedAt != null &&
        DateTime.now().difference(missedAt) < _probeMissTtl) {
      return false;
    }
    final failedAt = _probeBackoff[uuid];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _probeFailBackoff) {
      return false;
    }
    return e.advertisement.manufacturerSpecificData
        .any((m) => m.id == _appleManufacturerId);
  }

  Future<void> _onDiscovered(DiscoveredEventArgs e) async {
    if (_logBle) {
      final a = e.advertisement;
      _log('BLE saw ${e.peripheral.uuid.toString().substring(0, 8)} '
          'name=${a.name} svc=${a.serviceUUIDs.length}'
          '${a.serviceUUIDs.isNotEmpty ? "[${a.serviceUUIDs.first}]" : ""} '
          'mfr=${a.manufacturerSpecificData.length} rssi=${e.rssi} '
          'match=${_isSpotLink(a)}');
    }
    // Filtered out in hardware on iOS; done in software on Android's
    // unfiltered scan so we never dial random headphones/beacons. Very-near
    // Apple devices get a probe dial instead: a backgrounded iPhone's
    // advertisement carries no SpotLink marker at all (see
    // [_isIosProbeCandidate]) — GATT discovery is the only way to tell.
    final probe = !_isSpotLink(e.advertisement);
    if (probe && !_isIosProbeCandidate(e)) return;

    final remoteId = _shortIdFromAdvertisement(e.advertisement);

    // Never connect to our own advertisement (can happen with some stacks).
    if (remoteId != null && remoteId == myShortId) return;

    // Advertisements carry a live signal-strength reading — surface it for
    // the proximity UI (peer is null when the adv has no manufacturer id).
    if (!_disposed) _rssiSamples.add(RssiSample(remoteId, e.rssi));

    // We deliberately do NOT tie-break here. Cross-platform discovery is
    // asymmetric: iOS strips manufacturer data and puts 128-bit service UUIDs
    // in an overflow area that Android frequently cannot parse, so an iOS
    // advertiser may be invisible to Android. If we skipped connecting when
    // "our id is larger", an Android<->iOS pair could end up with NO link.
    // Instead every node connects to any SpotLink peripheral it can discover.
    // A redundant reverse link (e.g. between two Android devices) is harmless:
    // the router dedups by msgId, so nothing is delivered twice — it only
    // costs one extra connection. See docs/ARCHITECTURE.md §11.

    // Respect the link cap to bound battery/memory usage. Count in-flight
    // connections too, or a discovery burst can overshoot the cap (every
    // event sees _links still empty before any connect completes) — but NOT
    // standing pending-reconnects: a pending to a dead rotated address must
    // never starve a live discovery (it silently knocked every peer offline).
    if (_links.length + (_connecting.length - _pendingKeys.length) >=
        maxLinks) {
      return;
    }

    final key = e.peripheral.uuid.toString();
    if (_links.containsKey('C:$key') || _connecting.contains(key)) return;
    // Rate-limit per key so a discovery burst can't become a fail storm —
    // but do NOT let the escalating background backoff (up to 5 min) suppress
    // this path: a discovery means the peer is physically present RIGHT NOW,
    // so a short cooldown is enough. (This was the "kill the bridge and
    // everyone stays offline for 5 minutes" bug.) Acting now supersedes the
    // scheduled retry, so cancel it.
    final last = _lastDialAt[key];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 12)) {
      return;
    }
    _lastDialAt[key] = DateTime.now();
    _reconnectTimers.remove(key)?.cancel();
    _connecting.add(key);
    _log(probe
        ? 'BLE probing Apple device $key (rssi=${e.rssi})'
        : 'BLE discovered $key (shortId=$remoteId)');
    await _establishLink(e.peripheral, key, remoteId: remoteId, probe: probe);
  }

  /// Re-arm a background-proof connection to a peer we were linked with.
  /// iOS-only: elsewhere the (foreground-service) scanner reconnects fine,
  /// and Android's connect() can block a radio slot while it retries.
  /// The pending attempt occupies a [_connecting] slot so discovery won't
  /// race it; it resolves whenever the peer reappears — minutes later is fine.
  void _pendingReconnect(Peripheral peripheral) {
    if (!Platform.isIOS) return;
    if (_disposed || !_started) return;
    final key = peripheral.uuid.toString();
    if (_links.containsKey('C:$key') || _connecting.contains(key)) return;
    // Cap the standing pendings, evicting the oldest — rotated (dead)
    // addresses are the common case and the newest one is likeliest alive.
    while (_pendingKeys.length >= _maxPendingReconnects) {
      final oldest = _pendingKeys.first;
      _pendingKeys.remove(oldest);
      final old = _pendingPeripherals.remove(oldest);
      _log('BLE pending reconnect evicted $oldest');
      if (old != null) {
        // Cancelling makes its connect() throw; the establishLink cleanup
        // then releases the _connecting slot.
        unawaited(_central.disconnect(old).then((_) {}, onError: (_) {}));
      }
    }
    _connecting.add(key);
    _pendingKeys.add(key);
    _pendingPeripherals[key] = peripheral;
    _pendingTimers[key]?.cancel();
    _pendingTimers[key] = Timer(_pendingStaleTimeout, () => _expireStalePending(key));
    _log('BLE pending reconnect armed $key');
    unawaited(_establishLink(peripheral, key));
  }

  /// See [_pendingTimers]. Fired when a standing pending connect has gone
  /// [_pendingStaleTimeout] without linking: free the slot, and after two
  /// strikes forget the identifier so it stops being re-armed at every
  /// deep-heal / boot.
  void _expireStalePending(String key) {
    _pendingTimers.remove(key);
    if (_links.containsKey('C:$key')) return; // connected in the meantime
    if (!_pendingKeys.contains(key)) return; // already resolved / evicted
    final strikes = (_pendingStaleStrikes[key] ?? 0) + 1;
    _pendingStaleStrikes[key] = strikes;
    if (strikes >= 2 && _knownPeers.remove(key)) {
      knownPeersSave?.call(_knownPeers.toList());
      _pendingStaleStrikes.remove(key);
      _log('BLE forgetting stale peer identifier $key '
          '(no link in ${_pendingStaleTimeout.inSeconds}s x$strikes)');
    } else {
      _log('BLE pending reconnect expired $key (strike $strikes)');
    }
    final p = _pendingPeripherals[key];
    if (p != null) {
      // Cancels the awaiting connect() → its establishLink finally frees the
      // _connecting / _pendingKeys slots.
      unawaited(_central.disconnect(p).then((_) {}, onError: (_) {}));
    }
  }

  /// Connect to a SpotLink peripheral and bring up the GATT link. The caller
  /// must have added [key] to [_connecting]; it is removed here when done.
  Future<void> _establishLink(Peripheral peripheral, String key,
      {PeerId? remoteId, bool probe = false}) async {
    final linkId = 'C:$key';
    var connected = false; // did _central.connect succeed?
    var serviceMissing = false; // connected, but no SpotLink service
    if (probe) _activeProbes.add(key);
    final pauseScan = Platform.isAndroid;
    try {
      // Android: pause scanning across the connect so the radio isn't split
      // between scan + connect (status 133). iOS keeps scanning — its pending
      // reconnects are long-lived by design and CoreBluetooth arbitrates.
      if (pauseScan) await _pauseScanForConnect();
      try {
        // Probe dials to random Apple devices must not hang for Android's full
        // ~30s connectGatt timeout while holding a GATT client slot — bound
        // them. Android non-probe connects are also bounded so a wedged dial
        // can't hold the scan paused forever; iOS non-probe connects stay
        // unbounded (pending reconnects resolve minutes later by design).
        if (probe) {
          await _central.connect(peripheral).timeout(const Duration(seconds: 8));
        } else if (Platform.isAndroid) {
          await _central.connect(peripheral).timeout(const Duration(seconds: 20));
        } else {
          await _central.connect(peripheral);
        }
      } finally {
        if (pauseScan) _resumeScanForConnect();
      }
      connected = true;
      // Everything after the OS-level connect is bounded: a single lost
      // response frame (discovery response, CCCD ack) used to hang this
      // await chain FOREVER — the _connecting slot stayed occupied, so the
      // peer could never be redialed until an app restart (observed: two
      // idle phones mutually wedged mid-establish for 20+ minutes). The
      // connect() above intentionally stays unbounded on the non-probe
      // path — iOS pending reconnects resolve minutes later by design.
      final (tx, rx, maxPacket) = await () async {
        var services = await _central.discoverGATT(peripheral);
        var hasSvc = services.any((s) => s.uuid == BleConstants.serviceUuid);
        // A SpotLink advertiser with no SpotLink service is almost always an
        // iOS app mid-relaunch: when iOS kills the app in the background,
        // state restoration keeps ADVERTISING on its behalf, but the GATT
        // service only returns once the relaunched app republishes it —
        // seconds after our connect (which is the very event that wakes it).
        // Hanging up instantly re-suspends the app and loops forever
        // ("connect → service not found → disconnect" every 15s, observed
        // for hours). Staying connected grants the app background runtime:
        // wait and look again before giving up.
        if (!hasSvc && !probe) {
          for (var attempt = 0; attempt < 2 && !hasSvc; attempt++) {
            await Future<void>.delayed(const Duration(seconds: 4));
            services = await _central.discoverGATT(peripheral);
            hasSvc = services.any((s) => s.uuid == BleConstants.serviceUuid);
          }
          if (hasSvc) _log('BLE service appeared after relaunch wait: $key');
        }
        if (!hasSvc) {
          serviceMissing = true;
          throw StateError('service not found');
        }
        final svc =
            services.firstWhere((s) => s.uuid == BleConstants.serviceUuid);
        GATTCharacteristic? tx, rx;
        for (final c in svc.characteristics) {
          if (c.uuid == BleConstants.txCharacteristicUuid) tx = c;
          if (c.uuid == BleConstants.rxCharacteristicUuid) rx = c;
        }
        if (tx == null || rx == null) {
          throw StateError('characteristics not found');
        }

        var maxPacket = BleConstants.defaultMaxPacketSize;
        try {
          await _central.requestMTU(peripheral, mtu: 247);
        } catch (_) {}
        try {
          maxPacket = await _central.getMaximumWriteLength(
            peripheral,
            type: GATTCharacteristicWriteType.withoutResponse,
          );
        } catch (_) {
          maxPacket = BleConstants.targetMaxPacketSize;
        }

        await _central.setCharacteristicNotifyState(peripheral, rx,
            state: true);
        return (tx, rx, maxPacket);
      }()
          .timeout(const Duration(seconds: 25));

      // We may have been stopped/disposed while awaiting the connection. Don't
      // resurrect _links or emit on a closed controller — just disconnect.
      if (!_started) {
        try {
          await _central.disconnect(peripheral);
        } catch (_) {}
        return;
      }

      final link = MeshLink(
        id: linkId,
        role: LinkRole.central,
        peripheral: peripheral,
        remoteTx: tx,
        remoteRx: rx,
        maxPacketSize: maxPacket.clamp(BleConstants.defaultMaxPacketSize, 512),
      )..remoteShortId = remoteId;
      _links[linkId] = link;
      _emitUp(link);
      if (probe) _log('BLE probe hit: $key is a SpotLink peer');
      _reconnectAttempts.remove(key);
      _reconnectTimers.remove(key)?.cancel();
      _pendingStaleStrikes.remove(key); // linked → identifier proven live
      _probeMisses.remove(key);
      _probeBackoff.remove(key);
      _rememberPeer(key);
    } catch (err) {
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
      if (probe) {
        if (connected && serviceMissing) {
          // Definitively NOT SpotLink (connected, no service) — block it for
          // the full TTL so we stop dialing this Apple gadget.
          _probeMisses[key] = DateTime.now();
          _log('BLE probe miss $key (not SpotLink)');
        } else {
          // Connect itself failed — a real SpotLink iPhone hits transient
          // timeouts constantly (CBError 6). Do NOT blocklist for 10 min, but
          // apply a short backoff so a dense room can't re-dial this same
          // gadget every 12s and starve the real peer with status-133 storms.
          _probeBackoff[key] = DateTime.now();
          _log('BLE probe connect failed $key: $err (backoff ${_probeFailBackoff.inSeconds}s)');
        }
      } else {
        _log('BLE connect failed $key: $err');
        if (_isUnknownIdentifier(err)) {
          // Darwin threw illegalArgument: the identifier is not in the
          // system's peripheral cache (rotated/forgotten address — typical
          // for a restarted Android peer). No retry can ever succeed until a
          // live scan rediscovers the peer, so drop the standing retry AND
          // the persisted identifier that keeps resurrecting it at launch.
          _reconnectAttempts.remove(key);
          if (_knownPeers.remove(key)) {
            knownPeersSave?.call(_knownPeers.toList());
            _log('BLE forgetting dead peer identifier $key');
          }
        } else {
          // Transient failures happen (the peer republishing its GATT
          // database, radio contention). Keep trying with backoff — a
          // SpotLink peer that stays silent is worth a standing reconnect
          // on iOS.
          _scheduleReconnect(peripheral, key);
        }
      }
    } finally {
      _connecting.remove(key);
      _pendingKeys.remove(key);
      _pendingPeripherals.remove(key);
      _pendingTimers.remove(key)?.cancel(); // resolved → watchdog no longer needed
      if (probe) {
        _activeProbes.remove(key);
        // A probe that timed out (not a clean disconnect) leaves a pending
        // connectGatt — force-release it so the GATT client slot is freed.
        unawaited(_central.disconnect(peripheral).then((_) {}, onError: (_) {}));
      }
    }
  }

  /// Darwin's connect() throws `illegalArgument` when the peripheral
  /// identifier is unknown to the system cache — a permanent failure for that
  /// identifier, not a transient radio error. (Matched on the string to keep
  /// this file free of a flutter/services dependency.)
  bool _isUnknownIdentifier(Object err) =>
      Platform.isIOS && err.toString().contains('illegalArgument');

  PeerId? _shortIdFromAdvertisement(Advertisement adv) {
    for (final m in adv.manufacturerSpecificData) {
      if (m.id == BleConstants.manufacturerId &&
          m.data.length >= PeerId.wireLength) {
        return PeerId(Uint8List.fromList(m.data));
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Shared
  // ---------------------------------------------------------------------------

  void _ingest(MeshLink link, Uint8List packet) {
    if (_disposed) return;
    link.lastActivity = DateTime.now();
    final full = link.reassembler.offer(packet);
    if (full != null) {
      _inbound.add(InboundPacket(link, full));
    }
  }

  void _emitUp(MeshLink link) {
    if (_disposed) return;
    _log('BLE link up ${link.id} (${link.role.name})');
    _linkEvents.add(LinkEvent(link, true));
  }

  void _tearDown(String linkId) {
    _rssiFails.remove(linkId);
    // Clear the dial cooldown for this peer so it can be re-dialled promptly
    // the moment its advertisement reappears (linkId is 'C:<key>').
    if (linkId.startsWith('C:')) _lastDialAt.remove(linkId.substring(2));
    final link = _links.remove(linkId);
    if (link != null && !_disposed) {
      _log('BLE link down $linkId');
      _linkEvents.add(LinkEvent(link, false));
    }
  }

  bool _disposed = false;

  Future<void> dispose() async {
    await stop();
    _disposed = true;
    await _inbound.close();
    await _linkEvents.close();
    await _rssiSamples.close();
  }
}
