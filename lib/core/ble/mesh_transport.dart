import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart' show MethodChannel;

import '../model/peer_id.dart';
import 'ble_constants.dart';
import 'framing.dart';

/// BLE 진단 로깅: 디버그 빌드에서는 항상 켜져 있고, 릴리스에서는
/// `flutter build ios --release --dart-define=BLE_LOG=true` 로 켠다.
const bool _logBle = kDebugMode || bool.fromEnvironment('BLE_LOG');

/// 진단용: iOS에서도 UNFILTERED로 scan한다(포그라운드 전용 빌드). "스캐너가
/// 죽었다"(아무것도 못 봄)와 "피어의 advertisement에 우리 UUID가 없다"(세상은
/// 다 보이는데 그 피어만 안 보임)를 구분해준다. 절대 켠 채로 출시하지 말 것 —
/// iOS 백그라운드 scan은 service-UUID 필터가 필요하다.
const bool _diagUnfilteredScan = bool.fromEnvironment('DIAG_UNFILTERED');

/// BLE 진단을 위한 선택적 추가 sink(예: 앱 계층이 연결한 파일 로거). iOS의
/// 릴리스 빌드는 콘솔 출력을 버리므로, 디버거 없이 실기기에서 BLE 동작을
/// 진단할 수 있는 유일한 수단이다.
void Function(String line)? bleLogSink;

/// 알려진 피어의 peripheral 식별자를 저장하는 영속화 계층으로, 앱 계층이
/// 연결한다(작은 JSON 파일). 새로 실행되는 경우 — iOS의 상태 복원(state
/// restoration) 재실행 포함 — scan 없이도 알려진 피어에 대한 pending connect를
/// 다시 걸 수 있게 해준다.
Future<List<String>> Function()? knownPeersLoad;
void Function(List<String> uuids)? knownPeersSave;

void _log(String msg) {
  if (_logBle) debugPrint(msg);
  bleLogSink?.call(msg);
}

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

  int maxPacketSize;
  final L2Reassembler reassembler = L2Reassembler();

  // central 역할 핸들(우리가 원격 peripheral에 연결한 경우).
  final Peripheral? peripheral;
  final GATTCharacteristic? remoteTx; // 여기에 write 한다
  final GATTCharacteristic? remoteRx; // 여기서 notify를 받는다

  // peripheral 역할 핸들(원격 central이 우리에게 연결한 경우).
  final Central? central;
  bool centralSubscribed = false;

  // 마지막 with-response flush 이후 write한 패킷 수(central 역할에서만).
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

/// [MeshNode]가 의존하는 패킷 지향 transport 계약. 실제 구현은
/// [MeshTransport]이며, 테스트는 in-memory fake를 주입한다.
/// 사용자에게 보여줄 진단을 위한 개략적 어댑터 상태("블루투스가 꺼짐" vs
/// "권한 없음"은 사용자가 취해야 할 조치가 다르다).
enum RadioStatus { ready, poweredOff, unauthorized, unknown }

abstract class MeshTransportInterface {
  Stream<InboundPacket> get inbound;
  Stream<LinkEvent> get linkEvents;
  int get linkCount;

  /// 서로 구별되는 연결된 기기 수(한 피어에 대한 양방향 C:/P: 링크를 하나로
  /// 중복 제거). 사용자에게 보여줄 개수용이며, [linkCount]는 순수 링크 총계다.
  int get peerCount;

  /// 지금 무선이 사용 가능한(또는 불가능한) 이유.
  RadioStatus get radioStatus;

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

  Future<void> broadcast(Uint8List frameBytes, {String? exceptLinkId});
  Future<void> sendToLink(String linkId, Uint8List frameBytes);
}

/// BLE central & peripheral 매니저를 하나의 mesh transport로 이어준다:
/// 이웃을 discover하고, 이웃마다 하나의 링크를 관리하며(역할은 id 비교로
/// 결정), 패킷 지향 send/receive API를 노출한다.
///
/// 상위 계층인 [MeshNode]가 그 위에 얹혀 BLE를 직접 건드리지 않는다.
/// 배터리와 응답성을 맞바꾸는 전력 프로파일. docs/ARCHITECTURE.md §12 참고.
enum PowerMode {
  /// 연속 scanning + advertising. 도달성은 최고, 소모도 최고.
  active,

  /// duty-cycle 방식 scanning([_saverScanOn] 동안 scan, [_saverScanOff] 동안 idle).
  saver,
}

class MeshTransport implements MeshTransportInterface {
  final PeerId myShortId;

  /// INFO characteristic으로 노출할 전체 공개 번들.
  final Uint8List infoValue;

  /// 배터리/메모리를 제한하기 위한 동시 링크 상한. 슬롯이 빌 때까지 초과된
  /// 피어는 무시된다.
  final int maxLinks;

  PowerMode _powerMode = PowerMode.active;
  Timer? _dutyTimer;
  bool _scanning = false;

  /// Android: scan과 connect는 하나의 무선을 공유하며, (LOW_LATENCY) scan이
  /// 도는 동안 connectGatt를 호출하는 것이 삼성에서 `status 133` connect
  /// 실패를 일으키는 전형적 원인이다 — BLE가 붐비는 방에서는 모든 dial이
  /// 실패해 mesh가 결코 링크되지 않았다. 그래서 각 connect handshake 동안
  /// scan을 일시정지한다. [_connectDepth]는 동시 connect를 refcount하고,
  /// [_scanPausedForConnect]는 [_startScanning]을 no-op으로 만들어 self-heal /
  /// duty-cycle 타이머가 connect 도중 scan을 재시작하지 못하게 한다.
  int _connectDepth = 0;
  bool _scanPausedForConnect = false;

  static const Duration _saverScanOn = Duration(seconds: 6);
  static const Duration _saverScanOff = Duration(seconds: 20);

  /// iOS 포그라운드 scan 모드 교대. unfiltered scan은 iOS 27에서
  /// 포그라운드 상태의 iPhone을 찾을 수 있는 유일한 모드지만(see
  /// [_startScanning]), 백그라운드 상태의 iPhone은 전혀 볼 수 없다 —
  /// overflow 영역의 advertisement은 service UUID로 필터링된 scan에만
  /// 전달된다. 어느 모드도 둘 다 커버하지 못하므로 번갈아 쓴다: 포그라운드
  /// 피어/Android용 wide window, 백그라운드 iPhone용 짧은 filtered window
  /// (이 iPhone은 주소가 rotate되어 재실행 후에는 걸려 있던 pending-reconnect가
  /// 모두 낡아버리므로 — 새로 discovery하는 것만이 다시 붙는 유일한 길이다).
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

  /// central 링크별 연속 RSSI read 실패 횟수 — 좀비 링크 탐지기의 근거.
  /// 성공한 read나 teardown이 있으면 리셋된다.
  final Map<String, int> _rssiFails = {};
  static const int _staleRssiFailures = 3;

  /// 최근에 링크된 피어의 peripheral 식별자들로, 가장 최근 것이 뒤에 온다.
  /// [knownPeersLoad]/[knownPeersSave]로 영속화되어, 새로 실행되는 경우(iOS의
  /// 상태 복원 재실행 포함) scan 없이도 알려진 모든 피어에 대한 pending
  /// connect를 다시 걸 수 있다 — 백그라운드 피어의 overflow advertisement은
  /// scan에는 보이지 않지만, 식별자로 하는 connect는 동작한다.
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

  /// 어떤 known-peer id를 pending reconnect로 걸지 결정한다. 가장 최근 것부터
  /// (MOST-RECENT FIRST), [_maxPendingReconnects]로 상한을 둔다([budget]으로
  /// 추가 제한).
  ///
  /// [saved]는 오래된 것→최신 순이다(see [_rememberPeer]). 이 상한이 중요하다:
  /// 상한이 없으면 알려진 모든 피어를 거는 순간 pending 집합이 넘치고,
  /// [_pendingReconnect]가 가장 먼저 ARM된 항목을 밀어낸다 — 최신 것부터
  /// 거는 방식이라 그게 바로 가장 신선한 피어다. 그 결과 방금 링크했던
  /// 피어가 낡은 옛 id들에 밀려 버려지고, 실제로 성공할 수 있는 유일한
  /// connect-by-identifier가 ARM되지 못한 채 남았다. iOS 27은 백그라운드
  /// 피어를 scan으로 재발견할 수 없으므로, 이 pending connect가 유일한
  /// reconnect 경로다 — 반드시 가장 신선한 id를 겨냥해야 한다. 테스트 용이성을
  /// 위해 순수 함수 + static이다.
  static List<String> pendingReconnectOrder(List<String> saved, int budget) {
    final cap = budget < _maxPendingReconnects ? budget : _maxPendingReconnects;
    if (cap <= 0) return const [];
    return saved.reversed.take(cap).toList();
  }

  /// iOS: 영속화된 모든 피어에 대해 pending connect를 세워 둔다. 걸려 있는
  /// connect들이 scan으로 생기는 링크의 [maxLinks] 슬롯을 굶기지 않도록
  /// 상한을 둔다.
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
        } catch (_) {} // 형식이 잘못됐거나 알 수 없는 id — 대신 scan이 찾아준다
      }
      if (armed > 0) _log('BLE known-peer reconnect armed x$armed');
    } catch (_) {}
  }

  /// 걸려 있는 pending-reconnect 키들([_connecting]의 부분집합)과 그
  /// peripheral들. iOS의 pending connect는 절대 타임아웃되지 않고, Android
  /// 피어는 재시작할 때마다 advertising 주소를 rotate한다 — 그래서 죽은
  /// 주소로 향한 pending들이 그냥 두면 영원히 쌓여, [maxLinks] 슬롯 예산을
  /// 잡아먹고, 새로운 discovery를 전부 조용히 막아버린다(관찰됨: Android
  /// 피어를 죽이자 *다른* iPhone까지 오프라인이 됐다). discovery 예산에서
  /// 빼두고, 상한을 두며, 가장 오래된 것을 밀어낸다.
  final Set<String> _pendingKeys = {};
  final Map<String, Peripheral> _pendingPeripherals = {};
  static const int _maxPendingReconnects = 4;

  /// pending별 낡음 감시 watchdog + strike 카운터. [_pendingStaleTimeout] 안에
  /// 링크를 만들어내지 못한 pending connect는 거의 확실히 rotate된/죽은
  /// 식별자를 겨냥한 것이다(범위 안의 피어라면 몇 초 만에 링크된다). 매번
  /// 슬롯을 풀어주고, 연속 두 번 strike가 쌓이면 식별자를 잊어버려
  /// deep-heal/부팅이 그것을 되살리지 못하게 한다 — 피어의 살아 있는 주소는
  /// 다음에 나타날 때 scan이 여전히 찾아준다. 이것이 누수 수정이다: 이전에는
  /// 식별자가 오직 `illegalArgument` throw에서만 버려졌지만, 흔한 경우는
  /// connect가 그냥 절대 완료되지도, throw하지도 않는 상황이다.
  final Map<String, Timer> _pendingTimers = {};
  final Map<String, int> _pendingStaleStrikes = {};
  static const Duration _pendingStaleTimeout = Duration(seconds: 90);

  /// peripheral별 (재)connect 실패 횟수로, retry backoff를 이끈다.
  /// iOS에서 pending reconnect는 일회성이다: 한번 완료되고 우리의 GATT
  /// 셋업이 실패하면(예: 바로 그 순간 피어가 자기 service를 republish하고
  /// 있었음), 아무도 그걸 다시 걸어주지 않는다 — 그래서 우리가 걸어야 한다.
  /// 그렇지 않으면 노드는 OS가 자기를 suspend시킬 때까지 링크 없이 앉아
  /// 있고 메시지 흐름이 완전히 멈춘다.
  final Map<String, int> _reconnectAttempts = {};
  final Map<String, Timer> _reconnectTimers = {};

  /// 키별로 discovery가 촉발한 마지막 dial 시각 — scan 폭주가 실패 폭풍이
  /// 되는 것을 막되, 긴 백그라운드 backoff가 지금 당장 advertising 중인
  /// 피어를 억누르지는 않게 하는 짧은 쿨다운.
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

  // 로컬의 mutable RX characteristic(peripheral 역할이 여기에 notify한다).
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

  /// 서로 구별되는 연결된 기기(DEVICES) 수. 양방향으로 링크된 피어는 같은
  /// 내부 id를 가진 두 항목(`C:<id>` outbound + `P:<id>` inbound)을 가지므로,
  /// 2글자 `C:`/`P:` 접두사를 떼고 중복 제거하면 링크 둘이 아니라 기기 하나로
  /// 센다. 사용자에게 보여줄 chip을 구동하며, 내부 로직은 계속 [linkCount]를
  /// 쓴다.
  @override
  int get peerCount => distinctPeerCount(_links.keys);

  /// 링크 키(`C:<id>`/`P:<id>`)를 서로 구별되는 기기 id로 순수하게 중복
  /// 제거한다. 테스트 용이성을 위해 static + 순수 함수다.
  static int distinctPeerCount(Iterable<String> linkKeys) =>
      linkKeys.map((k) => k.substring(2)).toSet().length;

  /// iOS에서는 맨 처음 실행 시 권한 프롬프트가 아직 화면에 떠 있는 동안
  /// `unauthorized`/`unknown`을 보고한다; 사용자가 허용하면 상태가
  /// `poweredOn`으로 바뀌고 이것이 true를 내보낸다.
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

  /// 권한과 전원 상태를 요청한다; BLE가 사용 가능하면 true를 반환한다.
  @override
  Future<bool> ensureReady() async {
    // 어댑터가 이미 powered-on을 보고하면 권한이 허용됐고 무선이 켜진
    // 것이다 — 대화형 authorize()를 건너뛴다. 이는 Android의 HEADLESS 서비스
    // isolate에 필수적이다: 거기서 authorize()는 존재하지 않는 Activity에서
    // requestPermissions()를 호출해 실패하는데, 그러면 mesh가 아예 시작되지
    // 못한다. 권한은 이전 UI 세션에서 이미 허용됐으므로 상태 확인(Context
    // 기반, Activity 불필요)만으로 충분하다. 덤으로 UI에 불필요한 프롬프트도
    // 뜨지 않게 해준다.
    if (_central.state == BluetoothLowEnergyState.poweredOn) {
      _log('BLE ensureReady: already powered on');
      return true;
    }
    try {
      final a = await _central.authorize();
      final b = await _peripheral.authorize();
      return a && b;
    } on UnsupportedError {
      // authorize()는 Darwin/데스크톱에서 지원되지 않는다: 캐시된 어댑터
      // 상태(OS의 stateChanged 이벤트로 갱신됨)로 대체한다.
      _log('BLE ensureReady: state=${_central.state}');
      return _central.state == BluetoothLowEnergyState.poweredOn;
    } catch (e) {
      // headless isolate의 Android: authorize()가 throw한다(Activity 없음).
      // Context 기반 상태가 말하는 대로 대체한다.
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
    // peripheral 매니저는 central과 독립적으로 전원이 켜진다(iOS에서는 흔히
    // 한 박자 늦다). 아직 준비되지 않은 매니저에서 service를 publish하거나
    // advertising하면 조용히 실패해, 이 노드는 scan은 하지만 다른 누구에게도
    // 보이지 않게 된다 — 그래서 준비됐을 때만 하고, 그렇지 않으면
    // stateChanged 리스너가 넘겨받게 한다.
    if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
      await _setupPeripheral();
      // 부팅 시에는 항상 advertisement을 교체(REPLACE)한다. iOS가 앱을 죽인
      // 뒤 상태 복원이 우리 대신 격이 낮은 background-class advertisement을
      // 살려두는데; 그냥 start하면 "already started"를 반환해 우리는 그 유령
      // 위에서 계속 도는 셈이 된다 — 그것은 (iOS 27) 다른 iPhone의 filtered
      // scan에 전혀 보이지 않는다. 이 상태의 두 폰은 한쪽이 재설치할 때까지
      // 서로 보이지 않는다(몇 시간 동안 관찰됨).
      // Android에서는 새 엔진에 이전 advertisement이 없으므로, 이 추가 stop은
      // no-op이다 — 부팅 시 주소 rotation을 걱정할 필요가 없다.
      await _startAdvertising(restart: true);
    }
    await _startScanning();
    _beginScanModeCycle();
    // iOS: 이전에 링크했던 모든 피어에 대해서도 pending connect를 세워 둔다 —
    // 백그라운드 iPhone은 scan에는 보이지 않지만 식별자로 하는 connect로는
    // 도달 가능하고, 상태 복원 재실행 후에는 이것이 mesh를 다시 꿰매준다.
    if (Platform.isIOS) {
      unawaited(_reconnectKnownPeers());
    }
    // 연결된 링크의 신호 세기를 폴링해, advertisement이 멈춘 뒤에도 UI가 각
    // 이웃이 얼마나 가까운지 보여줄 수 있게 한다(연결된 피어는 보통
    // advertising을 멈춘다).
    _rssiTimer = Timer.periodic(_rssiPollInterval, (_) => _pollRssi());
    // Self-heal: 경쟁 상태 도중 실패한 start(엔진 handoff, 어댑터 바쁨)는
    // 노드를 실행 중이지만 벙어리 상태로 남겨두곤 했다. 링크가 하나도 없는
    // 동안, advertising + scanning을 주기적으로 다시 확립한다 — 두 호출 모두
    // 멱등이다("already started"는 무해하다).
    _selfHealTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_started) return;
      // 좀비 peripheral 링크: 어떤 스택도 모든 곳에서 신뢰할 만한 "central
      // 이 떠남" 콜백을 쏘지 않으며, 죽은 P-링크는 UI에 거짓말을 하는 동시에
      // 새로 들어오는 연결에 대해 GATT 서버를 막아버릴 수 있다(삼성에서
      // 관찰됨: 낡은 링크가 남아 있는 동안 새 central들이 CBError 6으로
      // 타임아웃난다). ANNOUNCE heartbeat은 약 15초마다 도착하므로, 몇 분간의
      // 침묵은 central이 떠났다는 뜻이다.
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
      // Deep heal: 약 3분 연속 링크 없음 → GATT service도 republish한다.
      // 막히거나 낡은 서버(엔진 handoff 잔여물)는 들어오는 모든 connect를
      // 타임아웃나게 만든다; removeAll+add로 스택에 새 것을 준다.
      // 가벼운 heal(advertise/scan 재가동)은 15초 tick마다; 더 무거운 GATT
      // republish는 약 2분마다만 해서 connect 중인 피어를 방해하지 않게 한다.
      final deep = _linklessTicks % 8 == 0;
      if (deep && _pendingKeys.isNotEmpty) {
        // 걸려 있는 pending들이 있는데도 몇 분간 링크 없음: 그것들은 죽은
        // rotate된 주소를 겨냥하고 있을 가능성이 높다. 전부 취소한다 —
        // 대신 scan/probe가 피어들의 살아 있는 주소를 찾아준다.
        _log('BLE deep heal: cancelling ${_pendingKeys.length} stale '
            'pending reconnects');
        for (final k in _pendingKeys.toList()) {
          final p = _pendingPeripherals[k];
          if (p != null) {
            unawaited(_central.disconnect(p).then((_) {}, onError: (_) {}));
          }
        }
        // 취소가 정리되고 나면 영속화된 목록에서 다시 건다. 취소만 해두면
        // 노드에 걸려 있는 connect가 전혀 없는 상태가 됐다 — 피어가 예전
        // 식별자로 돌아온다면(백그라운드, 같은 세션) 더 이상 그것을 기다리는
        // 게 아무것도 없었던 것이다.
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
        // 그냥 다시 확립하지 말고 재활용(recycle)한다: 우리의 _scanning
        // 플래그가 true로 남아 있는 동안 OS가 조용히 scan 결과 전달을 멈출 수
        // 있다(iOS에서 긴 포그라운드 세션 후 관찰됨 — 새로 뜬 앱이 기존 앱은
        // 눈멀어 있던 피어들을 즉시 discover했다). stop→start가 진짜 새 scan을
        // 강제한다.
        unawaited(_stopScanning().then((_) => _startScanning()));
      }
      // 아무것도 없을 때는 이전에 miss했던 Apple 기기를 더 빨리 다시 probe할
      // 수 있게 한다.
      if (_linklessTicks >= 4) {
        _probeMisses.clear();
        _probeBackoff.clear();
      }
    });
  }

  @override
  void wake() {
    if (!_started) return;
    // advertising과 scanning을 다시 확립한다. iOS는 앱이 백그라운드인 동안
    // 둘 다 suspend한다; 복귀 시 이것이 다음 duty cycle을 기다리지 않고 다시
    // 우리를 보이게/discover하게 만든다. 여기서 GATT service를 republish하지
    // 말 것: removeAll+add는 잠깐 service를 허물고, 그 창(window) 사이에
    // discoverGATT를 돌리는 피어는 "service not found"를 보고 (재)connect에
    // 실패한다. service는 포그라운드/백그라운드를 견뎌낸다 — peripheral 전원이
    // 켜질 때마다 한 번만 publish하면 된다.
    if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
      if (_servicePublished) {
        // 진짜 재시작: iOS advertising은 백그라운드인 동안 격이 떨어지며,
        // stop+start만이 완전한 포그라운드 advertisement을 복원한다.
        unawaited(_startAdvertising(restart: true));
      } else {
        unawaited(
            _setupPeripheral().then((_) => _startAdvertising(restart: true)));
      }
    }
    if (_powerMode == PowerMode.active) {
      _beginScanModeCycle(); // (재)scan 전에 wide phase로 리셋
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
        // 반쯤 죽은 GATT 연결(suspend 도중 피어가 떠남, 스택 막힘)은
        // disconnect를 전혀 보고하지 않은 채 몇 분간 프레임을 삼킬 수 있다.
        // 연속 세 번의 read 실패 ≈ 15초의 침묵 — 우리가 직접 링크를 끊는다;
        // disconnect 경로가 pending reconnect를 다시 걸어준다.
        final fails = (_rssiFails[link.id] ?? 0) + 1;
        _rssiFails[link.id] = fails;
        if (fails >= _staleRssiFailures) {
          _log('BLE link stale ($fails failed RSSI reads) — cutting ${link.id}');
          _rssiFails.remove(link.id);
          try {
            await _central.disconnect(link.peripheral!);
          } catch (_) {
            // 무선이 disconnect마저 거부했다 — 로컬에서 teardown하고
            // reconnect를 직접 손으로 건다(disconnect 이벤트는 오지 않는다).
            _tearDown(link.id);
            _pendingReconnect(link.peripheral!);
          }
        }
      }
    }
  }

  /// 사용자가 블루투스를 껐다 다시 켤 때 자동으로 복구한다: 전원이 켜지면
  /// service를 다시 publish하고 다시 advertise/scan하며; 전원이 꺼지면 낡은
  /// 링크를 버린다.
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
        // saver duty-cycle 체인을 멈춘다. 그러지 않으면 _scanning을 계속
        // 뒤집으며 죽은 어댑터에 대고 실패가 뻔한 startDiscovery 호출을
        // 계속 날린다.
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

    // peripheral 매니저 자체의 전원이 켜졌을 때만 GATT service를 publish하고
    // advertise한다 — 그 생명주기는 central의 것과 별개다.
    _subs.add(_peripheral.stateChanged.listen((e) async {
      _log('BLE peripheral state: ${e.state}');
      if (!_started) return;
      if (e.state == BluetoothLowEnergyState.poweredOn) {
        await _setupPeripheral();
        // start()에서와 같은 유령 교체(ghost-replacement): peripheral 매니저의
        // 전원이 늦게 켜질 때(iOS 상태 복원)의 부팅 경로다.
        await _startAdvertising(restart: true);
      } else {
        // 전원 off는 publish된 GATT 데이터베이스를 지운다.
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
  // 전송
  // ---------------------------------------------------------------------------

  /// 인코딩된 프레임을 [exceptLinkId]를 제외한 현재의 모든 이웃에게 보낸다.
  @override
  Future<void> broadcast(Uint8List frameBytes, {String? exceptLinkId}) async {
    final targets = _links.values.where((l) => l.id != exceptLinkId).toList();
    // 링크별 전송은 동시에(CONCURRENTLY) 돈다: withResponse flush가 기어가는
    // 아슬아슬한 원거리 링크 하나가 다른 모든 이웃으로의 전달을 막아서는 안
    // 된다(직렬로 하면 느린 hop 하나가 relay fan-out 전체를 지연시켰다).
    // _sendTo는 절대 throw하지 않는다 — 실패는 각자 자신의 링크를 teardown한다.
    await Future.wait(targets.map((link) => _sendTo(link, frameBytes)));
  }

  /// 인코딩된 프레임을 단일 링크로 보낸다.
  @override
  Future<void> sendToLink(String linkId, Uint8List frameBytes) async {
    final link = _links[linkId];
    if (link != null) await _sendTo(link, frameBytes);
  }

  Future<void> _sendTo(MeshLink link, Uint8List frameBytes) async {
    // 너무 작거나 아직 협상 중인 MTU가 잘못된 split을 만들지 못하게 한다.
    final size = link.maxPacketSize < BleConstants.minUsablePacketSize
        ? BleConstants.minUsablePacketSize
        : link.maxPacketSize;
    final List<Uint8List> packets;
    try {
      packets = L2Framing.split(frameBytes, size);
    } catch (_) {
      return; // 이 링크에서 framing하기엔 프레임이 너무 큼
    }
    for (final p in packets) {
      try {
        if (link.role == LinkRole.central) {
          // iOS는 큐가 차면 write-without-response 패킷을 조용히 버린다
          // (플러그인이 readiness를 확인하지 않고 즉시 완료 처리한다). 그래서
          // 긴 파일 청크 폭주가 증발해버린다. 그래서 몇 패킷마다 한 번씩
          // response를 받는(WITH response) write를 한다: ATT 왕복이 다음으로
          // 넘어가기 전에 큐를 비워준다.
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
        // write 실패는 보통 링크가 죽었다는 뜻이다; teardown한다.
        _tearDown(link.id);
        return;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // peripheral 역할 셋업
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

  /// 어느 스택에서든 나오는 "Already advertising" — advertisement이 살아
  /// 있다는 뜻이고, 그것이 바로 재확립(re-assert)이 원하는 것이므로; 성공으로
  /// 취급한다.
  /// (Darwin에서는 "Advertising has already started"; Android에서는 error code 3 =
  /// ADVERTISE_FAILED_ALREADY_STARTED.)
  static bool _isAlreadyAdvertising(Object e) {
    final s = e.toString();
    return s.contains('already started') || s.contains('error code: 3');
  }

  Future<void> _startAdvertising({bool restart = false}) async {
    // 재시작은 오직 명시적 요청일 때만(포그라운드 wake, GATT republish).
    // Android에서 stop+start는 무해한 refresh가 아니다: start할 때마다 새
    // 랜덤 주소(RPA)를 할당하고, 링크 없음 self-heal은 15초마다 재확립한다 —
    // 매번 재시작하면 이 노드가 *백그라운드* 상태의 iPhone이 dial을 끝낼 수
    // 있는 것보다 더 빠르게 주소를 갈아치우게 되고(백그라운드
    // discovery→connect는 매번 15초 경쟁에서 진다), 그래서 idle 상태의 두 폰은
    // 한쪽이 포그라운드로 오기 전까지 결코 다시 링크할 수 없었다. 기본 경로는
    // 살아 있는 advertisement을 건드리지 않고 둔다.
    if (restart) {
      try {
        await _peripheral.stopAdvertising();
      } catch (_) {}
    }
    // NAME + service UUID만 advertise한다. 예전에는 short id도 manufacturer
    // data에 넣어 보냈지만, 128비트 service UUID(18B) + 이름(4B) + flags(3B)만
    // 으로 이미 레거시 31바이트 advertisement을 거의 다 채우기 때문에,
    // manufacturer data 12B가 더해지자 Android가 한계를 넘겨 모든
    // startAdvertising이 DATA_TOO_LARGE(error code 1)로 실패했다 — 그러면
    // 노드는 어차피 정확히 이 패킷으로 fallback했다. 피어는 링크가 올라오는
    // 순간 보내는 ANNOUNCE에서 우리 short id를 알게 되므로 잃는 것은 없다;
    // service UUID를 남기는 이유는 iOS 피어의 백그라운드 scan이 그것으로
    // 필터링되기 때문이며(우리를 discover하는 유일한 수단), 이름은 iOS
    // 포그라운드 discovery를 이끈다. (Darwin은 manufacturer-data advertising을
    // 지원한 적이 없다.)
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
      // 원격 central이 우리의 TX characteristic에 패킷을 write했다.
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
      // 첫 접촉 시 링크를 생성하고 link-up을 내보낸다(see _peripheralLinkFor).
      final link = _peripheralLinkFor(e.central);
      link.centralSubscribed = e.state;
      if (e.state) {
        // notification 하나당 얼마나 밀어넣을 수 있는지 알아내, peripheral
        // 역할 링크가 작은 기본 패킷 크기에 갇혀 있지 않게 한다.
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

    // Android 전용: central disconnect를 추적해 링크를 정리한다.
    try {
      _subs.add(_peripheral.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected) {
          _tearDown(_peripheralLinkId(e.central));
        }
      }));
    } on UnsupportedError {
      // iOS/macOS: peripheral 연결 콜백이 없다; 대신 링크는 write 실패로
      // 타임아웃된다.
    }
  }

  MeshLink _peripheralLinkFor(Central central) {
    final id = _peripheralLinkId(central);
    final existing = _links[id];
    if (existing != null) return existing;
    // 이 central로부터의 첫 접촉(subscribe 또는 write). link-up을 내보내
    // mesh가 자기 ANNOUNCE/HAVE를 돌려보내게 하고 — 결정적으로 — [_links]가
    // 비어 있지 않게 만들어, 링크 없음 self-heal이 GATT service를 republish하며
    // 바로 이 연결을 허물어버리는 것을 막는다("central이 붙어 있는데도 우리는
    // 링크가 없다고 여기는" 루프로, iPhone↔Android를 단방향으로 만들었던
    // 원인이다).
    final link = MeshLink(id: id, role: LinkRole.peripheral, central: central);
    _links[id] = link;
    _emitUp(link);
    return link;
  }

  String _peripheralLinkId(Central central) => 'P:${central.uuid}';

  // ---------------------------------------------------------------------------
  // central 역할 셋업
  // ---------------------------------------------------------------------------

  Future<void> _startScanning() async {
    // connect handshake가 진행 중인 동안은 미뤄둔다(Android 133 수정) —
    // connect의 finally 블록이 scanning을 재개한다.
    if (_scanPausedForConnect) return;
    if (_scanning) return;
    _scanning = true;
    try {
      // OS가 허용하는 한 언제나 UNFILTERED로 scan하고, SpotLink 여부는
      // 소프트웨어에서 매칭한다(see [_isSpotLink]):
      // - Android: 하드웨어 service-UUID 필터가 iPhone의 overflow 영역
      //   advertisement을 아예 매칭하지 못한다(Results=0).
      // - iOS 포그라운드: iOS 27(beta 24A5380h)에서는 다른 iPhone의 128비트
      //   service UUID가 필터에 매칭되지도, 파싱된 advertisement에 드러나지도
      //   않는다(관찰됨: unfiltered scan은 그 피어를 name-'SL'만 있는 패킷으로
      //   보는 반면, filtered scan은 bluetoothd에 "0 advertisements delivered"를
      //   남긴다). 거기서 iPhone 피어를 실제로 찾아내는 것은 이름 매칭이다.
      // - iOS 백그라운드: unfiltered scan은 아무것도 전달하지 않으므로(OS
      //   규칙) UUID 필터가 필요하다 — [setForeground]가 모드를 바꿔준다.
      final unfiltered = Platform.isAndroid ||
          _diagUnfilteredScan ||
          (Platform.isIOS && _foregroundScan && !_overflowPhase);
      await _central.startDiscovery(
        serviceUUIDs: unfiltered ? null : [BleConstants.serviceUuid],
      );
      _log('BLE scanning started (${unfiltered ? 'unfiltered' : 'filtered'})');
    } catch (e) {
      // 다음 시도가 실제로 재시도되도록 플래그를 내려둔다 — 실패한 start
      // 이후 여기서 "true"에 막혀 있으면(예: 어댑터가 headless 엔진과 UI 엔진
      // 사이에서 handoff 중이었음) 무선이 영원히 벙어리가 됐다.
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

  /// Android: connect handshake 동안 scan을 멈춰, 무선이 scanning과
  /// connecting으로 갈라지지 않게 한다(`status 133`의 원인). refcount 방식이라
  /// 겹치는 connect들이 한 번만 pause하고 한 번만 resume한다.
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

  /// 앱이 포그라운드인지 여부 — iOS unfiltered scan 모드의 게이트 역할.
  /// 기본값은 true(보통의 실행은 포그라운드다); 백그라운드 재실행은 start
  /// 직후 [setForeground]로 이를 false로 설정한다.
  bool _foregroundScan = true;

  /// iOS: wide 포그라운드 scan(unfiltered + 소프트웨어 매칭 — iOS 27에서 다른
  /// iPhone을 안정적으로 찾는 유일한 모드)과 filtered 백그라운드 scan(OS가
  /// 요구)을 서로 바꾼다. 항상 unfiltered로 scan하는 Android에서는 no-op.
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

  /// 런타임에 전력 프로파일을 전환한다(예: 사용자가 "배터리 절약"을 토글).
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

  /// Android scan 모드: 0=LOW_POWER, 1=BALANCED, 2=LOW_LATENCY. LOW_LATENCY
  /// (벤더 기본값)는 거의 연속으로 scan하며 단일 요소로는 가장 큰 배터리
  /// 소모원이다; BALANCED는 대략 절반의 전력으로도 여전히 몇 초 안에
  /// discover한다. 적응형 전력(see MeshController)이 등급을 고른다.
  static const _scanPowerChannel = MethodChannel('spotlink/scan_power');
  int _scanModeCode = 2;

  /// Android BLE scan 모드를 설정하고 다시 scan해 적용한다(그 외에서는 no-op).
  Future<void> setScanMode(int code) async {
    if (!Platform.isAndroid || _scanModeCode == code) return;
    _scanModeCode = code;
    try {
      await _scanPowerChannel.invokeMethod('setScanMode', code);
    } catch (_) {} // 이 채널이 없는 포크: 벤더 기본값을 유지한다
    _log('BLE scan mode -> ${const {
          0: 'low-power',
          1: 'balanced',
          2: 'low-latency'
        }[code]}');
    // 스캐너는 다음 startScan 때 새 모드를 읽으므로, 한 번 껐다 켠다.
    if (_started && _scanning) {
      await _stopScanning();
      await _startScanning();
    }
  }

  void _beginDutyCycle() {
    _dutyTimer?.cancel();
    // scan window, 그다음 idle window, 반복.
    Future<void> onTick() async {
      await _startScanning();
      _dutyTimer = Timer(_saverScanOn, () async {
        await _stopScanning();
        _dutyTimer = Timer(_saverScanOff, onTick);
      });
    }

    onTick();
  }

  /// iOS 포그라운드 scan 모드 교대를 wide window로 시작하며 (재)시작한다.
  /// See [_scanModeTimer]. iOS/포그라운드/active가 아니면 no-op(saver duty
  /// cycle과 백그라운드 filtered scan이 나머지를 커버한다).
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
        // iOS: 두 앱이 모두 백그라운드면 scan 기반 재발견은 눈이 먼다 —
        // 백그라운드 peripheral의 advertisement은 overflow 영역으로 옮겨가고,
        // 그건 *포그라운드* 스캐너만 볼 수 있다. 하지만 알려진 peripheral로
        // 향한 pending connect()는 절대 타임아웃되지 않고 피어가 범위 안으로
        // 돌아오는 즉시 백그라운드에서 완료되므로, 확립된 링크가 끊길 때마다
        // 하나 다시 걸어둔다.
        if (hadLink) _pendingReconnect(e.peripheral);
      }
    }));

    _subs.add(_central.characteristicNotified.listen((e) {
      if (e.characteristic.uuid != BleConstants.rxCharacteristicUuid) return;
      final link = _links['C:${e.peripheral.uuid}'];
      if (link != null) _ingest(link, e.value);
    }));
  }

  /// unfiltered Android scan은 근처의 모든 BLE 기기를 드러낸다 — peripheral이
  /// 실제로 SpotLink일 때만 받아들인다: scan 레코드에 우리 service UUID가
  /// 있거나, (UUID가 overflow 영역에 숨은 iOS 피어의 경우) 우리가 advertise한
  /// local name 'SL'이 있을 때.
  bool _isSpotLink(Advertisement adv) {
    if (adv.serviceUUIDs.contains(BleConstants.serviceUuid)) return true;
    if (adv.name == BleConstants.advertisedName) return true;
    // 일부러 manufacturer id로는 매칭하지 않는다: 우리 것은 0xFFFF(예약/테스트
    // id)인데, 잡다한 기기들도 이를 내보낸다 — KT GiGA Genie 스피커가
    // 매칭되어 "SpotLink 피어"로 dial됐다(관찰됨). 진짜 SpotLink
    // advertisement은 언제나 service UUID 그리고/또는 이름을 담는다;
    // manufacturer data는 이미 매칭된 뒤의 shortId 힌트일 뿐이다.
    return false;
  }

  /// *백그라운드* 상태의 iPhone은 자기 service UUID(overflow 영역)와 local
  /// name을 둘 다 숨겨서, advertisement 어디에도 "SpotLink"라고 나오지 않는다.
  /// iOS가 숨길 수 없는 단 하나는 Apple 자체의 continuity beacon(manufacturer
  /// id 0x004C)이다. Android에서는 아주 가까운 Apple 기기에 probe-connect해서
  /// GATT discovery가 판정하게 한다: SpotLink service가 있으면 → 진짜 링크;
  /// 없으면 → miss를 기억해두고 한동안 내버려 둔다.
  static const int _appleManufacturerId = 0x004C;
  static const Duration _probeMissTtl = Duration(minutes: 10);
  final Map<String, DateTime> _probeMisses = {};

  /// probe dial이 connect에 실패한(status 133 등) 뒤의 짧은 쿨다운. 그러지
  /// 않으면 붐비는 방(AirPods/Mac/iPhone으로 가득 찬 사무실)에서는 같은
  /// 실패하는 기기를 12초마다 다시 dial하고, 실패가 뻔한 connectGatt마다
  /// 진짜 피어를 굶긴다. [_probeMisses](10분, "connect됐지만 SpotLink 아님")와는
  /// 구별된다 — 이건 짧게 유지해서, 일시적 실패를 맞은 진짜 SpotLink iPhone은
  /// 곧 재시도되게 한다.
  static const Duration _probeFailBackoff = Duration(seconds: 90);
  final Map<String, DateTime> _probeBackoff = {};

  /// 현재 진행 중인 probe dial의 키들. 상한을 두어, Apple 기기(TV, AirPods,
  /// 다른 iPhone)로 가득 찬 방이 동시 connectGatt 호출을 폭풍처럼 쏟아내
  /// Android GATT 클라이언트 풀을 고갈시키고 우리가 도달하려는 유일한 진짜
  /// 피어를 굶기지 못하게 한다.
  final Set<String> _activeProbes = {};
  static const int _maxConcurrentProbes = 1;

  bool _isIosProbeCandidate(DiscoveredEventArgs e) {
    if (!Platform.isAndroid) return false;
    if (e.rssi < -70) return false; // 가까운 기기만 dial할 가치가 있다
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
    // iOS에서는 하드웨어에서 필터링되고, Android의 unfiltered scan에서는
    // 소프트웨어에서 처리되어 잡다한 헤드폰/beacon을 절대 dial하지 않는다.
    // 아주 가까운 Apple 기기는 대신 probe dial을 받는다: 백그라운드 iPhone의
    // advertisement에는 SpotLink 표식이 전혀 없으므로(see
    // [_isIosProbeCandidate]) — GATT discovery만이 판별할 수 있는 유일한
    // 방법이다.
    final probe = !_isSpotLink(e.advertisement);
    if (probe && !_isIosProbeCandidate(e)) return;

    final remoteId = _shortIdFromAdvertisement(e.advertisement);

    // 우리 자신의 advertisement에는 절대 연결하지 않는다(일부 스택에서 발생할 수 있다).
    if (remoteId != null && remoteId == myShortId) return;

    // advertisement은 실시간 신호 세기 측정값을 담고 있다 — 이를 근접 UI로
    // 드러낸다(adv에 manufacturer id가 없으면 peer는 null이다).
    if (!_disposed) _rssiSamples.add(RssiSample(remoteId, e.rssi));

    // 여기서는 일부러 tie-break을 하지 않는다. 크로스 플랫폼 discovery는
    // 비대칭이다: iOS는 manufacturer data를 벗겨내고 128비트 service UUID를
    // Android가 자주 파싱하지 못하는 overflow 영역에 넣으므로, iOS advertiser는
    // Android에게 보이지 않을 수 있다. "우리 id가 더 크다"는 이유로 connect를
    // 건너뛰면, Android<->iOS 쌍이 아예 링크 없는 상태로 끝날 수 있다.
    // 대신 모든 노드는 자기가 discover할 수 있는 모든 SpotLink peripheral에
    // 연결한다. 중복되는 역방향 링크(예: 두 Android 기기 사이)는 무해하다:
    // 라우터가 msgId로 중복 제거하므로 무엇도 두 번 전달되지 않는다 — 그저
    // 연결 하나가 더 드는 것뿐이다. docs/ARCHITECTURE.md §11 참고.

    // 배터리/메모리 사용을 제한하기 위해 링크 상한을 지킨다. 진행 중인
    // (in-flight) 연결도 함께 센다. 그러지 않으면 discovery 폭주가 상한을 넘길
    // 수 있다(어떤 connect도 완료되기 전에는 모든 이벤트가 _links를 여전히 빈
    // 상태로 본다) — 다만 걸려 있는 pending-reconnect는 세지 않는다: 죽은 rotate된
    // 주소로 향한 pending이 살아 있는 discovery를 굶겨서는 절대 안 된다(그것이
    // 조용히 모든 피어를 오프라인으로 만들었다).
    if (_links.length + (_connecting.length - _pendingKeys.length) >=
        maxLinks) {
      return;
    }

    final key = e.peripheral.uuid.toString();
    if (_links.containsKey('C:$key') || _connecting.contains(key)) return;
    // discovery 폭주가 실패 폭풍이 되지 않도록 키별로 rate-limit한다 — 다만
    // 점점 커지는 백그라운드 backoff(최대 5분)가 이 경로를 억누르게 두지는
    // 않는다: discovery는 피어가 지금 당장 물리적으로 존재한다는 뜻이므로,
    // 짧은 쿨다운이면 충분하다. (이것이 "브리지를 죽이면 모두가 5분간 오프라인이
    // 되는" 버그였다.) 지금 당장 행동하는 것이 예약된 재시도를 대체하므로,
    // 그것을 취소한다.
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

  /// 링크된 적 있는 피어에 대해 백그라운드에서도 견디는 연결을 다시 걸어둔다.
  /// iOS 전용이다: 다른 곳에서는 (포그라운드 서비스) 스캐너가 문제없이
  /// reconnect하고, Android의 connect()는 재시도하는 동안 무선 슬롯을 막을 수
  /// 있다. pending 시도는 [_connecting] 슬롯을 하나 차지해 discovery가 이와
  /// 경쟁하지 않게 한다; 피어가 다시 나타나면 언제든 완료된다 — 몇 분 뒤여도
  /// 괜찮다.
  void _pendingReconnect(Peripheral peripheral) {
    if (!Platform.isIOS) return;
    if (_disposed || !_started) return;
    final key = peripheral.uuid.toString();
    if (_links.containsKey('C:$key') || _connecting.contains(key)) return;
    // 걸려 있는 pending들에 상한을 두고, 가장 오래된 것을 밀어낸다 — rotate된
    // (죽은) 주소가 흔한 경우이고, 가장 최신 것이 살아 있을 가능성이 가장 높다.
    while (_pendingKeys.length >= _maxPendingReconnects) {
      final oldest = _pendingKeys.first;
      _pendingKeys.remove(oldest);
      final old = _pendingPeripherals.remove(oldest);
      _log('BLE pending reconnect evicted $oldest');
      if (old != null) {
        // 취소하면 그것의 connect()가 throw하게 되고; 그러면 establishLink
        // 정리 과정이 _connecting 슬롯을 풀어준다.
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

  /// [_pendingTimers] 참고. 걸려 있는 pending connect가 링크를 만들지 못한 채
  /// [_pendingStaleTimeout]을 넘겼을 때 발동한다: 슬롯을 풀어주고, strike가 두
  /// 번 쌓이면 식별자를 잊어버려 매번의 deep-heal / 부팅에서 다시 ARM되지 않게
  /// 한다.
  void _expireStalePending(String key) {
    _pendingTimers.remove(key);
    if (_links.containsKey('C:$key')) return; // 그 사이에 연결됨
    if (!_pendingKeys.contains(key)) return; // 이미 해소됨 / 밀려남
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
      // 대기 중인 connect()를 취소한다 → 그것의 establishLink가 finally에서
      // _connecting / _pendingKeys 슬롯을 풀어준다.
      unawaited(_central.disconnect(p).then((_) {}, onError: (_) {}));
    }
  }

  /// SpotLink peripheral에 연결하고 GATT 링크를 올린다. 호출자는 [key]를
  /// [_connecting]에 추가해 두었어야 한다; 완료되면 여기서 제거된다.
  Future<void> _establishLink(Peripheral peripheral, String key,
      {PeerId? remoteId, bool probe = false}) async {
    final linkId = 'C:$key';
    var connected = false; // _central.connect가 성공했는가?
    var serviceMissing = false; // 연결됐지만 SpotLink service가 없음
    if (probe) _activeProbes.add(key);
    final pauseScan = Platform.isAndroid;
    try {
      // Android: connect 동안 scanning을 멈춰, 무선이 scan + connect로 갈라지지
      // 않게 한다(status 133). iOS는 계속 scan한다 — 그 pending reconnect는
      // 설계상 오래 사는 것이고 CoreBluetooth가 중재해준다.
      if (pauseScan) await _pauseScanForConnect();
      try {
        // 무작위 Apple 기기로 향한 probe dial이 GATT 클라이언트 슬롯을 쥔 채
        // Android의 꽉 찬 ~30초 connectGatt 타임아웃 동안 매달려 있어서는 안
        // 된다 — 그래서 상한을 둔다. Android의 non-probe connect에도 상한을 둬,
        // 막힌 dial이 scan을 영원히 일시정지된 채로 붙들지 못하게 한다; iOS의
        // non-probe connect는 상한 없이 둔다(pending reconnect는 설계상 몇 분 뒤에
        // 완료된다).
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
      // OS 레벨 connect 이후의 모든 것에는 상한이 있다: 응답 프레임 하나(discovery
      // 응답, CCCD ack)만 유실돼도 예전에는 이 await 체인이 영원히 매달렸다 —
      // _connecting 슬롯이 계속 점유된 채라, 앱을 재시작하기 전까지는 그 피어를
      // 다시 dial할 수 없었다(관찰됨: idle 상태의 두 폰이 establish 도중 서로 20분
      // 넘게 막혀 있었다). 위의 connect()는 non-probe 경로에서 일부러 상한 없이
      // 둔다 — iOS의 pending reconnect는 설계상 몇 분 뒤에 완료된다.
      final (tx, rx, maxPacket) = await () async {
        var services = await _central.discoverGATT(peripheral);
        var hasSvc = services.any((s) => s.uuid == BleConstants.serviceUuid);
        // SpotLink service가 없는 SpotLink advertiser는 거의 언제나 재실행
        // 도중인 iOS 앱이다: iOS가 백그라운드에서 앱을 죽이면, 상태 복원이 앱
        // 대신 계속 advertising하지만, GATT service는 재실행된 앱이 그것을 다시
        // publish해야만 돌아온다 — 우리의 connect(바로 그 앱을 깨우는 이벤트)
        // 몇 초 뒤에 말이다. 즉시 연결을 끊으면 앱을 곧바로 다시 suspend시켜
        // 영원히 루프를 돈다("connect → service not found → disconnect"를 15초마다,
        // 몇 시간 동안 관찰됨). 연결을 유지하면 앱에 백그라운드 실행 시간을
        // 준다: 포기하기 전에 기다렸다 다시 살펴본다.
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

      // 연결을 기다리는 동안 stop/dispose됐을 수 있다. _links를 되살리거나 닫힌
      // 컨트롤러에 emit하지 말고 — 그냥 disconnect한다.
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
      _pendingStaleStrikes.remove(key); // 링크 성립 → 식별자가 살아있음이 입증됨
      _probeMisses.remove(key);
      _probeBackoff.remove(key);
      _rememberPeer(key);
    } catch (err) {
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
      if (probe) {
        if (connected && serviceMissing) {
          // 확정적으로 SpotLink가 아님(연결됐지만 service 없음) — 이 Apple
          // 기기를 더 이상 dial하지 않도록 TTL 전체 동안 차단한다.
          _probeMisses[key] = DateTime.now();
          _log('BLE probe miss $key (not SpotLink)');
        } else {
          // connect 자체가 실패함 — 진짜 SpotLink iPhone도 일시적 타임아웃을
          // 끊임없이 만난다(CBError 6). 10분간 blocklist하지는 말되, 짧은
          // backoff를 걸어, 붐비는 방이 이 같은 기기를 12초마다 다시 dial해
          // status-133 폭풍으로 진짜 피어를 굶기지 못하게 한다.
          _probeBackoff[key] = DateTime.now();
          _log('BLE probe connect failed $key: $err (backoff ${_probeFailBackoff.inSeconds}s)');
        }
      } else {
        _log('BLE connect failed $key: $err');
        if (_isUnknownIdentifier(err)) {
          // Darwin이 illegalArgument를 throw함: 식별자가 시스템의 peripheral
          // 캐시에 없다(rotate된/잊힌 주소 — 재시작한 Android 피어의 전형적
          // 사례). 살아 있는 scan이 피어를 다시 발견하기 전까지는 어떤 재시도도
          // 결코 성공할 수 없으므로, 걸려 있는 재시도와, 실행 때마다 그것을
          // 되살리는 영속화된 식별자를 함께 버린다.
          _reconnectAttempts.remove(key);
          if (_knownPeers.remove(key)) {
            knownPeersSave?.call(_knownPeers.toList());
            _log('BLE forgetting dead peer identifier $key');
          }
        } else {
          // 일시적 실패는 일어난다(피어가 자기 GATT 데이터베이스를 다시
          // publish 중, 무선 경합). backoff를 두고 계속 시도한다 — 조용히
          // 침묵하는 SpotLink 피어는 iOS에서 걸려 있는 reconnect를 유지할 만한
          // 가치가 있다.
          _scheduleReconnect(peripheral, key);
        }
      }
    } finally {
      _connecting.remove(key);
      _pendingKeys.remove(key);
      _pendingPeripherals.remove(key);
      _pendingTimers.remove(key)?.cancel(); // 해소됨 → watchdog가 더는 필요 없음
      if (probe) {
        _activeProbes.remove(key);
        // 타임아웃된 probe(깨끗한 disconnect가 아님)는 pending connectGatt를
        // 남긴다 — GATT 클라이언트 슬롯이 풀리도록 강제로 해제한다.
        unawaited(_central.disconnect(peripheral).then((_) {}, onError: (_) {}));
      }
    }
  }

  /// Darwin의 connect()는 peripheral 식별자가 시스템 캐시에 알려져 있지 않을 때
  /// `illegalArgument`를 throw한다 — 그 식별자에 대한 영구적 실패이지, 일시적
  /// 무선 오류가 아니다. (이 파일이 flutter/services 의존성을 갖지 않도록
  /// 문자열로 매칭한다.)
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
  // 공용
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
    // 이 피어의 dial 쿨다운을 지워, 그 advertisement이 다시 나타나는 즉시 곧바로
    // 다시 dial될 수 있게 한다(linkId는 'C:<key>'이다).
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
