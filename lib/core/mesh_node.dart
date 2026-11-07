import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'ble/mesh_transport.dart';
import 'ble/radio_health.dart';
import 'crypto/identity.dart';
import 'crypto/session.dart';
import 'model/announce.dart';
import 'model/frame.dart';
import 'model/peer_id.dart';
import 'model/text_envelope.dart';
import 'node_events.dart';
import 'router/router.dart';
import 'router/seen_cache.dart';
import 'router/store_forward.dart';
import 'transfer/fast_lane.dart';
import 'transfer/file_transfer.dart';

export 'node_events.dart';

part 'mesh_node_receive.dart';
part 'mesh_node_transfer.dart';
part 'mesh_node_fast_lane.dart';

/// 완료된 수신 전송 id의 영속화 훅(앱 계층이 작은 JSON 파일로 연결).
/// 없으면 완료 기억이 메모리에만 남아, 재시작 후 스토어가 재전달한 META를
/// 새 수신으로 착각한다 — 바이트는 영영 오지 않으므로 "수신 실패" 유령
/// 말풍선이 생기고, 심하면 이미 받은 말풍선의 상태를 뒤집는다(2026-07-20
/// 02:02 gold 관찰).
Future<List<String>> Function()? completedTransfersLoad;
void Function(List<String> tids)? completedTransfersSave;

/// ACK 페이로드 종류(ACK 프레임에서 복호화와 무관한 페이로드의 첫 바이트).
class _AckKind {
  static const int message = 0; // 뒤에 16바이트 acked msgId가 이어짐
  static const int file = 1; // 뒤에 FileAck 바이트가 이어짐
}

/// 앱의 심장부: 원시 BLE 패킷을 암호화된 멀티홉 store-and-forward 메시징
/// 서비스로 변환한다. 플랫폼 BLE는 전적으로 [MeshTransport]에 있고,
/// 라우팅/암호화/전송은 테스트를 거친 순수 모듈이다.
class MeshNode {
  final Identity identity;

  /// 우리가 광고하는 표시 이름. 사용자가 실시간으로 변경할 수 있도록 가변이며,
  /// 변경 시 현재 이웃들에게 다시 announce한다([updateDisplayName] 참고).
  String displayName;

  /// 내 파츠 아바타 레시피(compact) — ANNOUNCE에 실려 이웃에게 전파된다.
  /// null이면 필드 자체가 생략된다(구버전과 동일한 프레임).
  String? avatarRecipe;

  late final MeshTransportInterface transport;
  late final Router router;
  late final SessionCrypto crypto;
  final SeenCache seen;
  final StoreForward store;

  /// peer id hex별로 알고 있는 kex 공개키(ANNOUNCE 또는 연락처를 통해 학습).
  final Map<String, Uint8List> _knownKex = {};

  /// peer id hex별로 알고 있는 Ed25519 서명 키. ANNOUNCE에서 학습해도 안전하다:
  /// peer id는 SHA-256(bundle)이므로 키와 id가 암호학적으로 묶여 있다.
  /// 전달 영수증(receipt) 검증에 사용된다.
  final Map<String, Uint8List> _knownSigning = {};

  /// 툼스톤(tombstone): 서명된 영수증으로 전달이 입증된 msgId들. 다시는 저장,
  /// 릴레이, 재요청(re-pull)되지 않는다(정리 도중 오프라인이던 폰이 "좀비"처럼
  /// 되살리는 것을 방지). 재시작 시 [rebuildReceipts]를 통해 영속화된
  /// 영수증에서 재구성된다.
  final _receipted = <String>{};
  static const int _receiptedCap = 4096;

  /// 진행 중인 전송들.
  final Map<String, FileSender> _senders = {};
  final Map<String, FileReceiver> _receivers = {};
  final Map<String, PeerId> _receiverPeers = {};

  /// 발신 전송별 META 프레임 msgId — 전송 종료 시 영속 사본 정리에 쓴다.
  final Map<String, String> _metaMsgIdByTid = {};

  /// 청크가 도착하는 동안 수신 전송의 부분 파일이 저장되는 위치.
  /// 앱 계층은 이를 자신의 documents 디렉터리로 지정한다; 기본값은 별도 설정
  /// 없이도 테스트와 headless 사용이 동작하도록 유지해준다.
  String Function(String tidHex) incomingPartPath = (tid) =>
      '${Directory.systemTemp.path}/spotlink_incoming_$tid.part';

  /// 수신 측 복구 타이머: 전송이 미완료인 동안 누락된 seq를 주기적으로 다시
  /// ACK하여, 유실된 마지막 부분(tail) 때문에 영원히 멈춰 있지 않도록 한다.
  final Map<String, Timer> _rxTimers = {};

  /// 전송 측 감시 타이머: 끝내 완료되지 않는 전송을 폐기한다.
  final Map<String, Timer> _senderTimers = {};

  /// 완료 ACK 재송신 타이머들 — stop() 시 취소.
  final List<Timer> _ackRepeatTimers = [];

  /// 수신을 마친 전송들 — 유실된 최종 ACK(그대로 두면 전송 측이 발이 묶임)를
  /// 중복 청크가 도착할 때 다시 보낼 수 있도록 잠시 보관해둔다.
  final Set<String> _completedTransfers = {};

  /// 완료 처리(스트리밍 해시 검증 + finalize)가 진행 중인 전송들. finalize()는
  /// 최대 [maxFileBytes]까지의 디스크 I/O를 기다리며, 그동안 수신자는 여전히
  /// [_receivers]에 남아 있다; 그 사이에 떠도는/중복 청크(BLE)나 다른 경로
  /// (fast lane)가 도착하면 finalize에 다시 진입해 FileReceived를 중복
  /// 방출하거나 무결성 실패를 잘못 보고하게 된다. 두 완료 지점 모두 이것으로
  /// 게이트를 건다.
  final Set<String> _finalizing = {};

  /// BLE로 전송하는 단일 파일의 합리적 상한(docs §8 참고).
  static const int maxFileBytes = 100 * 1024 * 1024;
  static const Duration _fileAckInterval = Duration(milliseconds: 700);

  /// 전송은 이 시간 동안 아무런 진전이 없을 때만 실패로 처리된다 — 큰 파일이
  /// 정상적으로도 수 분씩 걸리는 BLE에서는 절대적 마감 시한을 두는 것이 잘못이다.
  static const Duration _transferIdleTimeout = Duration(seconds: 60);

  /// 첫 바이트가 오기 전의 수신 대기 상한. 전송 측이 파일들을 fast lane에
  /// 한 건씩 직렬화하므로, 뒤 파일의 수신자는 앞 파일이 끝날 때까지 조용히
  /// 기다리는 것이 정상이다 — 60초 리퍼가 이를 죽이면 뒤 파일이 도착해도
  /// 조립할 수신자가 없다.
  static const Duration _transferQueuedTimeout = Duration(minutes: 5);

  /// 수신 측 ACK 정책: 전송 측이 [_ackIdleGap] 동안 조용하면(버스트 종료 /
  /// 멈춤) 누락된 청크를 요청하고, 활성 버스트 중에는 [_ackHeartbeat]마다 느린
  /// 하트비트를 보내 전송 측이 우리가 살아 있음을 알게 한다.
  static const Duration _ackIdleGap = Duration(seconds: 2);
  static const Duration _ackHeartbeat = Duration(seconds: 5);

  /// 하나의 ACK에 담는 누락 목록 상한: seq당 4B이므로 이 값이 ACK 프레임을
  /// 작게 유지한다; 이후 ACK들이 남은 빈 구간을 반복적으로 보고한다.
  static const int _ackMaxMissing = 64;

  /// 초기 청크 버스트가 아직 스트리밍 중인 전송들. 그동안 재전송 요청은
  /// 무시된다 — 요청된 청크는 이미 가는 중이고, 요청을 받아주면 버스트 전체가
  /// 중복될 것이기 때문이다.
  final Set<String> _streaming = {};

  /// 전송별 수신 측 생존/ack 관리 정보.
  final Map<String, DateTime> _rxLastChunk = {};
  final Map<String, DateTime> _rxLastAck = {};
  final Map<String, int> _rxLastPct = {};

  /// 이웃들에게 존재(presence)를 얼마나 자주 다시 announce하는지 — 멀어진
  /// 피어가 "주변"에서 만료되어 사라질 수 있도록 한다. 연락처 메타데이터도
  /// 갱신한다.
  static const Duration announceInterval = Duration(seconds: 8);

  /// presence는 이만큼의 홉 수로 플러딩되어, 릴레이를 통해 도달 가능한 피어가
  /// "주변 · n홉"으로 표시된다. [Router.defaultTtl]보다 일부러 작게 잡았다:
  /// presence는 수다스럽고(모든 노드가 15초마다) 그 프라이버시 영향 반경은
  /// 작게 유지되어야 하는 반면, 메시지는 여전히 7홉을 온전히 이동할 수 있다.
  static const int announceTtl = 3;

  /// 텍스트 메시지와 그 종단 간 ACK, 전달 영수증을 위한 TTL.
  /// 사람 규모의 메시(6단계 분리 정도의 지름)에서는 사실상 무한대다:
  /// 중복 억제 덕분에 프레임은 TTL과 무관하게 링크당 한 번만 전송되므로, 큰
  /// 값이라도 추가 비용이 전혀 없다 — 단지 store-and-forward된 프레임이 수많은
  /// 만남을 거쳐 계속 이동("언젠가 전달")할 수 있게 해줄 뿐이다. 좀비 방지
  /// 안전장치로 u8 최댓값보다는 낮게 유지한다. 파일은 기본값 7을 유지한다
  /// (덩치 큰 페이로드).
  static const int durableTtl = 64;
  Timer? _announceTimer;

  /// 종단 간 ACK를 기다리는 텍스트 메시지들, 확인될 때까지 재전송된다.
  final Map<String, _PendingText> _awaitingAck = {};
  Timer? _retransmitTimer;
  final Duration retransmitInterval;

  /// 활성(LIVE) 링크에서의 주기적 HAVE 재동기화. 링크 연결 시점의 HAVE만으로는
  /// 구멍이 남는다: A—R—B에서 R→B 릴레이 홉이 프레임을 하나 떨어뜨리면, A의
  /// 재전송(같은 msgId)은 R의 seen-cache에 중복으로 흡수되어 다시 릴레이되지
  /// 않는다 — 모든 링크가 안정적이면 R이 저장해둔 사본을 B에게 다시 제안하는
  /// 것이 아무것도 없어, 텍스트는 어떤 링크가 우연히 끊겼다 붙기 전까지 미전달
  /// 상태로 남는다. 우리 저장소 목록(inventory)을 타이머로 다시 보내면 이웃이
  /// 놓친 것을 무엇이든 WANT할 수 있어, 재연결을 기다리지 않고 손실 구간을
  /// 닫아준다.
  Timer? _haveTimer;
  final Duration haveInterval;
  final int maxTextAttempts;

  /// 최종 전달 상태에 도달한 msg id들 — 같은 메시지에 대해 DeliveryConfirmed와
  /// TextDeliveryFailed를 둘 다 방출하지 않도록 한다(늦게 도착한 ACK가 포기
  /// 틱과 경쟁할 수 있다). 항상 전달(delivery)이 이긴다.
  final _confirmedText = <String>{};

  /// 로컬에 전달된 메시지의 경계가 있는(bounded) 중복 제거. 라우팅 seen-cache는
  /// 10분 뒤 만료되지만(루프 방지용), 더 오래 사는 이 가드는 재요청된
  /// store-and-forward 프레임이 앱에 두 번 전달되는 것을 막는다.
  final _deliveredIncoming = <String>{};
  static const int _deliveredIncomingCap = 2048;

  /// 우리 앞으로 온 메시지 중, 라우터가 seen으로 표시했지만(루프 방지) 앱까지
  /// 도달하는 데 실패한 것들 — 복호화가 예외를 던졌거나(불안정한 링크에서 온
  /// 손상된 페이로드), 아직 전송 측의 키를 몰랐던 경우다. 이것이 없으면
  /// 영원히 잃어버렸다: seen-cache 때문에 [selectWanted]가 이들을 더 이상
  /// 요청하지 않고, 라우터도 재전송을 "중복"으로 버려서, 깨진 전달 한 번이
  /// 조용히 메시지를 삼켜버릴 수 있었다(관측: 3개 전송, 가운데 것이 끝내 도착
  /// 안 함). 여기에 추적해 두어 새 사본을 계속 WANT하고, 그것(또는 재전송)이
  /// 도착하면 실제로 도달할 때까지 전달을 다시 수행한다.
  final _pendingLocalDelivery = <String>{};
  static const int _pendingLocalDeliveryCap = 512;

  /// [_pendingLocalDelivery]를 위한 영속화 훅(앱 계층이 작은 테이블에 기록):
  /// `present`가 true = 추가, false = 제거. 미전달 메시지가 인메모리 라우팅
  /// seen-cache 뒤에 다시 발이 묶이는 대신 재시작을 견디고 살아남게 해준다.
  void Function(String msgIdHex, bool present)? onPendingLocalChanged;

  /// 시작 시 영속화된 pending-delivery id들을 다시 로드한다.
  void seedPendingLocalDelivery(Iterable<String> ids) {
    for (final id in ids) {
      if (_deliveredIncoming.contains(id)) continue;
      _pendingLocalDelivery.add(id);
    }
  }

  final _events = StreamController<NodeEvent>.broadcast();
  final List<StreamSubscription> _subs = [];

  /// 선택적 Wi-Fi 대용량 가속기. Null ⇒ 모든 전송이 BLE 청킹을 사용한다
  /// (기존 동작 그대로). 존재하면 큰 파일은 직접 Wi-Fi 채널로 업그레이드되며
  /// 자동 BLE 폴백을 갖는다. docs/WIFI_HYBRID_DESIGN.md 참고.
  final FastLaneInterface? fastLane;

  /// 이 크기 이상인 파일만 fast lane을 시도한다 — 그 미만에서는 BLE의 설정
  /// 없는 ~1초 시작이 Wi-Fi의 수 초짜리 핸드셰이크보다 빠르다.
  static const int fastLaneMinBytes = 256 * 1024;

  /// 전송 측이 BLE 청킹으로 폴백하기 전에 fast-lane ACCEPT를 얼마나 기다리는지.
  static const Duration fastLaneNegotiateWindow = Duration(seconds: 5);

  /// 멀티홉 BLE 폴백의 파일 크기 예산. 1홉은 당사자 둘의 라디오만 쓰므로
  /// 무제한(느려도 그들의 선택); 2홉부터는 중간 노드가 모든 청크를 받았다
  /// 다시 쏘는 제3자 비용이 걸리므로 작게 잡는다. 예산 초과는 실패가 아니라
  /// [FileDeferred] — 직접 만나면 자동 재전송된다. Wi-Fi 패스트레인은 이
  /// 게이트보다 먼저 시도되므로(도달만 하면 홉 수 무관) 잃는 기회가 없다.
  static int bleBudgetBytes(int hops) =>
      hops <= 2 ? 512 * 1024 : 200 * 1024;

  /// fast-lane 와이어의 세그먼트 모드 매직. 레거시 형식의 첫 u32는 파일 전체
  /// 암호문 길이(u32 fileSize + GCM 오버헤드)라 이 값이 나올 수 없다.
  static const int fastLaneMagicSegmented = 0xFFFFFFFF;

  /// 배치 연속 매직: 한 파일의 종료 마커(0) 뒤에 이어지면 "같은 세션으로
  /// 다음 파일을 계속한다"는 뜻 — [tid 16바이트][세그먼트 매직][세그먼트…]가
  /// 따라온다. 연속 협상(특히 multipeer의 잔상 광고 문제)을 제거해 다중
  /// 파일 전송을 한 번의 협상으로 끝낸다. ACCEPT flags bit2로 협상된다.
  static const int fastLaneMagicNext = 0xFFFFFFFE;

  /// fast-lane 세그먼트 평문 크기 — 전송 중 RAM 상주 상한을 정한다.
  /// 테스트 전용으로 축소 가능(멀티 세그먼트 경로 검증).
  static int fastLaneSegmentBytes = 4 * 1024 * 1024;

  /// 테스트 전용: 수신자가 세그먼트를 지원해도 레거시 한 덩어리 형식으로
  /// 보낸다(구버전 송신자 시뮬레이션).
  static bool debugForceLegacyFastLane = false;

  /// 대기 중인 fast-lane accept들, transferId를 키로 하며, 수신 측의 ACCEPT
  /// 프레임이 도착하면 완료된다(전송 측).
  final Map<String, Completer<_FastAccept>> _fastAcceptWaiters = {};

  /// 현재 fast lane으로 전달 중인 transferId들(전송 측 또는 수신 측) — 이들에
  /// 대한 병행 BLE 청크 경로를 억제한다.
  final Set<String> _fastActive = {};

  /// 피어별 마지막 관측 홉 수(announce의 TTL 기반). fast-lane 협상 창을
  /// 멀티홉 왕복 시간에 맞춰 늘리는 데 쓴다.
  final Map<String, int> _lastHops = {};

  /// 수신 측: ACCEPT를 보내고 송신자의 연결을 기다리는 중인 수단.
  /// 송신자가 그 수단의 연결에 실패해 마스크에서 빼고 재오퍼하면, 이 값으로
  /// "대기 중인 수단이 버려졌음"을 알아채고 남은 교집합으로 재협상한다.
  final Map<String, FastLaneKind> _pendingInboundKind = {};

  /// fast-lane 대기열/협상 중인 transferId(전송 측). 아직 첫 바이트도 보내기
  /// 전이므로, 수신 측의 조바심 ACK("전 청크 누락")에 재전송으로 답하면 안
  /// 된다 — 다중 파일 선택 시 대기 중인 파일들의 재전송이 3초마다 겹치며
  /// BLE 대역을 통째로 태우는 폭풍이 관찰됐다(2026-07-17 21:52).
  final Set<String> _fastQueued = {};

  /// 같은 상대에게 fast-lane 차례를 기다리는 파일들(dstHex → tid FIFO).
  /// 락 소유자가 자기 파일을 마친 뒤 이 목록을 같은 세션으로 이어 보낸다.
  final Map<String, List<String>> _fastBatchCandidates = {};

  /// 배치로 이미 전송된 tid — 자기 차례가 왔을 때 재전송/BLE 낙하를 막는다.
  final Set<String> _batchDelivered = {};

  /// BLE 파일 스트림 직렬화 체인 — 한 링크에 대용량 청킹이 병렬로 흐르면
  /// 서로의 대역을 잡아먹고 전부 타임아웃난다(2026-07-20 11:17: 9파일 병렬
  /// 낙하 → 전멸). fast lane과 별개 체인이라 Wi-Fi 전송을 막지 않는다.
  Future<void> _bleStreamChain = Future<void>.value();

  /// 재전송 루프가 이미 도는 transferId — ACK가 3초마다 도착하는데 64청크
  /// 재전송은 그보다 오래 걸리므로, 겹치면 같은 청크의 중복 사본만 쌓인다.
  final Set<String> _resending = {};

  /// Multipeer / Wi-Fi Direct는 동시에 여러 세션을 열면 전부 실패한다
  /// (실기기: 파일 6개 동시 전송 → 6× `FT fast connect null`). 전송·수신
  /// 협상+스트림을 한 건씩 직렬화한다. BLE 폴백은 락 밖에서 돌린다.
  Future<void> _fastLaneChain = Future<void>.value();

  /// Fast-lane 연결이 방금 실패했을 때의 짧은 쿨다운(피어×수단별,
  /// `dstHex/kind` 키) — 줄 선 나머지 파일이 각자 25초씩 또 실패하며
  /// 줄 서지 않게 한다. 수단별인 이유: multipeer 한 번의 실패가 lanSocket
  /// 등 다른 수단의 시도까지 막으면 대기열 전체가 BLE로 오염된다
  /// (2026-07-20 11:17 관찰).
  final Map<String, DateTime> _fastLaneCooldownUntil = {};

  DateTime? _lastSendRecovery;

  MeshNode({
    required this.identity,
    required this.displayName,
    int Function()? clock,
    MeshTransportInterface? transport,
    this.fastLane,
    this.retransmitInterval = const Duration(seconds: 4),
    this.haveInterval = const Duration(seconds: 15),
    this.maxTextAttempts = 5,
  }) : seen = SeenCache(nowMs: clock ?? _wallClock),
       store = StoreForward(nowMs: clock ?? _wallClock) {
    router = Router(myId: identity.peerId, seen: seen);
    crypto = SessionCrypto(identity);
    this.transport =
        transport ??
        MeshTransport(
          myShortId: identity.peerId,
          infoValue: identity.publicBundle,
        );
    // 우리 자신의 키는 항상 알고 있다.
    _knownKex[identity.peerId.hex] = identity.kexPublic;
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// 수신자가 [msgId]의 전달을 입증하기 위해 서명하는, 도메인 분리된 바이트.
  static Uint8List receiptSignedBytes(Uint8List msgId) =>
      Uint8List.fromList([...utf8.encode('SL-RECEIPT-v1'), ...msgId]);

  Stream<NodeEvent> get events => _events.stream;
  PeerId get myId => identity.peerId;
  int get linkCount => transport.linkCount;
  int get peerCount => transport.peerCount;

  /// 직접 이웃들의 신호 강도 측정값(근접 UI용).
  Stream<RssiSample> get rssiSamples => transport.rssiSamples;

  /// 링크가 없을 때 **왜 없는지**에 대한 판정. 앱 계층이 알림·배너·자동복구
  /// 결정에 쓰는 공통 근거다([RadioHealth] 참고).
  RadioHealth get radioHealth => transport.health;

  /// 연락처를 등록하여 ANNOUNCE 이전에도 그들에게 암호화하고 그들로부터 복호화할
  /// 수 있게 한다(예: QR 스캔으로 추가).
  void addContact(ContactIdentity contact) {
    _knownKex[contact.peerId.hex] = contact.kexPublic;
    _knownSigning[contact.peerId.hex] = contact.signingPublic;
  }

  /// 피어의 키를 잊는다(사용자가 연락처를 삭제함). 그들이 여전히 근처에 있으면
  /// 다음 ANNOUNCE가 다시 알려준다 — 삭제는 차단이 아니다.
  void removeContact(PeerId peerId) {
    _knownKex.remove(peerId.hex);
    _knownSigning.remove(peerId.hex);
  }

  Future<bool> start() async {
    final ready = await transport.ensureReady();
    if (!ready) {
      _events.add(NodeError('Bluetooth not available/authorized'));
      return false;
    }
    try {
      _completedTransfers
          .addAll(await completedTransfersLoad?.call() ?? const []);
    } catch (_) {} // 기록 없음/손상 — 최악은 유령 META 1회
    _subs.add(transport.inbound.listen(_onPacket));
    _subs.add(transport.linkEvents.listen(_onLinkEvent));
    await transport.start();
    _announceTimer = Timer.periodic(
      announceInterval,
      (_) => _broadcastAnnounce(),
    );
    _retransmitTimer = Timer.periodic(
      retransmitInterval,
      (_) => _retransmitPending(),
    );
    _haveTimer = Timer.periodic(haveInterval, (_) => _broadcastHave());
    return true;
  }

  /// [_haveTimer] 참고. 모든 활성 링크로 HAVE 프레임 하나를 브로드캐스트한다;
  /// 각 이웃은 부족한 것을 WANT하고 우리는 링크별로 응답한다. 저장소가 비어
  /// 있거나 링크가 없으면(제안할 것이 없음 / 들을 이가 없음) 건너뛴다.
  Future<void> _broadcastHave() async {
    if (transport.linkCount == 0) return;
    var inv = store.inventory();
    if (inv.isEmpty) return;
    // 주기적 제안의 크기를 제한한다: 큰 릴레이 저장소(durable 상한 4096 × 16B =
    // 64KB)는 매 틱마다 재브로드캐스트하기엔 너무 무겁다. 가장 최근 항목이
    // 아직 전달이 필요할 가능성이 가장 높다(맵 순회는 삽입 순서를 따른다);
    // 전체 목록은 링크가 연결될 때마다 여전히 나간다.
    const cap = 512;
    if (inv.length > cap) inv = inv.sublist(inv.length - cap);
    final frame = Frame.create(
      type: FrameType.have,
      ttl: 1,
      src: myId,
      dst: PeerId.broadcast,
      payload: MsgIdList.encode(inv),
    );
    await transport.broadcast(frame.encode());
  }

  /// 확인(ACK)받지 못한 텍스트 프레임을 다시 브로드캐스트한다(L2 패킷이
  /// 유실됐거나 수신자가 범위 밖이었던 경우). 수신자는 msgId로 중복을 제거하므로
  /// 재전송은 무해하다. [_maxTextAttempts] 이후에는 포기하고 메시지를 실패로
  /// 표시한다.
  Future<void> _retransmitPending() async {
    if (_awaitingAck.isEmpty) return;
    final done = <String>[];
    for (final entry in _awaitingAck.entries.toList()) {
      final pending = entry.value;
      pending.attempts++;
      if (pending.attempts > maxTextAttempts) {
        done.add(entry.key);
        // 실시간 재전송은 끝났지만, 프레임은 durable 저장소에 그대로 남는다:
        // 수신자의 ACK가 돌아올 때까지 우리가 만나는 모든 기기에 계속 실려
        // 간다("언젠가 전달"). UI는 이를 대기 중(queued)으로 표시하고, 늦은
        // ACK가 도착하면 전달됨으로 바꾼다.
        if (!_confirmedText.contains(entry.key)) {
          _events.add(TextDeliveryFailed(entry.key));
        }
        continue;
      }
      await transport.broadcast(pending.frame.encode());
    }
    for (final k in done) {
      _awaitingAck.remove(k);
    }
  }

  /// 이모지 리액션을 보낸다(추가 또는 제거). 페이로드는 대상 msgId(16) +
  /// 플래그(1: bit0=제거) + 이모지 UTF-8 — 가장 복잡한 조합 이모지도 수십
  /// 바이트라 BLE 패킷 하나에 들어간다. store-and-forward를 타므로 상대가
  /// 오프라인이어도 다음 조우 때 도착하고, 적용은 멱등이라 중복 배달이
  /// 무해하다.
  Future<void> sendReaction(
    PeerId dst,
    String targetMsgIdHex,
    String emoji, {
    bool remove = false,
  }) async {
    final kex = _knownKex[dst.hex];
    if (kex == null) {
      _events.add(NodeError('Unknown recipient key: ${dst.short}'));
      return;
    }
    final emojiBytes = utf8.encode(emoji);
    final target = MsgId.fromHex(targetMsgIdHex);
    final plain = Uint8List(17 + emojiBytes.length)
      ..setRange(0, 16, target)
      ..[16] = remove ? 1 : 0
      ..setRange(17, 17 + emojiBytes.length, emojiBytes);
    await _dispatch(
      router.originate(
        type: FrameType.reaction,
        dst: dst,
        payload: await crypto.encrypt(plain, kex),
        flags: FrameFlags.encrypted,
      ),
    );
  }

  /// QR 스캔 직후 상호 인증 증명을 보낸다: QR에 실려 있던 논스를 암호화해
  /// 되돌려주면, 상대는 "이 사람이 내 화면을 직접 봤다"를 확인하고 나를
  /// 인증된 친구로 승격한다. store-and-forward를 타므로 상대 화면이 잠겨
  /// 있어도 다음 조우 때 도착한다.
  Future<void> sendVerify(PeerId dst, Uint8List nonce) async {
    final kex = _knownKex[dst.hex];
    if (kex == null) {
      _events.add(NodeError('Unknown recipient key: ${dst.short}'));
      return;
    }
    await _dispatch(
      router.originate(
        type: FrameType.verify,
        dst: dst,
        payload: await crypto.encrypt(nonce, kex),
        flags: FrameFlags.encrypted,
      ),
    );
  }

  Future<void> _broadcastAnnounce() async {
    if (transport.linkCount == 0) return;
    await transport.broadcast(_announceFrame().encode());
  }

  /// 즉시 존재(presence)를 다시 announce하고 탐색(discovery)을 (재)가동한다.
  /// 앱이 포그라운드로 돌아올 때 호출된다: iOS는 백그라운드 동안 15초 presence
  /// 타이머를 정지시키므로, 재개 시 그대로 두면 피어들이 우리를 다시 보기까지
  /// 최대 한 주기를 기다리게 된다. 이 메서드는 온라인 상태 / 도달 가능성이
  /// 즉시 회복되게 한다.
  Future<void> wakeUp() async {
    await _broadcastAnnounce();
    transport.wake();
  }

  /// 보낼 링크가 없을 때의 능동 복구: 단순 wake가 아니라 전체 재탐색을 건다
  /// (백오프·쿨다운 초기화 + 알려진 피어 대기 연결 재무장). 사용자가 지금
  /// 보내려 한다는 것보다 강한 "찾아라" 신호는 없다.
  ///
  /// **속도 제한 필수**: 재탐색은 광고를 stop→start로 교체하는데, Android에서
  /// 그때마다 새 랜덤 주소(RPA)가 할당된다. 연달아 보내며 주소를 계속 갈아
  /// 치우면 백그라운드 상대(특히 iPhone)가 dial을 끝낼 시간을 얻지 못한다 —
  /// 복구하려다 발견을 망치는 역효과다. 15초에 한 번으로 제한한다.
  Future<void> _recoverForSend() async {
    final last = _lastSendRecovery;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 15)) {
      return;
    }
    _lastSendRecovery = DateTime.now();
    final t = transport;
    if (t is MeshTransport) {
      await t.boost();
    } else {
      t.wake();
    }
    await _broadcastAnnounce();
  }

  /// QR로 검증된 친구와의 직접 링크에서 BLE 본딩을 유도한다.
  /// [MeshTransport.ensureBonded] 참고. BLE가 아닌 전송에서는 no-op.
  Future<void> ensureBonded(String peerHex) async {
    final t = transport;
    if (t is MeshTransport) await t.ensureBonded(peerHex);
  }

  /// [wakeUp]의 강화판(사용자 명시 재탐색): announce에 더해 전송 계층의
  /// 탐색 백오프를 비우고 대기 연결을 재장전한다. [MeshTransport.boost] 참고.
  /// BLE가 아닌 전송(테스트 fake)에서는 [wakeUp]과 동일하게 동작한다.
  Future<void> boostDiscovery() async {
    await _broadcastAnnounce();
    final t = transport;
    if (t is MeshTransport) {
      await t.boost();
    } else {
      t.wake();
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _retransmitTimer?.cancel();
    _retransmitTimer = null;
    _haveTimer?.cancel();
    _haveTimer = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final t in _rxTimers.values) {
      t.cancel();
    }
    _rxTimers.clear();
    for (final t in _senderTimers.values) {
      t.cancel();
    }
    _senderTimers.clear();
    for (final t in _ackRepeatTimers) {
      t.cancel();
    }
    _ackRepeatTimers.clear();
    for (final w in _fastAcceptWaiters.values) {
      if (!w.isCompleted) w.completeError(StateError('node stopped'));
    }
    _fastAcceptWaiters.clear();
    _fastActive.clear();
    _fastQueued.clear();
    _resending.clear();
    for (final s in _senders.values) {
      s.close();
    }
    _senders.clear();
    for (final r in _receivers.values) {
      r.discard();
    }
    _receivers.clear();
    await transport.stop();
  }

  /// 실제 BLE 전송에서 배터리 절약(duty-cycle 스캔)을 토글한다.
  void setPowerSaver(bool saver) {
    final t = transport;
    if (t is MeshTransport) {
      t.setPowerMode(saver ? PowerMode.saver : PowerMode.active);
    }
  }

  bool get powerSaver {
    final t = transport;
    return t is MeshTransport && t.powerMode == PowerMode.saver;
  }

  /// Android BLE 스캔 모드(0=저전력, 1=균형, 2=저지연). 그 외 플랫폼에서는
  /// 아무 동작도 하지 않는다. [MeshTransport.setScanMode] 참고.
  Future<void> setScanMode(int code) async {
    final t = transport;
    if (t is MeshTransport) await t.setScanMode(code);
  }

  /// iOS: 스캔을 넓은 포그라운드 모드(iOS 27에서 다른 iPhone을 안정적으로 찾는
  /// 유일한 모드)와 필터링된 백그라운드 모드 사이에서 전환한다. 그 외
  /// 플랫폼에서는 아무 동작도 하지 않는다.
  void setForeground(bool foreground) =>
      transport.setForeground(foreground);

  /// 이 노드의 이름을 바꾸고 현재 이웃들에게 다시 announce하여, 그들의 연락처
  /// 목록이 재연결을 기다리지 않고 갱신되게 한다.
  Future<void> updateDisplayName(String name) async {
    displayName = name;
    await transport.broadcast(_announceFrame().encode());
  }

  /// 내 아바타 레시피를 바꾸고 즉시 재announce한다 — 이웃 화면의 내 아바타가
  /// 다음 15초 주기를 기다리지 않고 갱신되게.
  Future<void> updateAvatar(String? recipe) async {
    avatarRecipe = recipe;
    await transport.broadcast(_announceFrame().encode());
  }

  /// [dst]에게 텍스트 메시지를 보낸다. msgId를 반환하며, 아직 수신자의 키를
  /// 모르면 null을 반환한다.
  /// [sentAt]은 기본값이 현재 시각이다; 사용자가 시작한 재전송(RESEND)은 원래
  /// 작성 시각을 전달하여 수신자의 "보낸 시각"이 사실대로 유지되게 한다(미전달
  /// 경고 이후의 재전송이야말로 이 타임스탬프가 가장 중요한 지연 전달
  /// 사례다).
  Future<String?> sendText(PeerId dst, String text, {DateTime? sentAt}) async {
    final kex = _knownKex[dst.hex];
    if (kex == null) {
      _events.add(NodeError('Unknown recipient key: ${dst.short}'));
      return null;
    }
    final cipher = await crypto.encrypt(
      // 수신자 UI를 위해 sentAt을 함께 실어 보낸다.
      TextEnvelope.encode(text, sentAt: sentAt),
      kex,
    );
    final frame = router.originate(
      type: FrameType.text,
      dst: dst,
      payload: cipher,
      flags: FrameFlags.encrypted | FrameFlags.ackRequested,
      ttl: durableTtl,
    );
    _awaitingAck[frame.msgIdHex] = _PendingText(frame);
    // 전송 시도를 로그에 남긴다: "메시지가 안 간다"는 신고에 예전에는 로그가
    // 한 줄도 없어(전송 경로가 조용했다) 시도조차 했는지 알 수 없었다.
    // 링크 수를 함께 찍어 '내보낼 길이 있었는가'를 즉시 판별한다.
    final links = transport.linkCount;
    bleLogSink?.call('MSG send ${frame.msgIdHex.substring(0, 8)} '
        '→ ${dst.short} (links=$links)');
    // 링크가 없는데 사람이 보내려 한다 = 지금 당장 복구를 시도할 가장 강한
    // 신호다. 예전에는 프레임이 store-and-forward로 조용히 쌓이기만 하고
    // 무선 쪽은 아무 일도 하지 않아, 사용자가 보낼수록 답답해지기만 했다
    // (2026-07-26 heavy: links=0으로 전송 → 이후 50분간 아무 재연결 시도 없음).
    if (links == 0) unawaited(_recoverForSend());
    await _dispatch(frame);
    return frame.msgIdHex;
  }

  /// 이전에 보낸 텍스트를 버려서, 사용자가 시작한 재전송(새 msgId를 발급)이
  /// 원본의 늦은 store-and-forward 사본에 의해 중복 전달되지 않게 한다. 실시간
  /// 재전송 집합과 durable 저장소에서 제거한다; 수신자는 낡은 id를 다시는
  /// 보지 않는다.
  void forgetText(String msgIdHex) {
    _awaitingAck.remove(msgIdHex);
    store.remove(msgIdHex);
  }

  /// [dst]에게 파일 전송을 시작한다. transferId를 반환한다.
  ///
  /// [chunkSize] 4 KiB는 청크당 오버헤드(암호화 + 프레임 헤더 + 라우팅)를 약
  /// 2%로 유지하고, 2 KiB 대비 프레임 수를 절반으로 줄인다 — 이 프레임 수가
  /// BLE에서 청크당 고정 비용의 지배적 요소다.
  Future<String?> sendFile(
    PeerId dst, {
    required Uint8List bytes,
    required String name,
    required String mime,
    int chunkSize = 4096,
  }) async {
    final kex = _knownKex[dst.hex];
    if (kex == null) {
      _events.add(NodeError('Unknown recipient key: ${dst.short}'));
      return null;
    }
    if (bytes.length > maxFileBytes) {
      _events.add(
        NodeError('File too large (${bytes.length} bytes, max $maxFileBytes)'),
      );
      return null;
    }
    final sender = FileSender.forFile(
      bytes: bytes,
      name: name,
      mime: mime,
      chunkSize: chunkSize,
    );
    return _startSend(sender, dst, kex);
  }

  /// [sendFile]과 같지만 디스크 기반이다: 파일을 [path]에서 곧바로 해싱하고
  /// 청킹하므로, 큰 전송이 파일 전체를 RAM에 붙들어두는 일이 없다.
  Future<String?> sendFilePath(
    PeerId dst, {
    required String path,
    required String name,
    required String mime,
    int chunkSize = 4096,
  }) async {
    final kex = _knownKex[dst.hex];
    if (kex == null) {
      _events.add(NodeError('Unknown recipient key: ${dst.short}'));
      return null;
    }
    final size = await File(path).length();
    if (size > maxFileBytes) {
      _events.add(NodeError('File too large ($size bytes, max $maxFileBytes)'));
      return null;
    }
    final sender = await FileSender.forPath(
      path: path,
      name: name,
      mime: mime,
      chunkSize: chunkSize,
    );
    return _startSend(sender, dst, kex);
  }

  /// 사용자가 시작한 발신 전송 취소(청크 스트림을 멈춘다).
  void cancelSend(String transferIdHex) => _cancelSendImpl(transferIdHex);

  /// 저장소가 시드된 뒤(앱 재시작) 영속화된 영수증을 다시 적용하여, 툼스톤이
  /// 별도의 테이블 없이도 재시작을 견디게 한다.
  Future<void> rebuildReceipts() => _rebuildReceiptsImpl();

  /// 당시 전송 측의 키를 몰라서 보관(park)해둔, 우리 앞으로 온 프레임들을
  /// 재시도한다(전달되면 툼스톤을 통해 제거된다).
  Future<void> redeliverParked({PeerId? from}) =>
      _redeliverParkedImpl(from: from);

  /// 로컬에서 발신한 프레임을 라우팅한다: 이웃들에게 보내고 (기본적으로)
  /// store-and-forward를 위해 사본을 하나 보관해, 나중에 만나는 피어들도 그것을
  /// 여전히 받을 수 있게 한다.
  ///
  /// 대용량 파일 청크에는 [persist]가 false다: 청크는 활성 전송 중 직접 수신자
  /// 에게만 유용하며(store-and-forward가 아니라 ACK/재전송으로 복구된다), 수천
  /// 개를 추가하면 경계가 있는 저장소를 마구 뒤흔들게 된다 — 큰 파일에서 처리량을
  /// 죽이는 주된 원인이다.
  Future<void> _dispatch(Frame frame, {bool persist = true}) async {
    if (persist) store.add(frame);
    await transport.broadcast(frame.encode());
  }

  Future<void> dispose() async {
    await stop();
    final t = transport;
    if (t is MeshTransport) {
      await t.dispose();
    }
    await _events.close();
  }
}

/// 종단 간 ACK를 기다리는 텍스트 프레임. 재전송 시도 카운터를 함께 가진다.
class _PendingText {
  final Frame frame;
  int attempts = 0;
  _PendingText(this.frame);
}
