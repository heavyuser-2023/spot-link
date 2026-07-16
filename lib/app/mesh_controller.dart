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

/// 애플리케이션의 "두뇌": [MeshNode]를 소유하고, [AppDatabase]에 영속화하며,
/// [MeshFrontend]를 통해 관찰 가능한 상태를 노출한다. iOS에서는 UI isolate에서
/// 실행되고, Android에서는 foreground-service isolate(headless)에서 실행되며 이
/// 경우 UI는 대신 [RemoteMeshController]를 통해 연결된다.
///
/// 프레즌스 / 로스터 / 받은편지함 조회와 로컬 파일 동작은 공유 mixin인
/// [MeshFrontendState] / [LocalFileActions]에 들어 있다.
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
  int peerCount = 0;
  @override
  bool started = false;
  @override
  bool powerSaver = false;
  @override
  String? lastError;

  /// 메시지 행이 영속화되기 전에 도착한 상태 이벤트(delivered/failed);
  /// 삽입 시 [_persistAndCache]가 적용한다.
  final Map<String, MsgStatus> _pendingStatus = {};
  String? _openPeer; // 현재 화면에 열려 있는 대화(읽지 않음 표시를 억제한다)

  Timer? _presenceTimer;
  Timer? _bootFgRecheck;

  /// iOS 백그라운드 탈출구: 스와이프-강제종료/재기동으로 우리의 BLE 주소가
  /// 회전하거나(피어에 저장된 id가 오래돼 무효화됨) 링크가 끊겼는데 iOS 27이
  /// 백그라운드 상태의 피어를 다시 발견하지 못하면, wake→재연결이 조용히
  /// 멈춘다 — 하지만 foreground↔foreground 링크는 수 초 안에 맺힌다. 그래서
  /// 백그라운드 + 링크 없음 상태에서는 탭 한 번으로 여는 알림으로 사용자를
  /// 넛지한다. [_presenceTimer]에서 폴링한다(see [_maybeWakeNudge]); 전용
  /// 타이머는 없다.

  /// 링크 없음 감시견(watchdog) 비콘 펄스(iOS foreground torch). 임계값을 넘도록
  /// 링크가 하나도 없으면 wake torch가 막혀 있을 수 있다: 우리가 계속 송신하는
  /// 동안 우리 비콘 리전 "안에서" 스와이프-강제종료된 피어는 다시 진입하지 않고,
  /// 리전 회전이 끼어 있을 수도 있다. 링크가 없으니 잠깐 TX를 끄는 것은 아무
  /// 대가가 없다 — 그렇게 해서 리전 EXIT+ENTER를 강제하고 멈췄을 수도 있는
  /// 광고자(advertiser)를 다시 켠다.
  ///
  /// 적응형(ADAPTIVE) 임계값(현장 데이터 2026-07-16: ">1분간 못 찾음" 사례들):
  ///  - BOOT-linkless(이 프로세스에서 한 번도 링크된 적 없음 — 빠른
  ///    스와이프-강제종료 → 재기동 사례로, 피어가 EXIT를 기록하지 못했고 회전이
  ///    남은 유일한 wake일 수 있음): [_pulseAfterBootLinkless]에서 일찍 펄스한다.
  ///  - DROP-linkless(링크가 있었다가 끊김): 정상 경로(대기 중 연결, 회전 wake
  ///    ~20–54s)에게 먼저 방해받지 않는 시간을 줘야 한다 — 더 일찍 펄스하면 40s
  ///    간격 동안 회전 ENTER를 침묵시켜 일반적인 경우를 오히려 퇴행(REGRESS)시킬
  ///    수 있다. [_pulseAfterDrop]에서 펄스하고, 여전히 링크가 없는 동안
  ///    [_pulseAfterDrop]마다 반복한다.
  /// 하한(Floor): 구조 시간 ≈ 임계값 + 40s 간격 + ~5s 링크, 즉 ~75s(boot) /
  /// ~105s(drop) — 40s는 iOS의 ~30s 리전 종료 디바운스로, 조정 불가능하다.
  DateTime? _linklessSince;
  bool _beaconPulsing = false;
  bool _everLinked = false; // 이 프로세스에서의 링크 여부 → drop 주기로 전환
  bool _pulsedSinceBoot = false; // 첫 펄스 이후 drop 주기로 안착
  Timer? _beaconPulseTimer;

  /// 적응형 전력(Android 전용 — 24/7 foreground-service 소모). 비싼 부분은
  /// LOW_LATENCY로 계속 이어지는 BLE *스캐닝*이다; 광고(advertising)와 beacon
  /// torch는 저렴하고 다른 기능들이 이에 의존하므로, 그것들은 계속 켜 두고
  /// 스캐닝만 조절(throttle)한다. 단계(tier)는 [_adaptiveInterval]마다, 그리고
  /// 링크가 바뀔 때마다 평가한다:
  ///   충전 중                        → active  + low-latency (마음껏 소모)
  ///   배터리 ≤15% & 미충전           → saver   + low-power   (비상 절약)
  ///   최근 토폴로지 변화 (<60s)      → active  + low-latency (빠른 (재)합류)
  ///   미충전, 링크 없음              → active  + balanced    (½ 전력으로 탐색)
  ///   미충전, 링크 있음 (안정)       → saver   + balanced    (아껴 씀)
  /// 수동 "배터리 절약" 토글이 켜져 있으면 이는 하드 플로어(hard floor)로서 이
  /// 기능을 비활성화한다(사용자가 최소 소모를 명시적으로 요청한 것이다).
  final Battery _battery = Battery();
  Timer? _adaptiveTimer;
  DateTime? _lastTopoChange;
  int _appliedScanCode = 2;
  bool? _appliedSaver;
  static const Duration _adaptiveInterval = Duration(seconds: 30);
  static const Duration _pulseAfterBootLinkless = Duration(seconds: 30);
  static const Duration _pulseAfterDrop = Duration(seconds: 60);
  // > iOS의 ~30s 리전 종료 디바운스보다 커서, 막힌 피어가 실제로 EXIT하도록 한다.
  static const Duration _beaconPulseGap = Duration(seconds: 40);
  StreamSubscription? _sub;
  StreamSubscription? _rssiSub;
  StreamSubscription? _availabilitySub;

  /// 메시가 아직 시작되지 않은 동안의 주기적 폴백 재시도. [availabilityChanged]는
  /// BLE 어댑터가 켜질 때 발생하지만, 런타임 BLE 권한이 부여될 때는 발생하지
  /// 않는다(어댑터 상태 변화가 없음) — 그래서 최초 설치 사용자가 실행 후
  /// 블루투스를 켜거나 권한을 부여하면 앱을 재시작하기 전까지 오래된 "블루투스
  /// 꺼짐" 배너에 머무르게 된다. 느린 틱마다 시작을 재시도하면 재시작 없이 두
  /// 경우 모두 복구한다.
  Timer? _startRetryTimer;
  bool _restarting = false;

  /// 앱이 현재 foreground에 있는지 여부. 수신 메시지는 foreground가 아닐 때(화면
  /// 꺼짐 / 백그라운드)에만 로컬 알림을 띄운다.
  bool _foreground = true;

  /// 백그라운드 알림을 디스패치한다. 주입 가능(injectable)하게 하여 테스트가
  /// 플랫폼 채널 없이도 이를 관찰할 수 있다.
  final void Function(String conversationKey, String title, String body)
      _notify;

  /// UI가 연결되지 않은 Android foreground-service isolate 안에서 실행 중일 때
  /// true(부팅 / 스와이프-강제종료 복구): 위젯 생명주기 배선을 건너뛰고, 모든
  /// 수신 메시지를 백그라운드로 취급하며(→ 항상 알림), 우리 자신과는 결코 메시
  /// 소유권을 협상하지 않는다.
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
              // Fast lane. 전송마다 능력(capability) 순서로 시도하며, 모두 BLE
              // 폴백을 갖는다: (1) 네이티브 AP 없는 P2P(Android Wi-Fi Direct /
              // iOS MultipeerConnectivity), (2) 같은 Wi-Fi에 있을 때 LAN TCP.
              // 사용 불가한 곳에서는 비활성 → BLE가 모든 것을 나른다.
              fastLane: CompositeFastLane([
                PlatformFastLane.instance,
                LanSocketFastLane(),
              ]),
            ),
        _notify = notifier ?? _defaultNotify;

  static void _defaultNotify(String key, String title, String body) =>
      NotificationService.showMessage(
          conversationKey: key, title: title, body: body);

  /// 라디오를 사용할 수 없는 이유(홈 화면 배너 문구를 결정한다).
  @override
  RadioStatus get radioStatus => node.transport.radioStatus;

  @override
  PeerId get myId => identity.peerId;

  /// 피어별 평활화된 신호 강도: 원시 BLE RSSI는 심하게 흔들리므로, 지수 이동
  /// 평균(EMA)으로 근접 UI가 떨리지 않게 한다.
  void _onRssi(RssiSample s) {
    final peer = s.peer;
    if (peer == null) return; // 출처를 알 수 없는 측정값
    final hex = peer.hex;
    final old = rssiSmoothed[hex];
    rssiSmoothed[hex] =
        old == null ? s.rssi.toDouble() : old * 0.6 + s.rssi * 0.4;
    rssiSeenAt[hex] = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  /// 설정 UI를 위한 릴레이 메일박스 통계.
  @override
  int get relayStoreCount => node.store.durableCount;
  @override
  int get relayStoreBytes => node.store.durableBytes;

  /// 우리가 다른 사람을 위해 나르고 있는 메시지를 사용자가 직접 비운다.
  @override
  Future<void> clearRelayStore() async {
    node.store.clearDurable();
    await db.clearRelayStore();
    notifyListeners();
  }

  Future<void> init() async {
    await _wireKnownPeersStore();
    // 수신 전송은 우리 컨테이너의 디스크에서 조립된다(systemTemp가 아님 —
    // iOS는 압박을 받으면 이를 비울 수 있고, 전송 도중이면 part 파일이 손상된다).
    try {
      final docs = await getApplicationDocumentsDirectory();
      final incoming = Directory(p.join(docs.path, 'incoming'));
      if (!await incoming.exists()) {
        await incoming.create(recursive: true);
      } else {
        // 이전 강제종료로 중단된 전송이 남긴 .part 파일을 쓸어낸다 — init
        // 시점에는 진행 중인 전송이 아직 없으므로, 남은 것은 모두 죽은 것이다.
        // (디스크 정리 차원; 이것들이 메모리를 누수시킨 적은 없다.)
        for (final f in incoming.listSync()) {
          if (f is File && f.path.endsWith('.part')) {
            try {
              f.deleteSync();
            } catch (_) {}
          }
        }
      }
      node.incomingPartPath = (tid) => p.join(incoming.path, '$tid.part');
    } catch (_) {} // node는 systemTemp로 폴백한다
    // Wake-beacon TX: Android는 항상 송신하고(백그라운드 OK); iOS는 foreground
    // 상태일 때만 송신한다 — resume될 때마다 다시 확정한다. 이것이 근처의
    // 스와이프-강제종료된 아이폰을 되살린다(그들은 이 비콘의 리전을 모니터링한다).
    unawaited(BeaconWake.startTx());
    unawaited(_refreshBeaconStatus());
    // 네이티브 P2P fast-lane 능력을 탐지한다(Wi-Fi Direct / Multipeer).
    // 모든 플랫폼에서 안전하다: 네이티브 핸들러가 없으면 → capabilities는 비어
    // 있는 채로 유지되고 파일은 LAN 소켓이나 BLE를 사용한다.
    await PlatformFastLane.instance.warmUp();
    // Native Multipeer/Wi-Fi Direct diagnostics → Documents/ble.log
    PlatformFastLane.logSink = (msg) => bleLogSink?.call(msg);
    bleLogSink?.call('FastLane caps: '
        '${PlatformFastLane.instance.capabilities.map((k) => k.name).toList()}');
    if (headless) {
      // 이 isolate에는 UI가 없다: 모든 수신 메시지는 알림을 띄워야 한다.
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
    // 앱이 마지막으로 죽었을 때 진행 중이던 전송은 이제 결코 끝날 수 없다 —
    // 실패 처리하여 어떤 말풍선도 영원히 스피너에 갇히지 않게 한다.
    await db.failStaleTransfers();

    // 내구성 있는 store-and-forward 메일박스를 다시 불러온다(우리가 다른 사람을
    // 위해 나르는 미전달 텍스트는 재시작을 견딘다 — "언젠가 전달"), 그 뒤 모든
    // 변경을 디스크에 다시 반영한다.
    final relayFrames = <Frame>[];
    for (final bytes in await db.loadRelayFrames()) {
      try {
        relayFrames.add(Frame.decode(bytes));
      } catch (_) {} // 손상된 행: 건너뜀
    }
    node.store.seed(relayFrames);
    node.store.onDurableChanged = (msgIdHex, frame) {
      if (frame == null) {
        unawaited(db.deleteRelayFrame(msgIdHex));
      } else {
        unawaited(db.upsertRelayFrame(msgIdHex, frame.encode()));
      }
    };
    // 나에게 미전달된 id(봤지만 복호화 실패 / 키 없음): 영속화하여 깨끗한 사본이
    // 도착하기 전에 재시작해도 이들을 다시 요청하도록 한다.
    node.seedPendingLocalDelivery(await db.loadPendingDeliveries());
    node.onPendingLocalChanged = (msgIdHex, present) {
      unawaited(present
          ? db.addPendingDelivery(msgIdHex)
          : db.removePendingDelivery(msgIdHex));
    };
    // 영속화된 서명 영수증(receipt)을 다시 적용한다: 이미 전달된 텍스트에 대한
    // 툼스톤(tombstone)은 재시작을 견딘다(위의 연락처가 서명 키를 제공한다).
    await node.rebuildReceipts();
    // 그리고 그 사이에 발신자 키를 알게 된, 보류(parked)된 메시지를 재시도한다.
    await node.redeliverParked();
    // 알려진 각 대화의 마지막 메시지로 받은편지함을 시드(seed)한다.
    for (final hex in await db.conversationPeers()) {
      final last = await db.lastMessageFor(hex);
      if (last != null) lastMessages[hex] = last;
    }

    _sub = node.events.listen(_onEvent);
    _rssiSub = node.rssiSamples.listen(_onRssi);
    started = await node.start();
    // 부팅 시 링크 없음 시계를 시작한다: 한 번도 링크되지 않는 재기동(빠른
    // 스와이프-강제종료 → 재기동, 피어의 wake가 막힘)은 이른 펄스를 촉발해야
    // 한다 — 링크가 아예 맺히지 않으면 LinksChanged만으로는 결코 발생하지 않는다.
    if (started) _linklessSince ??= DateTime.now();
    // iOS 스캔 모드는 앱의 foreground 상태를 따른다(백그라운드 재기동은 필터링된
    // 스캔을 써야 하고; 일반 실행은 넓은 스캔을 쓴다). 일반 실행은 `resumed`로
    // 가는 도중에 `inactive`를 거치는데, 그 전이는 우리의 생명주기 옵저버가
    // 등록되기 전에 완료될 수 있다 — 여기서 이를 "백그라운드"로 읽으면 스캔이
    // 필터링된 채로(아이폰을 보지 못함) 남고 아무것도 이를 바로잡지 못했다.
    // 부팅 시에는 명시적인 백그라운드 상태만 백그라운드로 친다.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    node.setForeground(lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.detached &&
        lifecycle != AppLifecycleState.hidden);
    // 위의 낙관적 기본값은 백그라운드 재기동을 잘못 읽는다(비콘 wake / 상태
    // 복원은 init 시점에 null 생명주기를 보고하며, 이는 일반 실행과 같다).
    // +3s가 지나면 상태가 안정된다: 백그라운드 재기동은 `paused`로 읽히므로 —
    // 거기서 OS가 요구하는 필터링된 스캔으로 전환한다. foreground 실행은
    // `resumed`로 읽히고 이 동작은 no-op이다.
    if (!headless) {
      _bootFgRecheck = Timer(const Duration(seconds: 3), () {
        final s = WidgetsBinding.instance.lifecycleState;
        if (s == AppLifecycleState.paused ||
            s == AppLifecycleState.detached ||
            s == AppLifecycleState.hidden) {
          node.setForeground(false);
        }
      });
    }
    if (!started) {
      lastError = 'Bluetooth unavailable';
      // 새로 설치한 경우 OS 권한 프롬프트가 아직 화면에 떠 있어(또는 그냥
      // 블루투스가 꺼져 있어) 첫 시작이 실패한다. 앱 재시작을 요구하는 대신
      // 어댑터가 사용 가능해지는 즉시 재시도한다.
      _availabilitySub =
          node.transport.availabilityChanged.listen(_onTransportAvailable);
      // 이벤트에만 의존하는 복구는 런타임 권한 부여 사례를 놓친다(어댑터 상태
      // 변화가 발생하지 않음). 재시작 전까지 오래된 배너가 남는다 — 그래서 폴링도
      // 한다. start()가 성공하는 순간 둘 다 멈춘다.
      _startRetryTimer = Timer.periodic(
          const Duration(seconds: 3), (_) => _onTransportAvailable(true));
    }

    // "nearby" 프레즌스가 시간이 지나 사라지도록 리스너를 주기적으로 갱신한다.
    _presenceTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _maybeBeaconPulse();
      // 부팅 시에만 하지 않고 폴링하여, 한 번도 링크되지 않은 wake뿐 아니라
      // 나중에 끊겨 다시 맺지 못한 링크까지 넛지가 다루도록 한다.
      if (Platform.isIOS && !headless) unawaited(_maybeWakeNudge());
      notifyListeners();
    });
    // 적응형 BLE 전력(Android 전용). 지금 한 번, 그리고 느린 틱마다 평가한다.
    if (Platform.isAndroid) {
      unawaited(_evaluateAdaptivePower());
      _adaptiveTimer = Timer.periodic(
          _adaptiveInterval, (_) => unawaited(_evaluateAdaptivePower()));
    }
    notifyListeners();
  }

  /// [_battery] 참고. Android 전용; 수동 절약 토글이 켜져 있으면 no-op이다.
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
        node.setPowerSaver(saver); // 전송(transport)만 제어하고, UI 플래그는 아니다
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
        debugPrint('SpotLink $line'); // 현장 진단을 위해 logcat에 나타난다
      }
    } catch (_) {} // 배터리 플러그인 사용 불가 / 일시적 오류 — 마지막 단계 유지
  }

  /// 백그라운드에서 오프라인에 갇혀 있을 때 사용자가 앱을 열도록 넛지한다.
  /// [_presenceTimer]에서 10초마다 폴링하여, 한 번도 링크되지 않은 백그라운드
  /// 재기동과, 링크가 올라왔다가 나중에 끊긴 경우를 모두 다룬다(iOS 27은
  /// 백그라운드 상태의 피어를 다시 발견하지 못하므로, 끊긴 링크는 종종 조용히
  /// 다시 맺히지 못한다). foreground 상태이거나 링크가 있으면 no-op이다. 15분
  /// 디스크 쿨다운으로 리전 회전 wake(~36s)와 10초 폴링이 스팸을 일으키지 않게
  /// 한다.
  Future<void> _maybeWakeNudge() async {
    // foreground가 아님 = 넛지할 만함. 비콘 / 상태 복원 재기동은 이 시점에
    // lifecycleState를 `null` 또는 `inactive`로 보고한다(paused가 아님). 그래서
    // 앞선 `paused|detached|hidden` 검사는 바로 이 넛지가 존재하는 이유인
    // 백그라운드 재기동 사례를 조용히 놓쳤다(관측됨: gold가 깨어나 수 분간 링크
    // 없이 있었지만 넛지가 한 번도 발생하지 않음). 진짜 foreground 실행은
    // 부팅+10s 무렵이면 `resumed`이므로, "!= resumed"가 깔끔하게 구분한다.
    final s = WidgetsBinding.instance.lifecycleState;
    final foreground = s == AppLifecycleState.resumed;
    if (foreground || !started || linkCount > 0) return;
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
      return; // 영속화된 쿨다운 없음 → 알림 폭주 위험을 감수하지 않는다
    }
    bleLogSink?.call('${DateTime.now().toIso8601String()} wake nudge shown '
        '(background relaunch, linkless 10s)');
    await NotificationService.showMessage(
      conversationKey: 'wake-nudge',
      title: '주변에 SpotLink 친구가 있어요',
      body: '탭해서 열면 바로 연결됩니다.',
    );
  }

  /// [_linklessSince] 참고. iOS foreground 전용: [_linklessPulseAfter] 동안
  /// 링크를 하나도 갖지 못했을 때 wake torch를 펄스하여, 우리 비콘 리전 안에
  /// 갇힌 피어를 구조하고 멈춘 광고자를 풀어준다. 방해할 링크가 없다는 바로 그
  /// 이유로 단점이 없다.
  void _maybeBeaconPulse() {
    if (!Platform.isIOS || headless || !_foreground || _beaconPulsing) return;
    final since = _linklessSince;
    if (since == null || linkCount > 0) return;
    final threshold = (_everLinked || _pulsedSinceBoot)
        ? _pulseAfterDrop
        : _pulseAfterBootLinkless;
    if (DateTime.now().difference(since) < threshold) return;
    _beaconPulsing = true;
    _pulsedSinceBoot = true;
    bleLogSink?.call('${DateTime.now().toIso8601String()} '
        'beacon wake pulse (linkless ${threshold.inSeconds}s)');
    unawaited(BeaconWake.stopTx().then((_) {
      _beaconPulseTimer?.cancel();
      _beaconPulseTimer = Timer(_beaconPulseGap, () {
        unawaited(BeaconWake.startTx());
        // 펄스를 기관총처럼 쏘아대지 않도록 링크 없음 시계를 재시작한다.
        _linklessSince = linkCount == 0 ? DateTime.now() : null;
        _beaconPulsing = false;
      });
    }));
  }

  /// 늦은 시작: 초기 [MeshNode.start]가 실패했고 어댑터가 방금 사용 가능해졌다
  /// (권한이 부여되었거나 블루투스가 켜짐).
  Future<void> _onTransportAvailable(bool ok) async {
    if (!ok) {
      // 아직 사용 불가하지만 이유가 바뀌었을 수 있다(꺼짐 vs 권한 없음) —
      // 배너 문구를 갱신한다.
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
        // iOS/macOS 스캔 모드는 앱의 현재 foreground 상태를 따른다.
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
      // iOS가 우리를 서스펜드한 뒤 foreground로 복귀: 즉시 프레즌스를 다시
      // 알리고 디스커버리를 다시 걷어차, 우리(그리고 피어들)가 다음 15초 주기를
      // 기다리지 않고 온라인 상태를 회복하도록 한다.
      node.setForeground(true); // 먼저 넓은 스캔, 그다음 wake 재시동
      if (started) unawaited(node.wakeUp());
      // iOS는 백그라운드에서 beacon TX를 죽인다 — torch를 다시 켠다.
      unawaited(BeaconWake.startTx());
      // 위치 권한을 다시 읽는다: 사용자가 방금 설정에서 "항상"으로 바꿨을 수
      // 있는데, 이것이 없으면 "항상 권한 필요" 배너가 앱 재시작 전까지 남는다
      // (그러지 않으면 부팅 시에만 확인된다).
      unawaited(_refreshBeaconStatus());
      unawaited(NotificationService.cancelFor('wake-nudge'));
      if (_openPeer != null) NotificationService.cancelFor(_openPeer!);
    } else if (state == AppLifecycleState.paused) {
      node.setForeground(false); // OS가 요구하는 필터링된 스캔으로 복귀
      // 백그라운드로 향함 = jetsam 후보. 재구성 가능한 모든 것을 지금 벗어던져
      // 서스펜드 상태의 메모리 점유를 최대한 작게 만든다.
      _trimMemory();
    }
  }

  @override
  void didHaveMemoryPressure() => _trimMemory();

  /// 재구성 가능한 상태를 버린다: 디코딩된 이미지와 캐시된 대화(열 때 SQLite에서
  /// 다시 불러온다). 열려 있는 대화는 유지하여 보이는 채팅이 빈 화면이 되지 않게
  /// 한다.
  void _trimMemory() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    conversationCache.removeWhere((hex, _) => hex != _openPeer);
  }

  /// 앱이 foreground에 없을 때(화면 꺼짐 / 백그라운드) 수신 메시지에 대해 로컬
  /// 알림을 띄운다. 사용자가 현재 열어 둔 채팅에 대해서는 억제된다.
  void _notifyIncoming(PeerId from, String body) {
    // 앱이 foreground에 없을 때만(화면 꺼짐 / 백그라운드).
    if (_foreground) return;
    final name = contactByHex(from.hex)?.displayName ?? from.short;
    _notify(from.hex, name, body);
  }

  /// 테스트 훅: 실제 생명주기 이벤트 없이 앱 foreground 플래그를 조작한다.
  @visibleForTesting
  void setForegroundForTest(bool value) => _foreground = value;

  // ---- 크로스 isolate 브리지 훅(headless 모드; MeshHost 참고) ----

  /// 메시지 테이블의 단조 증가 리비전. 이 값이 바뀔 때마다 원격 UI는 열려 있는
  /// 대화를 (공유) DB에서 다시 불러온다 — isolate 포트로 메시지 목록을
  /// 직렬화하는 것보다 저렴하고 간단하다.
  int msgRev = 0;

  void _bumpRev() => msgRev++;

  /// 원격 UI의 앱 생명주기 상태를 브리지로 미러링하여, headless 두뇌가 로컬
  /// 두뇌와 정확히 똑같이 알림을 라우팅하도록 한다(사용자가 앱을 보고 있는
  /// 동안에는 억제).
  void setRemoteForeground(bool foreground) {
    final wasForeground = _foreground;
    _foreground = foreground;
    if (foreground && !wasForeground) {
      // 로컬 컨트롤러가 resume 시 하는 것과 같은 재시동: 광고를 다시 확정하고
      // 디스커버리를 재시작하여, 다음 self-heal/듀티 사이클을 기다리는 대신
      // 프레즌스가 즉시 회복되도록 한다.
      if (started) {
        unawaited(node.wakeUp());
      } else {
        // 메시가 전혀 올라오지 않았다(예: 부팅 시 BLE 권한이 없어 ensureReady가
        // 실패). UI가 방금 foreground로 왔고 권한을 부여했을 수 있다 — 권한
        // 부여가 항상 방출하지는 않는 어댑터 이벤트를 기다리는 대신 지금
        // 재시도한다.
        unawaited(_onTransportAvailable(true));
      }
      if (_openPeer != null) NotificationService.cancelFor(_openPeer!);
    }
  }

  /// 크로스 isolate UI 미러를 위한 직렬화 가능한 상태 스냅샷. 여기의 모든 것은
  /// JSON 안전하다(숫자/문자열/불리언/맵/리스트만).
  Map<String, Object?> snapshotForRemote() => {
        'started': started,
        'links': linkCount,
        'peers': peerCount,
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

  /// 브리지를 위한 Id 기반 명령 변형: 원격 UI는 평범한 ChatMessage 사본을 들고
  /// 있으므로, 명령은 (peerHex, msgId)로 포트를 건너오고 여기서 권위 있는 DB
  /// 행에 다시 연결된다.
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
        peerCount = node.peerCount; // 서로 다른 기기(C:/P: 중복 제거됨)
        if (count > 0) _everLinked = true; // → 향후 펄스는 drop 주기로
        _linklessSince = count == 0 ? (_linklessSince ?? DateTime.now()) : null;
        // 토폴로지 변화는 빠른 (재)합류를 위해 잠깐의 low-latency 버스트를 얻는다.
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
        // 실시간 재시도는 소진되었지만 텍스트는 내구성 있는 relay store에 보류된
        // 채로 남는다 — 무서운 실패 대신 "전달 대기"를 보여준다. 늦은 ACK가
        // DeliveryConfirmed로 도착하면 delivered로 뒤집는다.
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

  /// 메시지에 전달 상태 변화를 적용한다. 아주 작은 전송은 발신 말풍선이
  /// 영속화되기도 전에 확인(ACK)될 수 있다 — 상태를 기억해 두고 삽입 시
  /// [_persistAndCache]가 이를 적용하게 한다.
  Future<void> _applyStatus(String msgId, MsgStatus status) async {
    final updated = await db.updateStatusByMsgId(msgId, status);
    if (updated == 0) _pendingStatus[msgId] = status;
    _patchStatus(msgId, status);
    _bumpRev();
    notifyListeners();
  }

  // ---- 연락처 ----

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
      // 검증되었거나 사용자가 이름을 바꾼 경우 그 이름을 유지하고; 그렇지 않으면
      // 알려진(announce된) 이름을 채택한다. nameLocked 가드가 없으면 피어의 다음
      // ANNOUNCE(~15초마다)가 미검증 연락처에 대한 사용자의 이름 변경을 조용히
      // 되돌렸다.
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
    // 사용자가 이름을 바꾼 연락처는 QR 재스캔에도 이름을 유지한다.
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

  /// 연락처를 삭제한다: 키, 대화 이력, 그리고 수신/발신한 파일 사본 전부. 차단이
  /// 아니다 — 근처의 피어는 다음 ANNOUNCE 때 다시 나타난다(새로운 미검증
  /// 연락처로서).
  @override
  Future<void> deleteContact(String peerHex) async {
    // 이 대화가 참조하는 파일을 최선의 노력으로 정리한다.
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
    // nameLocked는 announce 업데이트에 맞서 사용자의 선택을 고정한다.
    final updated = existing.copyWith(displayName: trimmed, nameLocked: true);
    await db.upsertContact(updated);
    replaceContact(updated);
    notifyListeners();
  }

  // ---- 신원(identity) ----

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
      // 수동 절약은 하드 플로어다: 가장 저렴한 스캔으로도 내리고 적응형 제어는
      // 물러나게 한다.
      _appliedSaver = true;
      _appliedScanCode = 0;
      unawaited(node.setScanMode(0));
    } else {
      // 적응형 제어에 다시 넘긴다(지금 올바른 단계를 다시 도출한다).
      _appliedSaver = null;
      unawaited(_evaluateAdaptivePower());
    }
    notifyListeners();
  }

  // ---- QR 페이로드(포맷은 QrPayload에 있음) ----

  @override
  String get myQrPayload => QrPayload.encode(identity.publicBundle, displayName);

  static (Uint8List, String)? parseQr(String payload) =>
      QrPayload.decode(payload);

  // ---- 메시징 ----

  @override
  Future<void> openConversation(String peerHex) async {
    _openPeer = peerHex;
    unreadCounts.remove(peerHex);
    NotificationService.cancelFor(peerHex);
    if (!conversationCache.containsKey(peerHex)) {
      // await *이전에* 플레이스홀더 리스트를 설치하여 DB 로드 중에(_persistAndCache
      // 를 통해) 도착하는 메시지를 포착한 뒤, 중복 없이 DB 스냅샷과 병합한다.
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
    // 이전 시도를 취소하여, 그것의 늦은 store-and-forward 사본이 이 새 전송(새
    // msgId)과 함께 이중 전달되지 못하게 한다. 봉투(envelope)에는 원래(ORIGINAL)
    // 작성 시각을 유지한다 — 재전송은 새 메시지가 아니며, 수신자의 "HH:mm 전송"은
    // 그것이 작성된 시점을 반영해야 한다.
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
    // 바이트를 디스크에 한 번 내려놓은 뒤 디스크 기반으로 전송하여, 전송이 결코
    // 페이로드를 RAM에 고정하지 않게 한다. (실제 경로를 가진 호출자는
    // [sendFilePath]를 사용해 바이트 왕복을 아예 건너뛰어야 한다.)
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
    // Picker/outbox 경로는 OS가 비울 수 있는 캐시에 있다 — 내구성 있는 사본을
    // 유지하고(네이티브 File.copy: 스트리밍, RAM 비용 없음) 그로부터 전송하여,
    // 말풍선을 계속 열 수 있고 실패한 전송을 계속 재시도할 수 있게 한다. 소스가
    // 이미 우리 자신의 sent/ 사본인 경우(sendFile 바이트 경로)에는 건너뛴다.
    if (!path.contains('${Platform.pathSeparator}sent${Platform.pathSeparator}')) {
      final copy = await _copyToSent(now.toString(), name, path);
      if (copy != null) path = copy;
    }
    final size = await File(path).length();
    // META 프레임이 나가는 즉시 반환한다; 청크는 백그라운드에서 스트리밍되며
    // FileProgress / DeliveryConfirmed / FileFailed 이벤트로 결과를 보고한다.
    // 말풍선은 즉시 나타나야 한다.
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

  /// sent/ 아래의 내구성 있는 사본을 위한 목적지 경로, 또는 폴더를 준비할 수
  /// 없을 때 null. 사본은 어디서나 최선의 노력이다: null은 단지 "로컬 사본 없이
  /// 전송"을 뜻한다.
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

  /// [_saveLocalCopy]와 같지만 기존 파일로부터 — 네이티브 복사, RAM 없음.
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

  /// 진행 중인 발신 전송을 취소한다(청크 스트림을 멈춘다).
  @override
  Future<void> cancelFile(ChatMessage msg) async {
    node.cancelSend(msg.msgId);
    transferProgress.remove(msg.msgId);
    await _applyStatus(msg.msgId, MsgStatus.failed);
  }

  /// 실패한 파일 전송을, 전송 시점에 저장해 둔 로컬 사본으로부터 다시 보낸다.
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
      timestamp: now, // 도착 시각(이 기기의 시계)
      sentTs: sentAt?.millisecondsSinceEpoch,
    );
    await _persistAndCache(msg, incoming: true);
    _notifyIncoming(from, text);
  }

  /// 수신 전송이 방금 시작됐다(META 수신): 파일이 완료될 때까지 조용히 기다리는
  /// 대신 곧바로 진행률 말풍선을 보여준다.
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
    // 검증된 페이로드는 이미 디스크에 있다(수신자의 part 파일) — 바이트를 다시
    // 쓰는 대신 제자리로 옮긴다(같은 볼륨에서는 rename; 볼륨을 넘나들 때는 네이티브
    // 복사로 폴백한다).
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

    // 보통은 _onFileOffered가 만든 "receiving" 플레이스홀더가 존재한다 — 그것을
    // 제자리에서 완료 처리한다.
    final updated = await db.updateFileByMsgId(
        meta.transferIdHex, path, MsgStatus.received);
    if (updated > 0) {
      _patchFile(meta.transferIdHex, path, MsgStatus.received);
      _bumpRev();
      notifyListeners();
      return;
    }

    // 플레이스홀더가 없다(엣지 케이스) — 완성된 메시지를 직접 삽입한다.
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
    // 상태 이벤트(예: 아주 작은 파일의 완료 ACK)가 이 삽입보다 먼저 도착했을 수
    // 있다 — 잃어버리는 대신 지금 적용한다.
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

  /// iOS 비콘 리전 모니터링이 켜져 있을 때 true("항상" 위치 권한이 부여됐고
  /// 사용자가 토글을 켠 경우). Android에서는 의미 없다.
  @override
  bool beaconMonitoring = false;

  @override
  bool beaconNeedsAlways = false;

  Future<void> _refreshBeaconStatus() async {
    final s = await BeaconWake.status();
    beaconMonitoring = s['monitoring'] == true;
    // 격하된 권한 상태를 UI에 드러낸다: 모니터링은 켜져 있지만 iOS가 "사용 중에만"
    // 권한만 줘서, 백그라운드에서는 아무것도 우리를 깨우지 못한다. 아래에서
    // 업그레이드 프롬프트를 여전히 띄우지만, 사용자가 한 번 거부하면 iOS는 그
    // 호출을 무시한다 — 그때는 배너 + 설정 바로가기가 유일한 탈출구다.
    beaconNeedsAlways =
        Platform.isIOS && beaconMonitoring && s['auth'] != 'always';
    // 모니터링은 기본값이 ON이지만(BeaconPlugin.swift 참고) "항상" 위치 권한이
    // 있어야만 동작한다 — 최초 실행 때 한 번 요청한다.
    // 비콘-웨이크 RX(리전 진입 시 종료된 앱을 재실행)는 authorizedAlways가
    // 필요하다. iOS는 첫 프롬프트에서 흔히 When-In-Use만 부여하는데 — 그러면
    // 모니터링은 백그라운드에서 쓸모없고, 예전 코드는 다시 요청하지 않았다.
    // whenInUse 상태에서 다시 요청하면 일회성 "항상 허용으로 변경?" 업그레이드
    // 프롬프트가 뜬다; 사용자가 거부하면 iOS는 이후 호출을 무시하므로, 반복해도
    // 무해하게 유지된다.
    if (Platform.isIOS &&
        beaconMonitoring &&
        (s['auth'] == 'notDetermined' || s['auth'] == 'whenInUse')) {
      await BeaconWake.requestAlways();
    }
    notifyListeners();
  }

  /// Me 탭 토글: "비콘으로 나를 깨우기" 동작을 켜거나 끈다.
  @override
  Future<void> setBeaconMonitoring(bool on) async {
    if (on) {
      await BeaconWake.requestAlways(); // 일회성 권한 프롬프트
      await BeaconWake.enableMonitoring();
    } else {
      await BeaconWake.disableMonitoring();
    }
    await _refreshBeaconStatus();
  }

  /// 알려진 피어의 peripheral 식별자는 작은 JSON 파일에 저장되어, 새로운 실행
  /// (또는 iOS 상태 복원 재실행)이 스캔 없이 모든 친구에 대한 대기 중 연결을
  /// 다시 준비할 수 있게 한다.
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
    } catch (_) {} // 진단 수준의 영속화 — 시작을 절대 막지 않는다
  }

  // ---- 파일(openFile / saveToGallery / shareFile: LocalFileActions 참고) --

  /// 이 기기에서 메시지 말풍선 하나를 삭제한다(DB + 메모리). 파일 메시지의 경우
  /// 저장된 파일도 디스크에서 지운다. 순수하게 로컬 동작이다 — 피어의 사본은
  /// 건드리지 않는다.
  @override
  Future<void> deleteMessage(ChatMessage msg) async {
    await db.deleteMessage(msg.msgId);
    final path = msg.filePath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {} // 이미 없어졌다 — 괜찮다
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

  // ---- 헬퍼 ----

  /// [_patchStatus]와 같지만 저장된 파일 경로도 함께 붙인다(수신 전송이 제자리에서
  /// 완료되는 경우).
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
    // 받은편지함 요약을 동기화 상태로 유지한다(이는 lastMessages를 읽는다);
    // 그러지 않으면 그 행이 예전의 실패한 msgId에 영원히 갇힌다.
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
    _beaconPulseTimer?.cancel();
    _startRetryTimer?.cancel();
    _adaptiveTimer?.cancel();
    _sub?.cancel();
    _rssiSub?.cancel();
    _availabilitySub?.cancel();
    node.dispose();
    super.dispose(); // MeshFrontendState가 에러 스트림을 닫는다
  }
}
