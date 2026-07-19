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
      return pickAdvertisable(
          [for (final i in ifaces) (i.name, i.addresses)]);
    } catch (_) {
      return const [];
    }
  }

  /// 광고할 주소를 인터페이스 이름으로 선별한다. 예전에는 `addresses.first`를
  /// 그대로 광고했는데, 열거 결과에는 **셀룰러 인터페이스(통신사 NAT IP)**도
  /// 포함된다 — 그게 먼저 잡히면 송신자는 도달 불가능한 주소에 6초 매달렸다
  /// 실패하고 쿨다운까지 건다. Wi-Fi/유선/핫스팟을 앞세우고 셀룰러·터널은
  /// 아예 제외한다(셀룰러뿐이면 어차피 LAN 직결이 불가능하다 → BLE).
  static List<InternetAddress> pickAdvertisable(
      Iterable<(String, List<InternetAddress>)> ifaces) {
    // iOS/macOS: en*(Wi-Fi·유선), Android: wlan*(Wi-Fi), eth*(유선),
    // ap*/swlan*(핫스팟). 셀룰러: pdp_ip*(iOS), rmnet*/ccmni*(Android).
    // 터널/VPN: utun*/tun*/tap*/ipsec* — 피어가 같은 터널에 있을 리 없다.
    bool preferred(String n) =>
        n.startsWith('en') ||
        n.startsWith('wlan') ||
        n.startsWith('eth') ||
        n.startsWith('ap') ||
        n.startsWith('swlan') ||
        n.startsWith('bridge');
    bool excluded(String n) =>
        n.startsWith('pdp_ip') ||
        n.startsWith('rmnet') ||
        n.startsWith('ccmni') ||
        n.startsWith('utun') ||
        n.startsWith('tun') ||
        n.startsWith('tap') ||
        n.startsWith('ipsec');
    final lan = <InternetAddress>[];
    final unknown = <InternetAddress>[];
    for (final (name, addrs) in ifaces) {
      final n = name.toLowerCase();
      if (excluded(n)) continue;
      (preferred(n) ? lan : unknown).addAll(addrs);
    }
    return [...lan, ...unknown];
  }

  @override
  Set<FastLaneKind> get capabilities => {FastLaneKind.lanSocket};

  @override
  Set<FastLaneKind> get inboundCapabilities => {FastLaneKind.lanSocket};

  @override
  Future<FastLaneInbound?> prepareOutboundHost(
          String transferIdHex, FastLaneKind kind) async =>
      null; // 송신자-호스트 모드는 네이티브 레인 전용

  @override
  Future<bool> connectToHost(
          String transferIdHex, FastLaneKind kind, Uint8List blob) async =>
      false;

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static bool _bytesEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<FastLaneInbound?> prepareInbound(
      String transferIdHex, FastLaneKind kind,
      {bool tidPreamble = false}) async {
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

    // 정확히 하나의 연결만 수락한 뒤, 수신 대기를 멈춘다. 대기 창은 플랫폼
    // 레인(25초)과 정렬 — 예전 8초는 ACCEPT가 혼잡한 BLE(멀티홉)를 건너는
    // 동안 리스너가 먼저 닫혀, 송신자가 도착해 보면 아무도 없는 꼴이었다.
    final completer = Completer<FastLaneSession?>();
    late final StreamSubscription sub;
    final timeout = Timer(const Duration(seconds: 22), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        sub.cancel();
        server.close();
      }
    });
    final expected = tidPreamble ? _hexToBytes(transferIdHex) : null;
    // 검증 통과(또는 프리앰블 미사용) 소켓을 세션으로 채택하고 대기를 접는다.
    void adopt(FastLaneSession session) {
      timeout.cancel();
      sub.cancel();
      server.close();
      completer.complete(session);
    }

    sub = server.listen((socket) {
      if (completer.isCompleted) {
        socket.destroy();
        return;
      }
      if (expected == null) {
        adopt(SocketFastLaneSession(socket));
        return;
      }
      // 프리앰블 검증: 첫 16바이트가 transferId와 일치하는 연결만 세션으로
      // 인정한다. 불일치(같은 LAN의 포트 스캔, 엉뚱한 다이얼)는 끊고 진짜
      // 송신자를 계속 기다린다 — 예전 첫-연결 무조건 수락은 낯선 접속 하나가
      // 전송 전체를 BLE로 밀어냈다.
      final buf = BytesBuilder();
      var validated = false;
      final ctrl = StreamController<Uint8List>();
      late StreamSubscription<Uint8List> s;
      final guard = Timer(const Duration(seconds: 4), () {
        if (!validated) {
          s.cancel();
          socket.destroy();
        }
      });
      s = socket.listen((d) {
        if (validated) {
          ctrl.add(d);
          return;
        }
        buf.add(d);
        if (buf.length < 16) return;
        final all = buf.takeBytes();
        guard.cancel();
        if (!_bytesEq(Uint8List.sublistView(all, 0, 16), expected) ||
            completer.isCompleted) {
          s.cancel();
          socket.destroy();
          return;
        }
        validated = true;
        if (all.length > 16) ctrl.add(Uint8List.sublistView(all, 16));
        adopt(SocketFastLaneSession(socket, incoming: ctrl.stream));
      }, onError: (_) {
        guard.cancel();
        if (!ctrl.isClosed) ctrl.close();
      }, onDone: () {
        guard.cancel();
        if (!ctrl.isClosed) ctrl.close();
      });
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
      return SocketFastLaneSession(socket);
    } catch (_) {
      return null; // 도달할 수 없음 → BLE 폴백
    }
  }
}

/// TCP 소켓 위의 FastLaneSession. lanSocket 레인과 iOS의 Wi-Fi Direct
/// 클라이언트 경로(조인 후 그룹 오너로 다이얼)가 공유한다.
class SocketFastLaneSession implements FastLaneSession {
  final Socket _socket;

  /// 프리앰블 검증이 소켓 스트림을 이미 구독한 경우, 나머지 바이트가 흐르는
  /// 대체 스트림(단일 구독인 Socket은 재구독이 불가능하다).
  final Stream<Uint8List>? _incoming;
  bool _closed = false;
  SocketFastLaneSession(this._socket, {Stream<Uint8List>? incoming})
      : _incoming = incoming;

  @override
  Stream<Uint8List> get incoming =>
      _incoming ?? _socket; // Socket은 Stream<Uint8List>이다

  @override
  Future<void> add(Uint8List data) async {
    _socket.add(data);
    // flush를 기다려 OS 소켓 버퍼에 실제로 흘러간 뒤 다음 세그먼트를 읽는다 —
    // 느린 링크에서 파일 전체가 dart:io 내부 큐에 쌓이는 것을 막는다.
    await _socket.flush();
  }

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
