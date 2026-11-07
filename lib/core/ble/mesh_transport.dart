import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

import '../model/peer_id.dart';
import 'ble_constants.dart';
import 'framing.dart';
import 'mesh_transport_models.dart';
import 'radio_health.dart';
import 'radio_profile.dart';

export 'mesh_transport_models.dart';

part 'mesh_transport_maintenance.dart';
part 'mesh_transport_peripheral.dart';
part 'mesh_transport_central.dart';

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

/// 본딩된 피어의 영속화(peerHex → 마지막으로 본 peripheral 식별자).
/// 본딩된 식별자는 주소 회전으로 죽지 않으므로 2스트라이크 망각에서
/// 제외된다. [MeshTransport.ensureBonded] 참고.
Future<Map<String, String>> Function()? bondedPeersLoad;
void Function(Map<String, String> peers)? bondedPeersSave;

/// 메시 광고가 **BLE 광고 슬롯 부족**(Android
/// `ADVERTISE_FAILED_TOO_MANY_ADVERTISERS`, error code 2)으로 실패했을 때 앱
/// 계층이 웨이크 비콘 토치를 양보시키도록 거는 훅.
///
/// 왜 필요한가: 일부 Samsung 기기는 레거시 광고 인스턴스를 **하나만** 지원한다
/// (`isMultipleAdvertisementSupported() == false`). 그런 기기에서 비콘 토치가
/// 슬롯을 먼저 잡으면 메시 광고는 영영 실패하고, 그 노드는 BLE 스캔에 전혀
/// 보이지 않는다 — 그런데 토치는 계속 돌아 주변 iPhone을 깨운다. 그래서
/// "친구가 근처에 있다는 알림은 오는데 레이더엔 없고 메시지도 못 보내는"
/// 증상이 **일부 삼성 폰에서만** 나타났다(2026-10-04 신고). 발견되지 못하는
/// 노드는 아무것도 할 수 없으므로, 슬롯 경합에서는 **메시 광고가 토치보다
/// 우선**이다.
Future<void> Function()? advertiseSlotYield;

void _log(String msg) {
  if (_logBle) debugPrint(msg);
  bleLogSink?.call(msg);
}

/// BLE central & peripheral 매니저를 하나의 mesh transport로 이어준다:
/// 이웃을 discover하고, 이웃마다 하나의 링크를 관리하며(역할은 id 비교로
/// 결정), 패킷 지향 send/receive API를 노출한다.
///
/// 상위 계층인 [MeshNode]가 그 위에 얹혀 BLE를 직접 건드리지 않는다.
class MeshTransport implements MeshTransportInterface {
  final PeerId myShortId;

  /// 이 플랫폼의 무선 정책. 모든 OS별 결정은 이 객체를 거치며, 아래 메커니즘
  /// 들은 플랫폼 중립이다 — 새 플랫폼은 [RadioProfile]에 항목 하나만 추가하면
  /// 된다. 테스트는 임의 프로파일을 주입해 정책 동작을 검증한다.
  final RadioProfile profile;

  /// INFO characteristic으로 노출할 전체 공개 번들.
  final Uint8List infoValue;

  /// 배터리/메모리를 제한하기 위한 동시 링크 상한. 슬롯이 빌 때까지 초과된
  /// 피어는 무시된다.
  final int maxLinks;

  PowerMode _powerMode = PowerMode.active;
  Timer? _dutyTimer;
  bool _scanning = false;

  /// **지금 라디오에 실제로 걸려 있는** 필터(true=무필터, null=스캔 안 함).
  ///
  /// 왜 별도 필드인가: [_scanning]만으로는 "스캔 중"까지만 알 수 있어서,
  /// 모드를 바꾸려는 호출이 조용히 무시됐다. [_startScanning]이 `_scanning`
  /// 하나로 no-op을 판정했기 때문에 — `wake()`/boost·어댑터 복귀·전력 모드
  /// 전환은 모두 "wide(무필터) phase로 리셋 + _startScanning()" 형태였고,
  /// 이미 filtered 스캔이 돌고 있으면 phase 변수만 바뀌고 라디오는 그대로
  /// filtered로 남았다. iOS 27에서 **무필터 스캔만이 포그라운드 iPhone을
  /// 발견**하므로, 사용자가 당겨서 새로고침한 그 순간에 정작 친구를 볼 수 있는
  /// 유일한 모드가 적용되지 않았다(2026-07-30 heavy 11:09:37 boost → 스캔
  /// 재시작 로그 없음 → 11:09:48 self-heal이 15초 뒤에야 무필터 적용 →
  /// 11:09:49 교대 tick이 1.2초 만에 다시 filtered로 되돌림. 그날 발견 0건).
  ///
  /// 이제 원하는 필터와 걸려 있는 필터를 비교하므로, 모드 변경 의도는 어떤
  /// 호출 경로에서든 실제 stop→start로 이어진다.
  bool? _scanningUnfiltered;

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
  int _linkedTicks = 0;

  /// 마지막으로 무언가를 발견하거나 링크한 시각. CoreBluetooth가 조용히
  /// 죽었는지 판정하는 유일한 관측 가능 신호다.
  DateTime _lastRadioProgress = DateTime.now();

  /// 하드리셋 중복 방지 + 최소 간격.
  DateTime? _lastHardReset;
  bool _hardResetting = false;
  static const Duration _hardResetAfterSilence = Duration(minutes: 4);
  static const Duration _hardResetMinGap = Duration(minutes: 10);
  static const Duration _rssiPollInterval = Duration(seconds: 5);

  /// central 링크별 연속 RSSI read 실패 횟수 — 좀비 링크 탐지기의 근거.
  /// 성공한 read나 teardown이 있으면 리셋된다.
  final Map<String, int> _rssiFails = {};
  static const int _staleRssiFailures = 3;

  /// 우리 RX 특성을 구독한 원격 central들(UUID). **링크 객체보다 오래 산다**:
  /// P-링크는 전송 타임아웃 등으로 부기가 버려질 수 있는데, 그때 상대의 GATT
  /// 연결과 구독은 그대로 살아 있다. 예전에는 새 링크 객체가 구독 상태를
  /// false로 시작해 우리 notify가 **로그도 에러도 없이 영구히 버려졌다** —
  /// 상대→우리 방향만 살아 있는 반쪽 링크가 되어 "보이는데 메시지가 안 가는"
  /// 증상이 났다(2026-07-25 19:54 heavy↔gold: 전송 타임아웃으로 P-링크 교체
  /// 후 2시간 동안 heavy→gold 무음).
  final Set<String> _subscribedCentrals = {};

  /// 최근에 링크된 피어의 peripheral 식별자들로, 가장 최근 것이 뒤에 온다.
  /// [knownPeersLoad]/[knownPeersSave]로 영속화되어, 새로 실행되는 경우(iOS의
  /// 상태 복원 재실행 포함) scan 없이도 알려진 모든 피어에 대한 pending
  /// connect를 다시 걸 수 있다 — 백그라운드 피어의 overflow advertisement은
  /// scan에는 보이지 않지만, 식별자로 하는 connect는 동작한다.
  final Set<String> _knownPeers = {};
  static const int _maxKnownPeers = 6;

  /// 본딩 상태: peerHex → 마지막 peripheral 식별자. [bondedPeersLoad]에서
  /// 기동 시 채워지고 [ensureBonded] 성공 시 갱신·영속화된다.
  final Map<String, String> _bondedPeers = {};

  /// 이 세션에서 본딩을 이미 시도한 피어 — 성공/거절 무관 재프롬프트 금지.
  final Set<String> _bondAttempted = {};

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

  final Map<String, MeshLink> _links = {};
  final Set<String> _connecting = {};

  // 로컬의 mutable RX characteristic(peripheral 역할이 여기에 notify한다).
  GATTCharacteristic? _localRx;

  final List<StreamSubscription> _subs = [];
  bool _started = false;
  bool _disposed = false;

  /// [RadioHealth.searching]으로 볼 유예 — 이 안에서는 무선이 일하는 중이다.
  static const Duration _searchingGrace = Duration(seconds: 45);

  RadioHealth _lastHealth = RadioHealth.stopped;

  /// self-heal 틱의 하트비트. 이것이 멈추면 **모든 자동복구가 꺼진 것**이다
  /// (좀비 링크 절단·광고 재확립·deep heal·하드리셋 전부 이 틱 위에 있다).
  /// 2026-07-26 heavy: 이 타이머가 조용히 죽어 13시간 동안 자가복구가 전무했고,
  /// 스캔·광고는 계속 돌아 겉보기엔 정상이었다.
  DateTime? _lastMaintenanceTick;

  /// Android `ADVERTISE_FAILED_DATA_TOO_LARGE`.
  static const int _advertiseDataTooLarge = 1;

  /// Android `ADVERTISE_FAILED_TOO_MANY_ADVERTISERS`.
  static const int _advertiseTooManyAdvertisers = 2;

  /// 우리 메시 광고가 지금 올라와 있는가. 진단용 — 이 값이 false로 굳어 있으면
  /// 그 노드는 어떤 스캔에도 보이지 않는다.
  bool _advertising = false;

  /// 마지막 startAdvertising 실패의 Android error code(성공했으면 null).
  int? _lastAdvertiseError;

  /// 광고에 이름('SL')을 싣는가. [RadioProfile.advertiseNameOptional] 플랫폼에서
  /// 이름 단계가 한 번 실패하면 이 세션 동안 꺼 둔다 — 매 시도마다 같은
  /// 실패(또는 몇 초짜리 매달림)를 반복할 이유가 없다.
  bool _advertiseWithName = true;

  /// 이름 단계가 끝없이 매달릴 수 있는 플랫폼에서 광고 시작에 거는 상한.
  /// 정상이라면 어댑터 이름 방송과 광고 콜백이 1초 안에 끝난다.
  static const Duration _advertiseStartTimeout = Duration(seconds: 8);

  /// 앱이 포그라운드인지 여부 — iOS unfiltered scan 모드의 게이트 역할.
  /// 기본값은 true(보통의 실행은 포그라운드다); 백그라운드 재실행은 start
  /// 직후 [setForeground]로 이를 false로 설정한다.
  bool _foregroundScan = true;

  /// Android scan 모드: 0=LOW_POWER, 1=BALANCED, 2=LOW_LATENCY. LOW_LATENCY
  /// (벤더 기본값)는 거의 연속으로 scan하며 단일 요소로는 가장 큰 배터리
  /// 소모원이다; BALANCED는 대략 절반의 전력으로도 여전히 몇 초 안에
  /// discover한다. 적응형 전력(see MeshController)이 등급을 고른다.
  static const _scanPowerChannel = MethodChannel('spotlink/scan_power');
  int _scanModeCode = 2;

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

  /// 릴리즈 로그용 발견 계수기(마지막 linkless 요약 이후 누적). 개별 `BLE saw`
  /// 는 디버그 전용이라, 현장에서 "스캐너가 죽었나 / 상대가 광고를 안 하나 /
  /// 보이는데 SpotLink 매칭이 안 되나"를 릴리즈 로그로 구분할 수 없었다
  /// (2026-07-30 heavy↔Android: 무필터 스캔 2분에 dialed=0 — 이 셋 중 어느
  /// 것인지 로그로 판별 불가). linkless 요약이 함께 내보내고 리셋한다.
  int _sawTotal = 0;
  int _sawSpotLink = 0;
  int _sawApple = 0;

  /// 키별 최근 절단 시각들 — 플랩(짧은 시간 반복 절단) 감지용.
  final Map<String, List<DateTime>> _cutHistory = {};
  static const int _flapCutThreshold = 3;
  static const Duration _flapWindow = Duration(seconds: 90);
  static const Duration _flapRest = Duration(seconds: 60);

  MeshTransport({
    required this.myShortId,
    required this.infoValue,
    this.maxLinks = 8,
    RadioProfile? profile,
  }) : profile = profile ?? RadioProfile.forCurrentPlatform();

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
  ///
  /// [bonded]에 든 식별자는 최우선이다: 본딩된 id는 주소 회전으로 죽지
  /// 않는 유일한 부류라, 짧은 웨이크 창(~10–30초)에서 성공이 보장에 가까운
  /// 후보를 슬롯 경쟁에서 앞세워야 한다. 각 그룹 안에서는 최신순 유지.
  static List<String> pendingReconnectOrder(List<String> saved, int budget,
      {Set<String> bonded = const {}}) {
    final cap = budget < _maxPendingReconnects ? budget : _maxPendingReconnects;
    if (cap <= 0) return const [];
    final recentFirst = saved.reversed.toList();
    return [
      ...recentFirst.where(bonded.contains),
      ...recentFirst.where((id) => !bonded.contains(id)),
    ].take(cap).toList();
  }

  /// 벤더 플러그인은 Android 실패를 문자열로 감싸 던진다
  /// ("Start advertising failed with error code: N"). 복구 분기와 진단을 위해
  /// 그 숫자를 되살린다; 숫자가 없으면 null.
  @visibleForTesting
  static int? advertiseErrorCode(Object e) {
    final m = RegExp(r'error code:\s*(\d+)').firstMatch(e.toString());
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 이 광고 실패가 **이름 단계** 탓이라 이름을 빼고 다시 걸어야 하는가.
  ///
  /// 무선 스택의 광고 실패 중 슬롯 경합(code 2)이나 미지원(code 5)은 이름을
  /// 빼도 같은 결과다. 반면 code가 **없는** 실패(어댑터 이름 변경 거부
  /// IllegalStateException, 바뀐 이름 불일치 ArgumentError, 완료 방송이 오지
  /// 않아 매달림 TimeoutException)와 **데이터 크기 초과(code 1,
  /// ADVERTISE_FAILED_DATA_TOO_LARGE)**(Xiaomi/Huawei 등 OEM이 setName("SL")을
  /// 무시해 30바이트가 넘는 원래 기기 이름이 패킷에 들어가 31B 한도를 넘긴 경우)는
  /// 이름을 빼고 서비스 UUID만으로 다시 걸면 즉시 성공한다
  /// ([RadioProfile.advertiseNameOptional]).
  @visibleForTesting
  static bool dropsAdvertiseName(Object error, {required bool nameOptional}) {
    if (!nameOptional) return false;
    if (_MeshTransportPeripheral._isAlreadyAdvertising(error)) return false;
    final code = advertiseErrorCode(error);
    return code == null || code == _advertiseDataTooLarge;
  }

  /// Apple 제조사 데이터(0x004C) 중 probe dial 후보가 될 수 있는 패킷인지 판별한다.
  /// iBeacon(0x02, 0x15 — SpotLink 자체의 웨이크 토치 및 매장 비콘)은 언제나
  /// non-connectable이므로 probe dial을 걸면 스캔만 멈추고 8초간 허공에
  /// connectGatt를 낭비해 진짜 피어 발견을 마비시킨다.
  @visibleForTesting
  static bool isProbeableAppleData(Uint8List data) {
    if (data.length >= 2 && data[0] == 0x02 && data[1] == 0x15) {
      return false; // iBeacon (non-connectable)
    }
    return true;
  }

  /// probe dial이 끝난 뒤 연결을 강제로 놓아야 하는가.
  ///
  /// **성공한 probe는 절대 끊지 않는다.** 예전에는 이 정리가 성공·실패를
  /// 가리지 않고 돌아서, probe가 SpotLink iPhone을 찾아 링크를 올린 바로 그
  /// 순간 연결을 끊었다. 포크 플러그인의 disconnect는 `gatt.close()`라 끊김
  /// 콜백도 오지 않는다 — 우리 쪽엔 링크가 살아 있는 듯 남았다가 첫 write가
  /// 실패하며 잘리고, 다시 probe → 다시 끊김을 끝없이 반복했다. 백그라운드
  /// iPhone은 광고에 표식이 없어 probe가 Android의 **유일한** 도달 경로이므로,
  /// 이 경로가 통째로 막혀 있었다(2026-10-06 heavy: 사무실 삼성이 매번 새
  /// 주소로 붙고 ~3초 뒤 구독 해제 → `central not subscribed` 15회+, 신원 미확인
  /// 비콘 만남만 10건). 실패한 probe는 catch에서 이미 끊었고, 여기서 한 번 더
  /// 놓는 것은 타임아웃이 남긴 connectGatt 회수용 안전망이다.
  @visibleForTesting
  static bool releasesProbeConnection({required bool linked}) => !linked;

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
  DateTime? get lastMaintenanceTick => _lastMaintenanceTick;

  @override
  RadioHealth get health => RadioHealth.classify(
        started: _started,
        poweredOff: _central.state == BluetoothLowEnergyState.poweredOff,
        unauthorized: _central.state == BluetoothLowEnergyState.unauthorized,
        linkCount: _links.length,
        sinceProgress: DateTime.now().difference(_lastRadioProgress),
        flapping: _cutHistory.values.any((h) => h.length >= _flapCutThreshold),
        searchingGrace: _searchingGrace,
        agedAfter: _hardResetAfterSilence,
      );

  @override
  Stream<bool> get availabilityChanged => _central.stateChanged.map((e) {
        _log('BLE state changed: ${e.state}');
        return e.state == BluetoothLowEnergyState.poweredOn;
      });

  /// 진단용: 지금 전송이 믿고 있는 포그라운드 상태.
  bool get foregroundScan => _foregroundScan;

  PowerMode get powerMode => _powerMode;

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
    // 프로파일 이름을 남긴다: 나중에 로그만 보고 '어떤 정책으로 돌았는지'를
    // 알 수 있어야 플랫폼별 사건을 귀속할 수 있다.
    _log('BLE start: central=${_central.state} peripheral=${_peripheral.state} '
        'me=${myShortId.short} profile=${profile.name}');
    try {
      _bondedPeers.addAll(await bondedPeersLoad?.call() ?? const {});
      if (_bondedPeers.isNotEmpty) {
        _log('BLE bonded peers loaded x${_bondedPeers.length}');
      }
    } catch (_) {} // 본딩 기록 없음/손상 — 링크가 생기면 다시 채워진다
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
    if (profile.usesPendingConnect) {
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
    _startMaintenanceTimer();
  }

  @override
  void restartMaintenance() {
    if (!_started || _disposed) return;
    _log('BLE maintenance restarted by supervisor '
        '(last tick ${_lastMaintenanceTick == null ? "never" : "${DateTime.now().difference(_lastMaintenanceTick!).inSeconds}s ago"})');
    _lastMaintenanceTick = DateTime.now();
    _startMaintenanceTimer();
    // 죽어 있던 동안 놓친 것들을 즉시 만회한다.
    if (_links.isEmpty) {
      unawaited(_startScanning());
      if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
        unawaited(_startAdvertising(restart: true));
      }
      if (profile.usesPendingConnect) unawaited(_reconnectKnownPeers());
    }
  }

  /// QR로 검증된 친구와의 살아 있는 central 링크에서 OS 본딩을 유도한다.
  /// 암호화 특성([BleConstants.bondCharacteristicUuid])을 한 번 읽으면:
  /// 미본딩이면 OS가 페어링 다이얼로그를 띄우고(수락 시 IRK 교환 → 상대
  /// 주소 회전을 OS가 투명하게 해석 → 대기 연결이 절대 죽지 않음), 이미
  /// 본딩돼 있으면 조용히 성공한다. 세션당 피어당 1회만 시도해 거절한
  /// 사용자를 들볶지 않는다.
  Future<void> ensureBonded(String peerHex) => _ensureBondedImpl(peerHex);

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

  /// 사용자가 명시적으로 요청한 재탐색([wake]의 강화판, 당겨서 새로고침).
  /// 자동 경로가 실패 폭풍을 막으려고 쌓아 둔 백오프/쿨다운은 "사용자가 지금
  /// 찾으라고 했다"는 신호 앞에서는 의미가 없다 — 전부 비워서 scan 결과가
  /// 즉시 다시 dial/probe되게 하고, iOS에서는 빈 슬롯에 알려진 피어 대기
  /// 연결도 재장전한다(백그라운드 iPhone은 scan에 안 보이므로 이것이 유일한
  /// 경로다). 이미 걸려 있는 pending은 건드리지 않는다 — 90초 워치독이
  /// 죽은 식별자를 알아서 걸러낸다.
  Future<void> boost() async {
    if (!_started) return;
    _log('BLE boost: user-requested rediscovery');
    _probeMisses.clear();
    _probeBackoff.clear();
    _lastDialAt.clear();
    wake();
    if (profile.usesPendingConnect) await _reconnectKnownPeers();
  }

  /// iOS: wide 포그라운드 scan(unfiltered + 소프트웨어 매칭 — iOS 27에서 다른
  /// iPhone을 안정적으로 찾는 유일한 모드)과 filtered 백그라운드 scan(OS가
  /// 요구)을 서로 바꾼다. 항상 unfiltered로 scan하는 Android에서는 no-op.
  @override
  void setForeground(bool foreground) {
    if (_foregroundScan == foreground) return;
    _foregroundScan = foreground;
    if (!_started || !profile.switchesScanModeOnForeground) return;
    _scanModeTimer?.cancel();
    _scanModeTimer = null;
    _overflowPhase = false;
    if (foreground) {
      // 백그라운드 사이 iOS가 광고를 백그라운드급(이름 제거, 서비스 UUID는
      // overflow 영역)으로 강등시킨다 — 포그라운드로 돌아와도 스스로
      // 승격되지 않고, self-heal의 가벼운 _startAdvertising()은 "already
      // started"라 no-op이다. 이 상태로는 비콘 웨이크 창의 필터 스캐너가
      // 우리를 못 본다(2026-07-19 22:05: heavy가 포그라운드로 3분 서
      // 있는데도 gold가 세 번 깨어나 번번이 링크 실패, heavy 재시작 직후
      // 웨이크에서만 1.3초 만에 성공 — 재시작이 주던 것이 바로 신선한
      // 포그라운드급 광고였다). 부트 경로처럼 stop→start로 교체한다.
      unawaited(_startAdvertising(restart: true));
      // 링크가 없으면 알려진 피어 대기 연결도 다시 걸어, 앱 재시작이 주던
      // "즉시 재발견"을 포그라운드 복귀가 그대로 갖게 한다.
      if (_links.isEmpty) unawaited(_reconnectKnownPeers());
      // 자동 경로가 쌓아 둔 백오프도 비운다(boost와 같은 근거): 사용자가
      // 앱을 열었다 = 지금 찾으라는 신호다. 백그라운드에서 쌓인 프로브
      // 백오프(최대 10분)와 다이얼 쿨다운이 복귀 직후의 재발견을 억누르면
      // 안 된다.
      _probeMisses.clear();
      _probeBackoff.clear();
      _lastDialAt.clear();
    }
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

  /// Android BLE scan 모드를 설정하고 다시 scan해 적용한다(그 외에서는 no-op).
  Future<void> setScanMode(int code) async {
    if (!profile.supportsScanPowerTuning || _scanModeCode == code) return;
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
    _subscribedCentrals.clear();
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

  Future<void> dispose() async {
    await stop();
    _disposed = true;
    await _inbound.close();
    await _linkEvents.close();
    await _rssiSamples.close();
  }
}
