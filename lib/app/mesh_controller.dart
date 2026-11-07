import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../core/ble/radio_profile.dart';
import '../core/ble/mesh_transport.dart'
    show
        RadioStatus,
        RssiSample,
        bleLogSink,
        knownPeersLoad,
        knownPeersSave,
        bondedPeersLoad,
        bondedPeersSave,
        advertiseSlotYield;
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
import '../data/avatar_codec.dart';
import '../data/identity_store.dart';
import '../data/models.dart';
import '../l10n/l10n.dart';
import 'background_service.dart';
import 'app_paths.dart';
import 'beacon_wake.dart';
import 'device_location.dart';
import 'encounter_tracker.dart';
import 'mesh_frontend.dart';
import 'mesh_frontend_state.dart';
import 'notification_service.dart';
import 'wake_torch_keeper.dart';

export 'mesh_frontend.dart' show ConversationSummary, MeshFrontend;

part 'mesh_controller_background.dart';
part 'mesh_controller_contacts.dart';
part 'mesh_controller_transfer.dart';

/// [MeshController]의 공유 상태 및 기본 계약. 하위 책임별 mixin들이 이 베이스
/// 클래스를 `on` 제약으로 삼아 [ChangeNotifier] / [MeshFrontendState] /
/// [LocalFileActions]의 `@protected` 멤버에 직접 접근한다.
abstract class _MeshControllerBase extends MeshFrontend
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

  /// 웨이크 토치가 꺼진 채 굳지 않게 지킨다 — 슬롯 양보 후 재점화, 헤드리스
  /// (Android 서비스)에서 주기 재확정([WakeTorchKeeper] 참고).
  late final WakeTorchKeeper _torch = WakeTorchKeeper(
    start: BeaconWake.startTx,
    stop: BeaconWake.stopTx,
    log: (line) =>
        bleLogSink?.call('${DateTime.now().toIso8601String()} $line'),
  );

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

  /// 수동(부스트) 펄스의 연타 방지 쿨다운. 펄스 1주기(40s 갭)+ENTER 여유보다
  /// 길게 잡아, 연속 당김이 TX 블랙아웃을 이어 붙이지 못하게 한다.
  DateTime? _lastManualPulse;
  static const Duration _manualPulseCooldown = Duration(seconds: 90);

  /// 웨이크 넛지 알림의 기본 쿨다운(디스크 스탬프 기준).
  static const Duration _nudgeCooldown = Duration(minutes: 15);

  /// 링크가 방금 끊겼을 때 웨이크 넛지의 잔여 쿨다운 상한 — "끊긴 직후"가
  /// 사용자가 알림을 가장 필요로 하는 순간이다. [_relaxWakeNudgeCooldown] 참고.
  static const Duration _nudgeAfterDrop = Duration(minutes: 2);
  StreamSubscription? _sub;
  StreamSubscription? _rssiSub;
  StreamSubscription? _availabilitySub;

  /// 이 플랫폼의 무선/웨이크 정책([RadioProfile]) — 앱 계층의 OS별 결정도
  /// 전부 이 객체를 거친다. 새 플랫폼은 프로파일 한 줄로 편입된다.
  ///
  /// 주입 가능하다: iOS 전용 정책(포그라운드 재조정 등)의 동작을 맥에서
  /// 단위 테스트로 고정할 수 있어야 한다 — 실기기에서만 재현되는 정책 결함이
  /// 이 계층의 사고 대부분이었다.
  final RadioProfile profile;

  /// 메시가 아직 시작되지 않은 동안의 주기적 폴백 재시도. [availabilityChanged]는
  /// BLE 어댑터가 켜질 때 발생하지만, 런타임 BLE 권한이 부여될 때는 발생하지
  /// 않는다(어댑터 상태 변화가 없음) — 그래서 최초 설치 사용자가 실행 후
  /// 블루투스를 켜거나 권한을 부여하면 앱을 재시작하기 전까지 오래된 "블루투스
  /// 꺼짐" 배너에 머무르게 된다. 느린 틱마다 시작을 재시도하면 재시작 없이 두
  /// 경우 모두 복구한다.
  Timer? _startRetryTimer;

  /// 멀티홉 BLE 예산 초과로 보류된 발신 파일(peerHex → msgId들). 상대가
  /// 직접(1홉) 나타나는 순간 자동 재전송된다. DB의 queued 상태와 함께
  /// 이중으로 기억돼 재기동을 견딘다.
  final Map<String, Set<String>> _deferredFiles = {};
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

  /// 메시지 테이블의 단조 증가 리비전. 이 값이 바뀔 때마다 원격 UI는 열려 있는
  /// 대화를 (공유) DB에서 다시 불러온다 — isolate 포트로 메시지 목록을
  /// 직렬화하는 것보다 저렴하고 간단하다.
  int msgRev = 0;

  /// 스쳐간 친구 기록이 바뀔 때마다 증가(화면 새로고침 신호, 스냅샷에 실림).
  @override
  int encounterRev = 0;
  EncounterTracker? _encounters;
  bool _encounterLocationEnabled = true;
  bool _resolvingPlaces = false;

  String? _myAvatar;
  bool _avatarCustomized = true; // 로드 전 기본값: 넛지를 잘못 띄우지 않게

  /// 내 QR에 실어 내보낸 논스들(발급 시각 포함). QR 화면을 직접 본 사람만
  /// 알 수 있는 비밀값 — 유효기간 안에 되돌아오면 보낸 상대를 인증된 친구로
  /// 승격한다. 같은 화면을 여러 명이 스캔할 수 있으므로 일회용이 아니라
  /// 유효기간제다(화면을 봤다는 사실 자체가 신뢰 모델의 기준).
  final List<(Uint8List, DateTime)> _qrNonces = [];
  static const Duration _qrNonceTtl = Duration(minutes: 10);
  static const Duration _qrNonceRotate = Duration(minutes: 5);

  /// 논스 증명이 상대의 ANNOUNCE(연락처 생성)보다 먼저 도착한 경우의 보류분.
  final Set<String> _pendingVerified = {};

  /// dispose 이후의 늦은 async 완료가 notifyListeners를 부르지 않게 하는 가드.
  bool _disposed = false;

  /// iOS 비콘 리전 모니터링이 켜져 있을 때 true("항상" 위치 권한이 부여됐고
  /// 사용자가 토글을 켠 경우). Android에서는 의미 없다.
  @override
  bool beaconMonitoring = false;

  @override
  bool beaconNeedsAlways = false;

  _MeshControllerBase({
    required this.identity,
    required this.displayName,
    required this.db,
    required this.identityStore,
    MeshNode? node,
    void Function(String conversationKey, String title, String body)? notifier,
    this.headless = false,
    RadioProfile? profile,
  })  : profile = profile ?? RadioProfile.forCurrentPlatform(),
        node = node ??
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

  /// 생성 시각 — 무선 판정의 과도 구간을 재는 기준.
  final DateTime _createdAt = DateTime.now();

  @override
  bool get radioVerdictSettled =>
      started ||
      radioStatus == RadioStatus.poweredOff ||
      DateTime.now().difference(_createdAt) > const Duration(seconds: 8);

  @override
  PeerId get myId => identity.peerId;

  /// 고빈도 프레즌스 이벤트(RSSI 샘플, ANNOUNCE)의 notify를 200ms로
  /// 코얼레싱한다. 3명일 땐 무의미하지만 100명이면 초당 ~7회의 announce가
  /// 각각 전체 UI 리빌드(주변 목록 정렬 + 레이더 배치 + Android 브리지
  /// 스냅샷 직렬화)를 일으킨다 — 사람 눈에는 200ms 갱신이면 실시간이다.
  /// 사용자 행동(전송·삭제 등)의 notify는 기존대로 즉발이다.
  Timer? _notifyCoalesce;
  void _notifyCoalesced() {
    if (_disposed || _notifyCoalesce != null) return;
    _notifyCoalesce = Timer(const Duration(milliseconds: 200), () {
      _notifyCoalesce = null;
      if (!_disposed) notifyListeners();
    });
  }

  /// 피어별 평활화된 신호 강도: 원시 BLE RSSI는 심하게 흔들리므로, 지수 이동
  /// 평균(EMA)으로 근접 UI가 떨리지 않게 한다.
  /// 마지막으로 SpotLink 광고(또는 링크 RSSI)를 관측한 시각 — 웨이크 넛지의
  /// "정말 근처에 친구가 있나" 증거로 쓴다. iOS에서 링크 0일 때의 샘플은
  /// 곧 SpotLink 매칭 광고를 봤다는 뜻이다.
  DateTime? _lastRssiAt;

  void _onRssi(RssiSample s) {
    _lastRssiAt = DateTime.now();
    final peer = s.peer;
    if (peer == null) return; // 출처를 알 수 없는 측정값
    final hex = peer.hex;
    final old = rssiSmoothed[hex];
    rssiSmoothed[hex] =
        old == null ? s.rssi.toDouble() : old * 0.6 + s.rssi * 0.4;
    rssiSeenAt[hex] = DateTime.now().millisecondsSinceEpoch;
    _notifyCoalesced();
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

  void _bumpRev() => msgRev++;
}

/// 애플리케이션의 "두뇌": [MeshNode]를 소유하고, [AppDatabase]에 영속화하며,
/// [MeshFrontend]를 통해 관찰 가능한 상태를 노출한다. iOS에서는 UI isolate에서
/// 실행되고, Android에서는 foreground-service isolate(headless)에서 실행되며 이
/// 경우 UI는 대신 [RemoteMeshController]를 통해 연결된다.
///
/// 프레즌스 / 로스터 / 받은편지함 조회와 로컬 파일 동작은 공유 mixin인
/// [MeshFrontendState] / [LocalFileActions]에 들어 있다.
class MeshController extends _MeshControllerBase
    with
        _MeshControllerBackground,
        _MeshControllerContacts,
        _MeshControllerTransfer {
  MeshController({
    required super.identity,
    required super.displayName,
    required super.db,
    required super.identityStore,
    super.node,
    super.notifier,
    super.headless = false,
    super.profile,
  });

  Future<void> init() async {
    await _wireKnownPeersStore();
    // 유령 META가 이미 받은 파일 말풍선을 failed로 뒤집어 놓은 것을 복구:
    // 파일이 디스크에 있다(=수신을 끝냈다는 증거)면 received로 되돌린다.
    // 멱등 위생 — 정상 상태에서는 0건이다.
    try {
      final repaired = await db.repairIncomingFilesWithLocalPath();
      if (repaired > 0) {
        bleLogSink?.call('${DateTime.now().toIso8601String()} '
            'repaired $repaired ghost-failed incoming file(s)');
      }
    } catch (_) {}
    // "가까워지면 전달" 큐 복원: 지난 세션에서 멀티홉 예산에 걸려 보류된
    // 발신 파일들 — 상대가 직접(1홉) 나타나면 자동 재전송된다.
    try {
      for (final m in await db.queuedOutgoingFiles()) {
        (_deferredFiles[m.peerHex] ??= {}).add(m.msgId);
      }
    } catch (_) {}
    // 수신 전송은 우리 컨테이너의 디스크에서 조립된다(systemTemp가 아님 —
    // iOS는 압박을 받으면 이를 비울 수 있고, 전송 도중이면 part 파일이 손상된다).
    try {
      final docs = await AppPaths.dataDir();
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
    _encounterLocationEnabled = await EncounterSettings.locationEnabled();
    _encounters = EncounterTracker(
      db: db,
      locate: _locateForEncounter,
      sendAuto: (peerHex, text) async {
        bleLogSink?.call('${DateTime.now().toIso8601String()} '
            'auto-message -> ${PeerId.fromHex(peerHex).short}');
        await sendText(peerHex, text);
      },
      isForeground: () => _foreground,
      locationEnabled: EncounterSettings.locationEnabled,
      onChanged: () {
        encounterRev++;
        _notifyCoalesced();
      },
    );
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

    // 첫 announce가 나가기 전에 저장된 아바타 레시피를 노드에 싣는다.
    // 없으면 무작위 기본 아바타를 만들어 시작한다 — 모두가 첫날부터
    // 캐릭터를 갖고, "커스텀 유도" 넛지의 출발점이 된다.
    try {
      _myAvatar = await identityStore.storedAvatar();
      var customized = await identityStore.avatarCustomized();
      if (_myAvatar != null && customized == null) {
        // 구버전에서 올라온 사용자: 이미 빌더로 만든 아바타 — 커스텀 간주.
        customized = true;
        await identityStore.setAvatarCustomized(true);
      }
      if (_myAvatar == null) {
        _myAvatar = AvatarCodec.randomCompact();
        await identityStore.setAvatar(_myAvatar!);
        customized = false;
        await identityStore.setAvatarCustomized(false);
      }
      _avatarCustomized = customized ?? false;
      node.avatarRecipe = _myAvatar;
    } catch (_) {} // 저장소 불가(테스트/플러그인 없음) — 아바타 없이 진행

    _sub = node.events.listen(_onEvent);
    _rssiSub = node.rssiSamples.listen(_onRssi);
    // 슬롯 경합 시 토치를 양보시킨다([advertiseSlotYield] 참고). 메시 광고가
    // 실패하면 이 노드는 어떤 스캔에도 보이지 않으므로 토치보다 우선한다.
    advertiseSlotYield = _torch.yieldSlot;
    started = await node.start();
    // Wake-beacon TX: Android는 항상 송신하고(백그라운드 OK); iOS는 foreground
    // 상태일 때만 송신한다 — resume될 때마다 다시 확정한다. 이것이 근처의
    // 스와이프-강제종료된 아이폰을 되살린다(그들은 이 비콘의 리전을 모니터링한다).
    //
    // **반드시 node.start() 뒤에 켠다.** 일부 Samsung은 레거시 광고 인스턴스를
    // 하나만 지원해서, 토치가 먼저 슬롯을 잡으면 메시 광고가 code 2로 영영
    // 실패하고 그 폰은 BLE 스캔에 보이지 않게 된다 — 그런데 토치는 계속 돌아
    // 주변 iPhone을 깨우므로 "알림은 오는데 레이더엔 없는" 증상이 된다.
    unawaited(BeaconWake.startTx());
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
    // +3s가 지나면 상태가 안정된다: 진짜 포그라운드 실행은 `resumed`이므로 —
    // 그렇지 않은 모든 상태는 백그라운드로 보고 OS가 요구하는 필터링된 스캔으로
    // 전환한다.
    //
    // 예전에는 `paused|detached|hidden`만 백그라운드로 쳤는데, 백그라운드
    // 재기동의 **실제 시그니처는 `inactive`(또는 null)** 여서 이 재확인이
    // 그대로 통과했다 → 전송은 부팅 낙관값 true에 머물고, 컨트롤러 쪽 플래그는
    // false로 계산돼 재조정 비교가 영구히 일치, 아무도 이를 바로잡지 못했다
    // (2026-07-30 heavy 11:09 비콘 웨이크: 백그라운드인데 무필터 스캔으로 돌아
    // iOS가 광고를 하나도 전달하지 않았고, 12번의 웨이크 내내 발견 0건).
    // 넛지·재조정과 같은 판정 기준("+3s면 진짜 포그라운드는 resumed")을 쓴다.
    //
    // [RadioProfile.reconcilesForegroundMode]가 있는 플랫폼에서만 한다. 데스크톱
    // 은 창이 포커스를 잃으면 `inactive`가 되는데 OS가 앱을 서스펜드하지도,
    // 스캔에 필터를 강제하지도 않는다 — 거기서 이 재확인을 돌리면 실행 3초 안에
    // 다른 창을 클릭한 것만으로 맥이 필터 스캔에 갇히고, 되돌릴 재조정 틱조차
    // 없어 다시 조용히 눈먼다(맥 16일 실명과 같은 계열의 사고).
    if (!headless && profile.reconcilesForegroundMode) {
      _bootFgRecheck = Timer(const Duration(seconds: 3), () {
        node.setForeground(WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed);
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
      _superviseMaintenance();
      _maybeBeaconPulse();
      // 네이티브 웨이크 토치에 생존 신호를 보낸다 — 이 타이머(=메시 소유
      // isolate)가 멎으면 토치도 꺼져야 한다([BeaconWake.heartbeat]).
      unawaited(BeaconWake.heartbeat());
      // Android 서비스에는 토치를 다시 켜 주는 수명주기·펄스가 없다 — 슬롯
      // 양보나 심박 게이트로 꺼진 토치를 여기서 되살린다.
      if (headless) _torch.tick();
      // 부팅 시에만 하지 않고 폴링하여, 한 번도 링크되지 않은 wake뿐 아니라
      // 나중에 끊겨 다시 맺지 못한 링크까지 넛지가 다루도록 한다.
      if (profile.reconcilesForegroundMode && !headless) {
        _reconcileForegroundMode();
        unawaited(_maybeWakeNudge());
      }
      notifyListeners();
    });
    // 적응형 BLE 전력(Android 전용). 지금 한 번, 그리고 느린 틱마다 평가한다.
    if (profile.usesAdaptivePower) {
      unawaited(_evaluateAdaptivePower());
      _adaptiveTimer = Timer.periodic(
          _MeshControllerBase._adaptiveInterval,
          (_) => unawaited(_evaluateAdaptivePower()));
    }
    notifyListeners();
  }

  /// 테스트 훅: 실제 생명주기 이벤트 없이 앱 foreground 플래그를 조작한다.
  @visibleForTesting
  void setForegroundForTest(bool value) => _foreground = value;

  /// 테스트 훅: 프레즌스 틱을 10초 기다리지 않고 포그라운드 재조정만 돌린다.
  @visibleForTesting
  void reconcileForegroundModeForTest() => _reconcileForegroundMode();

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
        'encRev': encounterRev,
        'contacts': [for (final c in contactList) c.toMap()],
        'meAvatar': _myAvatar,
        'meAvCustom': _avatarCustomized,
        'seen': lastSeenAt,
        'hops': lastHopCount,
        'via': lastViaHex,
        'lanes': liveLanes,
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

  static (Uint8List, String, Uint8List?)? parseQr(String payload) =>
      QrPayload.decode(payload);

  Future<void> _onEvent(NodeEvent e) async {
    switch (e) {
      case LinksChanged(:final count):
        final hadLinks = linkCount > 0;
        linkCount = count;
        peerCount = node.peerCount; // 서로 다른 기기(C:/P: 중복 제거됨)
        if (count > 0) _everLinked = true; // → 향후 펄스는 drop 주기로
        _linklessSince = count == 0 ? (_linklessSince ?? DateTime.now()) : null;
        // 방금 마지막 링크가 끊겼다: 직전 넛지의 15분 쿨다운이 남아 있으면
        // 정작 필요한 순간에 침묵하므로 잔여를 짧게 되감는다.
        if (hadLinks && count == 0) unawaited(_relaxWakeNudgeCooldown());
        // 토폴로지 변화는 빠른 (재)합류를 위해 잠깐의 low-latency 버스트를 얻는다.
        _lastTopoChange = DateTime.now();
        if (profile.usesAdaptivePower) unawaited(_evaluateAdaptivePower());
        BackgroundService.updateStatus(count);
        notifyListeners();
      case PeerAnnounced(:final contact, :final hops, :final via, :final avatar):
        lastSeenAt[contact.peerId.hex] =
            DateTime.now().millisecondsSinceEpoch;
        lastHopCount[contact.peerId.hex] = hops;
        // 중계 경로: 멀티홉일 때만 기록한다. 직접 announce가 오면 지워서
        // "직접 링크로 승격"이 레이더에서 즉시 반영되게 한다.
        if (hops > 1 && via != null) {
          lastViaHex[contact.peerId.hex] = via.hex;
        } else {
          lastViaHex.remove(contact.peerId.hex);
        }
        await _rememberAnnounced(contact, avatar: avatar);
        // 스쳐간 친구 기록 + 자동 메시지(연결됐으니 이제 누구인지 안다).
        final known = contactByHex(contact.peerId.hex);
        if (known != null) {
          unawaited(_encounters?.onPeerSeen(known, hops: hops));
        }
        // 직접(1홉)으로 승격됐다: 멀티홉 예산에 걸려 보류됐던 파일들을
        // 자동 재전송한다(이제 패스트레인/1홉 BLE 모두 가능).
        if (hops == 1 && _deferredFiles.containsKey(contact.peerId.hex)) {
          unawaited(_flushDeferredFiles(contact.peerId.hex));
        }
        // QR로 검증된 친구가 직접 링크로 살아 있다: OS 본딩을 유도해 이후의
        // 주소 회전이 대기 연결을 죽이지 못하게 한다(세션당 1회, 전송
        // 계층에서 중복 방지).
        if (contactByHex(contact.peerId.hex)?.verified ?? false) {
          unawaited(node.ensureBonded(contact.peerId.hex));
        }
        _notifyCoalesced(); // 100명 규모에서 announce는 초당 수 회다
      case VerifyReceived(:final from, :final nonce):
        if (!_validQrNonce(nonce)) {
          // 만료됐거나 위조된 논스 — 원격 위장 시도일 수 있으니 승격하지 않는다.
          bleLogSink?.call('QR verify rejected (invalid nonce) '
              'from ${from.short}');
          break;
        }
        bleLogSink?.call('QR mutual verify ok from ${from.short}');
        final existing0 = contactByHex(from.hex) ?? await db.contact(from.hex);
        if (existing0 != null) {
          final updated = existing0.copyWith(verified: true);
          await db.upsertContact(updated);
          replaceContact(updated);
        } else {
          // 아직 ANNOUNCE 전 — 연락처가 생길 때 승격한다.
          _pendingVerified.add(from.hex);
        }
        _bumpRev();
        notifyListeners();
      case ReactionReceived(
          :final from,
          :final targetMsgIdHex,
          :final emoji,
          :final removed
        ):
        if (removed) {
          await db.removeReaction(targetMsgIdHex, emoji, false);
          reactionCache[targetMsgIdHex]
              ?.removeWhere((r) => !r.fromMe && r.emoji == emoji);
        } else {
          await db.addReaction(from.hex, targetMsgIdHex, emoji, false);
          final list = reactionCache[targetMsgIdHex] ??= [];
          if (!list.any((r) => !r.fromMe && r.emoji == emoji)) {
            list.add(Reaction(
                msgId: targetMsgIdHex, emoji: emoji, fromMe: false));
          }
          // 화면을 보고 있지 않으면 가벼운 알림 — 텍스트 수신과 같은 규칙.
          _notifyIncoming(from, systemS.notifReaction(emoji));
        }
        _bumpRev();
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
      case TransferLane(:final transferIdHex, :final lane):
        if (liveLanes[transferIdHex] != lane) {
          liveLanes[transferIdHex] = lane;
          await db.updateLaneByMsgId(transferIdHex, lane);
          _bumpRev(); // 원격 UI가 열린 대화를 다시 읽어 경로 칩을 갱신한다
          notifyListeners();
        }
      case FileSuperseded(:final oldTransferIdHex):
        // 재시도로 대체된 유령 수신 말풍선: 실패로 남기지 말고 지운다 —
        // 성공한 재시도 옆의 "수신 실패"는 사용자에게 거짓말이다.
        await db.deleteMessage(oldTransferIdHex);
        transferProgress.remove(oldTransferIdHex);
        liveLanes.remove(oldTransferIdHex);
        for (final msgs in conversationCache.values) {
          msgs.removeWhere((m) => m.msgId == oldTransferIdHex);
        }
        lastMessages.removeWhere((_, m) => m.msgId == oldTransferIdHex);
        _bumpRev();
        notifyListeners();
      case FileReceived(:final from, :final meta, :final path):
        await _onFileReceived(from, meta, path);
      case FileFailed(:final transferIdHex):
        transferProgress.remove(transferIdHex);
        await _applyStatus(transferIdHex, MsgStatus.failed);
      case FileDeferred(:final transferIdHex, :final to):
        // 실패가 아니라 대기: 말풍선이 "만나면 자동 전달"로 표시되고,
        // 상대가 직접 나타나면 재전송된다.
        transferProgress.remove(transferIdHex);
        await _applyStatus(transferIdHex, MsgStatus.queued);
        (_deferredFiles[to.hex] ??= {}).add(transferIdHex);
      case NodeError(:final message):
        lastError = message;
        reportError(message);
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (!headless) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _notifyCoalesce?.cancel();
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
