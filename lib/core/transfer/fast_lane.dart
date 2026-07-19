import 'dart:async';
import 'dart:typed_data';

/// 기기가 대용량 전송을 위해 제안할 수 있는 직접 Wi-Fi 전송의 종류.
/// 값은 와이어에서 안정적이다(협상 프레임으로 전송됨) — 추가만 허용.
enum FastLaneKind {
  wifiAware(1), // Android Wi-Fi Aware (NAN) — AP 없는 직접 연결 (네이티브)
  wifiDirect(2), // Android Wi-Fi Direct (WifiP2p) — 네이티브
  multipeer(3), // iOS/macOS MultipeerConnectivity (AWDL) — 네이티브
  lanSocket(4), // 같은 Wi-Fi(AP) 위 TCP 소켓 — 순수 Dart, 크로스플랫폼
  // 송신자-호스트 역방향 모드: 송신자(Android)가 그룹(SoftAP)+리스너를 만들고
  // 접속 정보를 HOSTINFO 프레임으로 넘기면 수신자(iOS 등)가 조인+다이얼한다.
  // Android(송신)→iPhone(수신)처럼 수신자가 AP를 만들 수 없는 조합용.
  wifiDirectHosted(5);

  final int code;
  const FastLaneKind(this.code);

  static FastLaneKind? fromCode(int c) {
    for (final k in FastLaneKind.values) {
      if (k.code == c) return k;
    }
    return null;
  }
}

/// 발신자가 직접 Wi-Fi 채널로 연결할 수 있도록 수신자가 BLE로 되돌려 주는
/// 불투명한 연결 정보. [blob]은 플랫폼별로 다르다(예: Wi-Fi Aware publish
/// 정보, SoftAP SSID+psk, 또는 MultipeerConnectivity 토큰).
class FastLaneOffer {
  final FastLaneKind kind;
  final Uint8List blob;
  const FastLaneOffer(this.kind, this.blob);
}

/// 패스트레인 위의 살아 있는 양방향 바이트 채널. 신뢰성과 순서 보장은 전송
/// 계층의 몫(TCP / OS)이므로, 메시는 암호문 전체를 하나의 길이 프리픽스가 붙은
/// blob으로 보낸다 — 청크/ACK/윈도 로직이 없다.
abstract class FastLaneSession {
  /// 피어로부터 도착하는 바이트.
  Stream<Uint8List> get incoming;

  /// 피어에게 바이트를 보낸다. 반환된 future는 데이터가 전송 계층에 실제로
  /// 넘겨진 뒤 완료된다 — 호출자가 await하면 자연스러운 백프레셔가 걸려,
  /// 대용량 파일이 플랫폼 채널/소켓 큐에 통째로 쌓이는 것을 막는다.
  Future<void> add(Uint8List data);

  /// 정중하게 전송을 끝낸다(half-close); 한 번 호출하는 것은 안전하다.
  Future<void> finishSending();

  /// 채널을 허문다(Wi-Fi 라디오를 해제한다).
  Future<void> close();
}

/// [MeshNode]에 주입되는 선택적 대용량 전송 가속기. 없을 때(기본값)는 노드가
/// 모든 것을 BLE 청킹으로 처리한다 — 따라서 이는 순수하게 선택적으로 켜는
/// 업그레이드이며, BLE는 언제나 폴백으로 사용할 수 있다.
///
/// 제어 평면(발견, 협상, 전달 ACK)은 BLE에 그대로 남고, 이 인터페이스는 파일의
/// *바이트*만 옮긴다.
abstract class FastLaneInterface {
  /// 이 기기가 **송신**(connect) 측으로 쓸 수 있는 수단(비어 있으면 ⇒ 사용
  /// 가능한 패스트레인이 없어 모든 전송이 BLE에 머문다).
  Set<FastLaneKind> get capabilities;

  /// 이 기기가 **수신**(prepareInbound) 측으로 쓸 수 있는 수단. 기본은
  /// [capabilities]와 같지만 비대칭 레인이 있다: iOS는 Android의 Wi-Fi
  /// Direct 그룹(SoftAP)에 클라이언트로 **접속(송신)** 은 되지만, AP를 만들
  /// 수 없어 **수신 호스트**는 될 수 없다.
  Set<FastLaneKind> get inboundCapabilities => capabilities;

  /// 수신자 측: 들어오는 전송 하나를 수신 대기하기 시작하고 BLE로 되돌려 보낼
  /// 연결 정보를 반환한다. 불가능하면 null을 반환한다(→ BLE). 반환된 세션은
  /// 발신자가 연결하면 완료된다.
  ///
  /// [tidPreamble]이 true면(송신자가 OFFER flags로 지원을 알린 경우) 첫
  /// 16바이트가 transferId와 일치하는 연결만 세션으로 인정한다 — 같은 LAN의
  /// 엉뚱한 접속(포트 스캔 등)이 진짜 송신자를 밀어내지 못하게 한다.
  /// 검증을 실제로 무장한 구현만 ACCEPT에 그 사실을 알린다(레인별 선택).
  Future<FastLaneInbound?> prepareInbound(
    String transferIdHex,
    FastLaneKind kind, {
    bool tidPreamble = false,
  });

  /// 발신자 측: 수신자가 BLE로 반환한 [offer]를 사용해 수신자에게 연결한다.
  /// 연결된 세션을 반환하거나, 실패 시 null을 반환한다(→ BLE 폴백).
  Future<FastLaneSession?> connect(String transferIdHex, FastLaneOffer offer);

  /// 송신자-호스트 모드([FastLaneKind.wifiDirectHosted]): 송신자가 그룹과
  /// TCP 리스너를 만들고, BLE(HOSTINFO)로 광고할 접속 정보를 반환한다.
  /// 수신자가 조인+다이얼하면 세션이 완료된다. 미지원 레인은 null.
  Future<FastLaneInbound?> prepareOutboundHost(
          String transferIdHex, FastLaneKind kind) async =>
      null;

  /// 수신자 측(송신자-호스트 모드): HOSTINFO의 접속 정보로 송신자의 그룹에
  /// 조인하고 다이얼한다. 성공하면 [prepareInbound]가 돌려준 세션 future를
  /// 완성시키고 true를 반환한다.
  Future<bool> connectToHost(
          String transferIdHex, FastLaneKind kind, Uint8List blob) async =>
      false;
}

/// 수신자 측 절반: BLE로 광고할 오퍼와, 발신자가 연결되면 세션으로 해석되는
/// (타임아웃 시 null인) future.
class FastLaneInbound {
  final FastLaneOffer offer;
  final Future<FastLaneSession?> session;
  const FastLaneInbound(this.offer, this.session);
}
