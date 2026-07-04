import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'fast_lane.dart';

/// A fast lane that moves file bytes over a plain TCP socket when both peers
/// share a Wi-Fi/LAN. Pure `dart:io` — works iOS↔Android with no native code,
/// and is fully testable over real loopback sockets.
///
/// This covers the very common "둘 다 같은 Wi-Fi" case (home / office / cafe)
/// at Wi-Fi speed. It does NOT provide AP-less peer-to-peer (that needs the
/// native Wi-Fi Aware / Direct / MultipeerConnectivity transports); when no
/// usable LAN address exists, [capabilities] is empty and the mesh stays on
/// BLE. The receiver binds an ephemeral port and advertises its <IPv4:port>
/// over BLE; the sender dials it.
class LanSocketFastLane implements FastLaneInterface {
  /// Injectable for tests: how we discover our own reachable IPv4 addresses.
  /// Defaults to enumerating non-loopback network interfaces.
  final Future<List<InternetAddress>> Function() _localAddresses;

  /// Injectable for tests: bind address for the listening socket. Real devices
  /// bind 0.0.0.0 (all interfaces); tests can pin loopback.
  final InternetAddress _bindHost;

  LanSocketFastLane({
    Future<List<InternetAddress>> Function()? localAddresses,
    InternetAddress? bindHost,
  })  : _localAddresses = localAddresses ?? _defaultLocalAddresses,
        _bindHost = bindHost ?? InternetAddress.anyIPv4;

  static Future<List<InternetAddress>> _defaultLocalAddresses() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      return [for (final i in ifaces) ...i.addresses];
    } catch (_) {
      return const [];
    }
  }

  @override
  Set<FastLaneKind> get capabilities => {FastLaneKind.lanSocket};

  @override
  Future<FastLaneInbound?> prepareInbound(
      String transferIdHex, FastLaneKind kind) async {
    if (kind != FastLaneKind.lanSocket) return null;
    final addrs = await _localAddresses();
    if (addrs.isEmpty) return null; // not on any network → BLE

    late final ServerSocket server;
    try {
      server = await ServerSocket.bind(_bindHost, 0);
    } catch (_) {
      return null;
    }

    // Advertise the first reachable IPv4 + the chosen port.
    final ip = addrs.first.rawAddress; // 4 bytes for IPv4
    if (ip.length != 4) {
      await server.close();
      return null;
    }
    final blob = Uint8List(6)
      ..setRange(0, 4, ip)
      ..[4] = (server.port >> 8) & 0xff
      ..[5] = server.port & 0xff;

    // Accept exactly one connection, then stop listening.
    final completer = Completer<FastLaneSession?>();
    late final StreamSubscription sub;
    final timeout = Timer(const Duration(seconds: 8), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        sub.cancel();
        server.close();
      }
    });
    sub = server.listen((socket) {
      if (completer.isCompleted) {
        socket.destroy();
        return;
      }
      timeout.cancel();
      sub.cancel();
      server.close();
      completer.complete(_SocketSession(socket));
    }, onError: (_) {
      if (!completer.isCompleted) completer.complete(null);
    });

    return FastLaneInbound(
        FastLaneOffer(FastLaneKind.lanSocket, blob), completer.future);
  }

  @override
  Future<FastLaneSession?> connect(
      String transferIdHex, FastLaneOffer offer) async {
    if (offer.kind != FastLaneKind.lanSocket || offer.blob.length != 6) {
      return null;
    }
    final ip = InternetAddress.fromRawAddress(
        Uint8List.fromList(offer.blob.sublist(0, 4)));
    final port = (offer.blob[4] << 8) | offer.blob[5];
    try {
      final socket = await Socket.connect(ip, port,
          timeout: const Duration(seconds: 6));
      return _SocketSession(socket);
    } catch (_) {
      return null; // couldn't reach → BLE fallback
    }
  }
}

class _SocketSession implements FastLaneSession {
  final Socket _socket;
  bool _closed = false;
  _SocketSession(this._socket);

  @override
  Stream<Uint8List> get incoming => _socket; // Socket is a Stream<Uint8List>

  @override
  void add(Uint8List data) => _socket.add(data);

  @override
  Future<void> finishSending() async {
    try {
      await _socket.flush();
      // Half-close the write side → signals EOF to the peer's reader.
      await _socket.close();
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _socket.destroy();
    } catch (_) {}
  }
}
