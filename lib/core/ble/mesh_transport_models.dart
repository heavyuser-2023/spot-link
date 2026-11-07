import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../model/peer_id.dart';
import 'ble_constants.dart';
import 'framing.dart';
import 'radio_health.dart';

/// 주어진 링크에서 이 노드가 GATT central로 동작하는지 peripheral로 동작하는지.
enum LinkRole { central, peripheral }

/// 하나의 BLE 연결 위에서 한 이웃과 맺는 논리적 양방향 링크.
class MeshLink {
  final String id;
  final LinkRole role;

  /// advertisement(central 역할)이나 ANNOUNCE에서 알아낸 short id.
  PeerId? remoteShortId;

  /// 이 링크로 패킷이 마지막으로 도착한 시각. peripheral 역할 링크는 모든
  /// 스택에서 신뢰할 만한 disconnect 콜백을 받지 못한다 — ANNOUNCE
  /// heartbeat를 몇 분 넘도록 조용한 링크는 좀비이며 제거된다.
  DateTime lastActivity = DateTime.now();

  /// 이 링크로 수신한 패킷 수. 0인 채 12초가 지나면 신생 좀비(link up은
  /// 됐지만 ATT 트래픽이 전혀 흐르지 않는 반쯤 죽은 연결)로 판정한다.
  int rxPackets = 0;

  int maxPacketSize;
  final L2Reassembler reassembler = L2Reassembler();

  // central 역할 핸들(우리가 원격 peripheral에 연결한 경우).
  final Peripheral? peripheral;
  final GATTCharacteristic? remoteTx; // 여기에 write 한다
  final GATTCharacteristic? remoteRx; // 여기서 notify를 받는다
  final GATTCharacteristic? remoteBond; // 암호화 읽기 → 본딩 유도(없으면 구버전)
  final GATTCharacteristic? remoteInfo; // 신생 링크 능동 생존 확인용 read 대상

  // peripheral 역할 핸들(원격 central이 우리에게 연결한 경우).
  final Central? central;
  bool centralSubscribed = false;

  // 마지막 with-response flush 이후 write한 패킷 수(central 역할에서만).
  int txBurst = 0;

  // 링크별 GATT 비동기 작업 직렬화 큐.
  // Android BluetoothGatt는 단일 mDeviceBusy 락을 사용하므로 한 링크에서
  // writeCharacteristic, readCharacteristic, readRSSI가 동시에 호출되면
  // 즉시 IllegalStateException(!writing/!reading)이 발생해 링크가 절단된다.
  // 또한 동일 특성에 대한 동시 write는 네이티브 콜백 맵을 덮어써 10초
  // TimeoutException 절단을 유발하므로, 모든 링크별 GATT 작업을 직렬화한다.
  Future<void> _opQueue = Future<void>.value();

  Future<T> enqueueOp<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _opQueue = _opQueue.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  MeshLink({
    required this.id,
    required this.role,
    this.maxPacketSize = BleConstants.defaultMaxPacketSize,
    this.peripheral,
    this.remoteTx,
    this.remoteRx,
    this.remoteBond,
    this.remoteInfo,
    this.central,
  });

  @override
  String toString() => 'MeshLink($id ${role.name} mtu=$maxPacketSize '
      '${remoteShortId?.short ?? "?"})';
}

/// 링크에서 재조립되어 [Frame]으로 파싱될 준비가 된 패킷.
class InboundPacket {
  final MeshLink link;
  final Uint8List frameBytes;
  InboundPacket(this.link, this.frameBytes);
}

/// 올라오거나 내려가는 링크.
class LinkEvent {
  final MeshLink link;
  final bool up;
  LinkEvent(this.link, this.up);
}

/// 직접 이웃의 신호 세기 측정값으로, advertisement이나 연결된 링크의 RSSI
/// 폴링에서 얻는다. 무선이 상대가 누구인지 알 수 없을 때(예: iOS
/// advertisement에는 id가 없다) [peer]는 null이다.
class RssiSample {
  final PeerId? peer;
  final int rssi; // dBm, 보통 -30 (바로 옆) … -100 (수신 한계)
  RssiSample(this.peer, this.rssi);
}

/// 사용자에게 보여줄 진단을 위한 개략적 어댑터 상태("블루투스가 꺼짐" vs
/// "권한 없음"은 사용자가 취해야 할 조치가 다르다).
enum RadioStatus { ready, poweredOff, unauthorized, unknown }

/// [MeshNode]가 의존하는 패킷 지향 transport 계약. 실제 구현은
/// [MeshTransport]이며, 테스트는 in-memory fake를 주입한다.
abstract class MeshTransportInterface {
  Stream<InboundPacket> get inbound;
  Stream<LinkEvent> get linkEvents;
  int get linkCount;

  /// 서로 구별되는 연결된 기기 수(한 피어에 대한 양방향 C:/P: 링크를 하나로
  /// 중복 제거). 사용자에게 보여줄 개수용이며, [linkCount]는 순수 링크 총계다.
  int get peerCount;

  /// 지금 무선이 사용 가능한(또는 불가능한) 이유.
  RadioStatus get radioStatus;

  /// 링크가 없을 때 **왜 없는지**에 대한 판정. 로그·UI·자동복구의 공통 근거다.
  RadioHealth get health;

  /// 유지보수(self-heal) 틱이 마지막으로 돈 시각. **복구 장치가 살아 있는지**를
  /// 밖에서 확인하는 유일한 신호다 — null이면 아직 한 번도 돌지 않았다.
  DateTime? get lastMaintenanceTick;

  /// 유지보수 타이머를 다시 세운다(멱등). 감시자가 하트비트 정지를 발견했을 때
  /// 호출한다.
  void restartMaintenance();

  /// 무선이 사용 가능해지면(권한 허용 / 어댑터 전원 켜짐) true를, 더 이상
  /// 사용 불가능해지면 false를 내보낸다. 첫 start가 실패해도 재시도할 수
  /// 있도록, [start] 이전에 listen이 가능해야 한다.
  Stream<bool> get availabilityChanged;

  /// 직접 이웃의 신호 세기 측정값 (드러난 거리감의 원천).
  Stream<RssiSample> get rssiSamples;

  Future<bool> ensureReady();
  Future<void> start();
  Future<void> stop();

  /// 무선을 다시 능동적인 discovery/advertising 상태로 되돌린다(예: 앱이 막
  /// 포그라운드로 복귀함). 이미 실행 중이면 no-op.
  void wake();

  /// 앱의 포그라운드 여부를 알린다 — 스캔 필터 모드를 좌우한다
  /// ([MeshTransport.setForeground]). 값이 바뀌지 않으면 no-op이어야 한다.
  ///
  /// 인터페이스에 있는 이유: 예전에는 [MeshNode]가 `is MeshTransport` 캐스트로만
  /// 호출해서 페이크 전송이 이 호출을 아예 관측할 수 없었고, 그래서 "포그라운드
  /// 진입이 전송에 전달되지 않는다"는 사고를 단위 테스트가 잡을 수 없었다.
  void setForeground(bool foreground);

  Future<void> broadcast(Uint8List frameBytes, {String? exceptLinkId});
  Future<void> sendToLink(String linkId, Uint8List frameBytes);
}

/// 배터리와 응답성을 맞바꾸는 전력 프로파일. docs/ARCHITECTURE.md §12 참고.
enum PowerMode {
  /// 연속 scanning + advertising. 도달성은 최고, 소모도 최고.
  active,

  /// duty-cycle 방식 scanning([_saverScanOn] 동안 scan, [_saverScanOff] 동안 idle).
  saver,
}
