import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../model/peer_id.dart';
import 'ble_constants.dart';
import 'framing.dart';

/// BLE diagnostics logging: always on in debug builds; enable in release with
/// `flutter build ios --release --dart-define=BLE_LOG=true`.
const bool _logBle = kDebugMode || bool.fromEnvironment('BLE_LOG');

/// Optional extra sink for BLE diagnostics (e.g. a file logger wired up by the
/// app layer). Release builds drop console output on iOS, so this is the only
/// way to diagnose BLE behaviour on a real device without a debugger.
void Function(String line)? bleLogSink;

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

  static const Duration _saverScanOn = Duration(seconds: 6);
  static const Duration _saverScanOff = Duration(seconds: 20);

  final CentralManager _central = CentralManager();
  final PeripheralManager _peripheral = PeripheralManager();

  final _inbound = StreamController<InboundPacket>.broadcast();
  final _linkEvents = StreamController<LinkEvent>.broadcast();
  final _rssiSamples = StreamController<RssiSample>.broadcast();
  Timer? _rssiTimer;
  static const Duration _rssiPollInterval = Duration(seconds: 5);

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
      await _startAdvertising();
    }
    await _startScanning();
    // Poll connected links for signal strength so the UI can show how close
    // each neighbour is even after advertisements stop (connected peers
    // usually stop advertising).
    _rssiTimer = Timer.periodic(_rssiPollInterval, (_) => _pollRssi());
  }

  @override
  void wake() {
    if (!_started) return;
    // Re-assert advertising and scanning. iOS suspends both while the app is
    // backgrounded; on resume this makes us visible / discovering again
    // without waiting for the next duty cycle.
    if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
      unawaited(_setupPeripheral().then((_) => _startAdvertising()));
    }
    if (_powerMode == PowerMode.active) {
      unawaited(_startScanning());
    } else {
      _beginDutyCycle();
    }
  }

  Future<void> _pollRssi() async {
    if (!_started) return;
    for (final link in _links.values.toList()) {
      if (link.role != LinkRole.central || link.peripheral == null) continue;
      if (link.remoteShortId == null) continue; // can't attribute the reading
      try {
        final rssi = await _central.readRSSI(link.peripheral!);
        if (_disposed) return;
        _rssiSamples.add(RssiSample(link.remoteShortId, rssi));
      } catch (_) {
        // Link died mid-read or the platform refused; the link teardown
        // paths handle the rest.
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
          await _startScanning();
        } else {
          _beginDutyCycle();
        }
      } else if (e.state == BluetoothLowEnergyState.poweredOff) {
        // Stop the saver duty-cycle chain, otherwise it keeps re-flipping
        // _scanning and issuing doomed startDiscovery calls on a dead adapter.
        _dutyTimer?.cancel();
        _dutyTimer = null;
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
        await _startAdvertising();
      }
    }));
  }

  @override
  Future<void> stop() async {
    _started = false;
    _rssiTimer?.cancel();
    _rssiTimer = null;
    _dutyTimer?.cancel();
    _dutyTimer = null;
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
    _links.clear();
    _connecting.clear();
  }

  // ---------------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------------

  /// Send an encoded frame to every current neighbour except [exceptLinkId].
  @override
  Future<void> broadcast(Uint8List frameBytes, {String? exceptLinkId}) async {
    final targets = _links.values.where((l) => l.id != exceptLinkId).toList();
    for (final link in targets) {
      await _sendTo(link, frameBytes);
    }
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
      _log('BLE service published');
    } catch (e) {
      _log('BLE addService failed: $e');
    }
  }

  Future<void> _startAdvertising() async {
    // The manufacturer data carries our short id so scanners can skip their
    // own advertisement and pre-learn the peer id. Darwin refuses to
    // advertise manufacturer data at all (CoreBluetooth supports only local
    // name + service UUIDs), so fall back to a bare advertisement there —
    // peers learn our id from the ANNOUNCE sent right after the link is up.
    try {
      await _peripheral.startAdvertising(Advertisement(
        name: 'SL',
        serviceUUIDs: [BleConstants.serviceUuid],
        manufacturerSpecificData: [
          ManufacturerSpecificData(
            id: BleConstants.manufacturerId,
            data: myShortId.bytes,
          ),
        ],
      ));
      _log('BLE advertising started');
      return;
    } catch (e) {
      _log('BLE startAdvertising with manufacturer data failed: $e');
    }
    try {
      await _peripheral.startAdvertising(Advertisement(
        name: 'SL',
        serviceUUIDs: [BleConstants.serviceUuid],
      ));
      _log('BLE advertising started (service uuid only)');
    } catch (e) {
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
        _emitUp(link);
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
    return _links.putIfAbsent(
      id,
      () => MeshLink(id: id, role: LinkRole.peripheral, central: central),
    );
  }

  String _peripheralLinkId(Central central) => 'P:${central.uuid}';

  // ---------------------------------------------------------------------------
  // Central role setup
  // ---------------------------------------------------------------------------

  Future<void> _startScanning() async {
    if (_scanning) return;
    _scanning = true;
    try {
      await _central.startDiscovery(
          serviceUUIDs: [BleConstants.serviceUuid]);
      _log('BLE scanning started');
    } catch (e) {
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

  /// Switch power profile at runtime (e.g. user toggles "battery saver").
  void setPowerMode(PowerMode mode) {
    if (_powerMode == mode) return;
    _powerMode = mode;
    _dutyTimer?.cancel();
    _dutyTimer = null;
    if (!_started) return;
    if (mode == PowerMode.active) {
      _startScanning();
    } else {
      _beginDutyCycle();
    }
  }

  PowerMode get powerMode => _powerMode;

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

  Future<void> _onDiscovered(DiscoveredEventArgs e) async {
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
    // event sees _links still empty before any connect completes).
    if (_links.length + _connecting.length >= maxLinks) return;

    final key = e.peripheral.uuid.toString();
    if (_links.containsKey('C:$key') || _connecting.contains(key)) return;
    _connecting.add(key);
    _log('BLE discovered $key (shortId=$remoteId)');
    await _establishLink(e.peripheral, key, remoteId: remoteId);
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
    if (_links.length + _connecting.length >= maxLinks) return;
    _connecting.add(key);
    _log('BLE pending reconnect armed $key');
    unawaited(_establishLink(peripheral, key));
  }

  /// Connect to a SpotLink peripheral and bring up the GATT link. The caller
  /// must have added [key] to [_connecting]; it is removed here when done.
  Future<void> _establishLink(Peripheral peripheral, String key,
      {PeerId? remoteId}) async {
    final linkId = 'C:$key';
    try {
      await _central.connect(peripheral);
      final services = await _central.discoverGATT(peripheral);
      final svc = services.firstWhere(
        (s) => s.uuid == BleConstants.serviceUuid,
        orElse: () => throw StateError('service not found'),
      );
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
    } catch (err) {
      _log('BLE connect failed $key: $err');
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
    } finally {
      _connecting.remove(key);
    }
  }

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
