import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'fast_lane.dart';

/// 두 피어가 같은 Wi-Fi/LAN을 공유할 때 파일 바이트를 평범한 TCP 소켓으로
/// 옮기는 패스트레인. 순수 `dart:io` — 네이티브 코드 없이 iOS↔Android로
/// 동작하며, 실제 루프백 소켓 위에서 완전히 테스트할 수 있다.
///
/// 이는 매우 흔한 "둘 다 같은 Wi-Fi" 경우(집 / 사무실 / 카페)를 Wi-Fi 속도로
/// 처리한다. AP 없는 P2P는 제공하지 않는다(그건 네이티브 Wi-Fi Aware / Direct /
/// MultipeerConnectivity 전송이 필요하다); 사용 가능한 LAN 주소가 없으면
/// [capabilities]가 비어 있고 메시는 BLE에 머문다. 수신자는 임시 포트를
/// 바인딩하고 자신의 <IPv4:port>를 BLE로 광고한다; 발신자가 그곳으로 연결한다.
class LanSocketFastLane implements FastLaneInterface {
  /// 테스트를 위해 주입 가능: 우리 자신의 도달 가능한 IPv4 주소를 어떻게
  /// 발견하는지. 기본값은 루프백이 아닌 네트워크 인터페이스를 열거하는 것이다.
  final Future<List<InternetAddress>> Function() _localAddresses;

  /// 테스트를 위해 주입 가능: 수신 대기 소켓의 바인드 주소. 실제 기기는 0.0.0.0
  /// (모든 인터페이스)에 바인딩한다; 테스트는 루프백으로 고정할 수 있다.
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
    if (addrs.isEmpty) return null; // 어떤 네트워크에도 없음 → BLE

    late final ServerSocket server;
    try {
      server = await ServerSocket.bind(_bindHost, 0);
    } catch (_) {
      return null;
    }

    // 도달 가능한 첫 IPv4 + 선택된 포트를 광고한다.
    final ip = addrs.first.rawAddress; // IPv4의 경우 4바이트
    if (ip.length != 4) {
      await server.close();
      return null;
    }
    final blob = Uint8List(6)
      ..setRange(0, 4, ip)
      ..[4] = (server.port >> 8) & 0xff
      ..[5] = server.port & 0xff;

    // 정확히 하나의 연결만 수락한 뒤, 수신 대기를 멈춘다.
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
      return null; // 도달할 수 없음 → BLE 폴백
    }
  }
}

class _SocketSession implements FastLaneSession {
  final Socket _socket;
  bool _closed = false;
  _SocketSession(this._socket);

  @override
  Stream<Uint8List> get incoming => _socket; // Socket은 Stream<Uint8List>이다

  @override
  void add(Uint8List data) => _socket.add(data);

  @override
  Future<void> finishSending() async {
    try {
      await _socket.flush();
      // 쓰기 쪽을 half-close → 피어의 리더에게 EOF를 알린다.
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
