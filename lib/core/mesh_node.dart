import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'ble/mesh_transport.dart';
import 'crypto/identity.dart';
import 'crypto/session.dart';
import 'model/announce.dart';
import 'model/frame.dart';
import 'model/peer_id.dart';
import 'model/text_envelope.dart';
import 'router/router.dart';
import 'router/seen_cache.dart';
import 'router/store_forward.dart';
import 'transfer/fast_lane.dart';
import 'transfer/file_transfer.dart';

/// ACK 페이로드 종류(ACK 프레임에서 복호화와 무관한 페이로드의 첫 바이트).
class _AckKind {
  static const int message = 0; // 뒤에 16바이트 acked msgId가 이어짐
  static const int file = 1; // 뒤에 FileAck 바이트가 이어짐
}

/// 애플리케이션/UI 계층으로 노출되는 이벤트의 기반 클래스.
sealed class NodeEvent {}

class PeerAnnounced extends NodeEvent {
  final ContactIdentity contact;

  /// 메시 거리: 1 = 직접 이웃, 2 = 우리 사이에 릴레이 하나, …
  final int hops;
  PeerAnnounced(this.contact, {this.hops = 1});
}

class LinksChanged extends NodeEvent {
  final int count;
  LinksChanged(this.count);
}

class TextReceived extends NodeEvent {
  final PeerId from;
  final String text;
  final String msgId;

  /// 보낸 사람의 전송 시각(그쪽 시계 기준), 레거시 피어의 경우 null. UI가
  /// "보낸 시각 / 도착 시각"을 표시할 수 있게 해준다 — 작성된 지 한참 뒤에야
  /// 도착하는 store-and-forward 텍스트에서 의미가 있다.
  final DateTime? sentAt;
  TextReceived(this.from, this.text, this.msgId, {this.sentAt});
}

/// 로컬에서 보낸 메시지가 종단 간 전달됨(ACK가 돌아옴).
class DeliveryConfirmed extends NodeEvent {
  final String msgId;
  DeliveryConfirmed(this.msgId);
}

/// 로컬에서 보낸 텍스트 메시지가 모든 재시도 후에도 확인(ACK)받지 못함.
class TextDeliveryFailed extends NodeEvent {
  final String msgId;
  TextDeliveryFailed(this.msgId);
}

class FileOffered extends NodeEvent {
  final PeerId from;
  final FileMeta meta;
  FileOffered(this.from, this.meta);
}

class FileProgress extends NodeEvent {
  final String transferId;
  final double progress;
  final bool outgoing;
  FileProgress(this.transferId, this.progress, this.outgoing);
}

/// 파일 전송을 포기함(전송 감시 타이머 또는 수신 복구가 타임아웃됨).
class FileFailed extends NodeEvent {
  final String transferIdHex;
  final String name;
  final bool incoming;
  FileFailed(this.transferIdHex, this.name, {required this.incoming});
}

/// 파일이 다 도착함. 페이로드는 디스크에 그대로 남는다([path], 수신 측의
/// 부분 파일, 해시 검증 완료) — 앱 계층이 이를 제자리로 옮긴다.
/// 여기서 바이트를 직접 넘기던 방식은 완료 시점에 파일 크기의 2배만큼 RAM을 치솟게 했다.
class FileReceived extends NodeEvent {
  final PeerId from;
  final FileMeta meta;
  final String path;
  FileReceived(this.from, this.meta, this.path);
}

class NodeError extends NodeEvent {
  final String message;
  NodeError(this.message);
}

/// 앱의 심장부: 원시 BLE 패킷을 암호화된 멀티홉 store-and-forward 메시징
/// 서비스로 변환한다. 플랫폼 BLE는 전적으로 [MeshTransport]에 있고,
/// 라우팅/암호화/전송은 테스트를 거친 순수 모듈이다.
class MeshNode {
  final Identity identity;

  /// 우리가 광고하는 표시 이름. 사용자가 실시간으로 변경할 수 있도록 가변이며,
  /// 변경 시 현재 이웃들에게 다시 announce한다([updateDisplayName] 참고).
  String displayName;

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

  /// 대기 중인 fast-lane accept들, transferId를 키로 하며, 수신 측의 ACCEPT
  /// 프레임이 도착하면 완료된다(전송 측).
  final Map<String, Completer<_FastAccept>> _fastAcceptWaiters = {};

  /// 현재 fast lane으로 전달 중인 transferId들(전송 측 또는 수신 측) — 이들에
  /// 대한 병행 BLE 청크 경로를 억제한다.
  final Set<String> _fastActive = {};

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

  Stream<NodeEvent> get events => _events.stream;
  PeerId get myId => identity.peerId;
  int get linkCount => transport.linkCount;
  int get peerCount => transport.peerCount;

  /// 직접 이웃들의 신호 강도 측정값(근접 UI용).
  Stream<RssiSample> get rssiSamples => transport.rssiSamples;

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
    for (final w in _fastAcceptWaiters.values) {
      if (!w.isCompleted) w.completeError(StateError('node stopped'));
    }
    _fastAcceptWaiters.clear();
    _fastActive.clear();
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
  void setForeground(bool foreground) {
    final t = transport;
    if (t is MeshTransport) t.setForeground(foreground);
  }

  /// 이 노드의 이름을 바꾸고 현재 이웃들에게 다시 announce하여, 그들의 연락처
  /// 목록이 재연결을 기다리지 않고 갱신되게 한다.
  Future<void> updateDisplayName(String name) async {
    displayName = name;
    await transport.broadcast(_announceFrame().encode());
  }

  // ---------------------------------------------------------------------------
  // 전송(보내기)
  // ---------------------------------------------------------------------------

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

  Future<String?> _startSend(FileSender sender, PeerId dst, Uint8List kex) async {
    final tid = sender.meta.transferIdHex;
    bleLogSink?.call(
      'FT send start: ${sender.meta.name} ${sender.meta.fileSize}B '
      'chunks=${sender.meta.totalChunks}',
    );
    _senders[tid] = sender;
    // 감시 타이머: 완료 ACK가 도착하지 않으면 sender를 폐기하여 영원히 새지
    // 않게 한다(예: 수신자가 떠났거나, 최종 ACK가 유실된 경우).
    _armSenderWatchdog(tid, sender.meta.name);

    // 1. META를 보낸다.
    final metaCipher = await crypto.encrypt(sender.meta.encode(), kex);
    await _dispatch(
      router.originate(
        type: FrameType.fileMeta,
        dst: dst,
        payload: metaCipher,
        flags: FrameFlags.encrypted,
      ),
    );

    // 2. 바이트를 전달한다. 큰 파일은 Wi-Fi fast lane을 시도한다; 어떤
    // 실패든(fast lane 없음, 공유 기능 없음, 연결/스트림 오류) BLE 청킹으로
    // 폴백한다. 호출자는 transferId를 즉시 받으므로, 경로와 무관하게 UI가
    // 말풍선 + 진행률을 표시한다.
    unawaited(_deliverFile(sender, dst, kex));
    return tid;
  }

  /// 가능하면 fast lane을, 아니면 BLE 청킹을 선택한다. 전송 하나당 항상 정확히
  /// 한 경로로 귀결된다.
  Future<void> _deliverFile(
    FileSender sender,
    PeerId dst,
    Uint8List kex,
  ) async {
    final tid = sender.meta.transferIdHex;
    if (fastLane != null &&
        fastLane!.capabilities.isNotEmpty &&
        sender.meta.fileSize >= fastLaneMinBytes) {
      final ok = await _trySendFast(sender, dst, kex);
      if (ok) return; // fast lane이 전달을 완수함(전달 ACK는 BLE로 도착)
      if (!_senders.containsKey(tid)) return; // 그 사이에 취소됨/폐기됨
      bleLogSink?.call(
        'FT fast lane unavailable → BLE fallback: ${sender.meta.name}',
      );
    }
    _streaming.add(tid);
    await _streamChunks(sender, dst, kex);
  }

  /// 전송 측 fast path: BLE로 offer하고, ACCEPT를 기다리고, Wi-Fi로 연결한 뒤,
  /// 전체 암호문을 스트리밍한다. 피어가 바이트를 확인한 경우에만 true를 반환한다.
  Future<bool> _trySendFast(
    FileSender sender,
    PeerId dst,
    Uint8List kex,
  ) async {
    final tid = sender.meta.transferIdHex;
    final caps = fastLane!.capabilities;
    // Offer 페이로드: transferId(16) + capsBitmask(1).
    var bitmask = 0;
    for (final k in caps) {
      bitmask |= 1 << k.code;
    }
    final offerPlain = Uint8List(17)
      ..setRange(0, 16, sender.meta.transferId)
      ..[16] = bitmask;
    final waiter = _fastAcceptWaiters[tid] = Completer<_FastAccept>();
    await _dispatch(
      router.originate(
        type: FrameType.fileFastOffer,
        dst: dst,
        payload: await crypto.encrypt(offerPlain, kex),
        flags: FrameFlags.encrypted,
      ),
      persist: false,
    );

    _FastAccept accept;
    try {
      accept = await waiter.future.timeout(fastLaneNegotiateWindow);
    } catch (_) {
      _fastAcceptWaiters.remove(tid);
      return false; // 제때 ACCEPT 없음 → BLE
    } finally {
      _fastAcceptWaiters.remove(tid);
    }

    bleLogSink?.call('FT fast accept: ${accept.offer.kind.name}');
    FastLaneSession? session;
    Timer? feeder;
    try {
      session = await fastLane!.connect(tid, accept.offer);
      if (session == null) {
        bleLogSink?.call('FT fast connect null → BLE');
        return false;
      }
      _fastActive.add(tid);
      // fast lane이 전송을 소유하는 동안에는 idle 감시 타이머에 먹여줄 BLE
      // ACK가 없으므로, 그동안은 우리가 직접 먹여준다.
      feeder = Timer.periodic(const Duration(seconds: 20),
          (_) => _armSenderWatchdog(tid, sender.meta.name));
      bleLogSink?.call('FT fast connected: ${accept.offer.kind.name}');
      // 파일 전체를 하나의 암호화된, 길이 접두(length-prefixed) blob으로 보낸다.
      // 파일 전체 GCM은 평문+암호문이 이 호출 동안에만 RAM에 존재한다는 뜻이다 —
      // 설계상 일시적이다; BLE 경로는 파일을 아예 메모리에 올리지 않는다.
      final cipher = await crypto.encrypt(await sender.readAll(), kex);
      final header = ByteData(4)..setUint32(0, cipher.length, Endian.big);
      session.add(header.buffer.asUint8List());
      session.add(cipher);
      await session.finishSending();
      // 전송 계층이 아직 큐에 쌓인 바이트를 내보내는 중일 수 있다 — Multipeer는
      // .reliable 전송을 비동기로 큐잉하므로, 지금 연결을 끊으면 아직 라디오를
      // 떠나지 않은 바이트가 유실된다. 수신 측은 파일을 다 조립하면 자기 쪽을
      // 닫으므로, 우리 쪽을 닫기 전에 그 EOF를 기다린다 — 또는 완료 ACK를
      // 기다린다(권위 있는 신호; MC의 연결 해제 통지는 두 세션이 같은 피어 쌍을
      // 공유할 때 ~30초까지 지연될 수 있다). 예산은 크기에 비례해 늘어나므로
      // (하한 ~512KB/s) 큰 파일이 중간에 끊기지 않는다.
      try {
        await Future.any([
          session.incoming.drain<void>(),
          _senderRetired(tid),
        ]).timeout(
            Duration(seconds: 30 + sender.meta.fileSize ~/ (512 * 1024)));
      } catch (_) {}
      bleLogSink?.call('FT fast send done: ${sender.meta.name} '
          '(${sender.meta.fileSize}B via ${accept.offer.kind.name})');
      // 수신 측의 완료 ACK를 기다린다(BLE로 도착) — 끝내 오지 않으면 감시
      // 타이머가 이미 전송을 실패로 처리한다.
      _events.add(FileProgress(tid, 1.0, true));
      return true;
    } catch (e) {
      bleLogSink?.call('FT fast send error: $e');
      return false;
    } finally {
      feeder?.cancel();
      _fastActive.remove(tid);
      await session?.close();
    }
  }

  /// sender가 폐기되면(완료 ACK가 도착했거나 취소/타임아웃됨) 완료된다 —
  /// 전송 후 flush 대기를 조기에 끝내는 데 사용된다.
  Future<void> _senderRetired(String tid) async {
    while (_senders.containsKey(tid)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// sender 감시 타이머를 계속 먹여준다. 전송 시작 시점과 수신 측의 모든 ACK
  /// 마다 (재)무장되므로 — 전송은 실제로 조용해진 뒤에야 죽는다.
  void _armSenderWatchdog(String tid, String name) {
    _senderTimers[tid]?.cancel();
    _senderTimers[tid] = Timer(_transferIdleTimeout, () {
      final sender = _senders.remove(tid);
      if (sender != null) {
        sender.close();
        _senderTimers.remove(tid);
        _streaming.remove(tid);
        bleLogSink?.call('FT send timeout: $name');
        _events.add(FileFailed(tid, name, incoming: false));
        _events.add(NodeError('File transfer timed out: $name'));
      }
    });
  }

  /// 사용자가 시작한 발신 전송 취소(청크 스트림을 멈춘다).
  void cancelSend(String transferIdHex) {
    final sender = _senders.remove(transferIdHex);
    if (sender != null) {
      sender.close();
      _senderTimers.remove(transferIdHex)?.cancel();
      _streaming.remove(transferIdHex);
      bleLogSink?.call('FT send cancelled: $transferIdHex');
    }
  }

  Future<void> _streamChunks(
    FileSender sender,
    PeerId dst,
    Uint8List kex,
  ) async {
    final tid = sender.meta.transferIdHex;
    var sent = 0;
    var lastPct = -1;
    try {
      for (final chunk in sender.allChunks()) {
        // 버스트 도중에 폐기됨(조기 완료, 타임아웃, 취소, 정지).
        if (!_senders.containsKey(tid)) return;
        final cipher = await crypto.encrypt(chunk.encode(), kex);
        await _dispatch(
          router.originate(
            type: FrameType.fileChunk,
            dst: dst,
            payload: cipher,
            flags: FrameFlags.encrypted,
          ),
          persist: false,
        );
        sent++;
        // 진행률 이벤트를 조절한다: 청크마다가 아니라 퍼센트마다 하나씩.
        final pct = sent * 100 ~/ sender.meta.totalChunks;
        if (pct != lastPct || sent == sender.meta.totalChunks) {
          lastPct = pct;
          _events.add(FileProgress(tid, sent / sender.meta.totalChunks, true));
        }
      }
      bleLogSink?.call(
        'FT send burst done: ${sender.meta.name} ($sent chunks)',
      );
    } catch (e) {
      bleLogSink?.call('FT send burst error: $e');
    } finally {
      _streaming.remove(tid);
    }
  }

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

  // ---------------------------------------------------------------------------
  // 수신(받기)
  // ---------------------------------------------------------------------------

  void _onLinkEvent(LinkEvent e) async {
    _events.add(LinksChanged(transport.linkCount));
    if (e.up) {
      // 우리 자신을 소개하고 store-and-forward 저장소 목록(inventory)을 동기화한다.
      await _sendAnnounce(e.link.id);
      await _sendHave(e.link.id);
      // 새로 생긴 링크는 확인받지 못한 텍스트를 재시도하기에 가장 좋은 순간이다 —
      // 재전송 틱이나 HAVE/WANT 왕복을 기다리지 말고 지금 바로 새 파이프로 밀어
      // 넣는다. 수신자는 중복을 제거하며, 이것은 공짜 기회다: maxTextAttempts에
      // 카운트되지 않는다.
      for (final pending in _awaitingAck.values.toList()) {
        await transport.sendToLink(e.link.id, pending.frame.encode());
      }
    }
  }

  /// 라우터를 통해 존재(presence) 프레임을 만들어 우리 자신의 msgId가 seen으로
  /// 표시되게 한다 — 플러딩된 announce가 우리에게 되돌아오면 전달하거나 다시
  /// 릴레이하지 말고 버려야 한다.
  Frame _announceFrame() {
    final ann = Announce(
      publicBundle: identity.publicBundle,
      displayName: displayName,
    );
    return router.originate(
      type: FrameType.announce,
      dst: PeerId.broadcast,
      payload: ann.encode(),
      ttl: announceTtl,
    );
  }

  Future<void> _sendAnnounce(String linkId) async {
    await transport.sendToLink(linkId, _announceFrame().encode());
  }

  Future<void> _sendHave(String linkId) async {
    final inv = store.inventory();
    final frame = Frame.create(
      type: FrameType.have,
      ttl: 1,
      src: myId,
      dst: PeerId.broadcast,
      payload: MsgIdList.encode(inv),
    );
    await transport.sendToLink(linkId, frame.encode());
  }

  void _onPacket(InboundPacket pkt) async {
    // 여기의 모든 처리는 공격자의 영향을 받은 바이트 위에서 돌아간다. 잘못된
    // 프레임 하나가 절대 수신 파이프라인을 죽여서는 안 되므로, 본문 전체를
    // 가드로 감쌌다(아래 개별 디코더들이 적대적 입력에 예외를 던질 수 있다).
    try {
      final Frame frame;
      try {
        frame = Frame.decode(pkt.frameBytes);
      } catch (_) {
        return; // 잘못된 헤더/길이
      }

      // 이 링크의 피어로부터 full-TTL announce가 곧바로 도착했다: RSSI 폴링이
      // 측정값의 주인을 알 수 있도록 반대편 끝에 누가 있는지 기억해둔다
      // (iOS 광고에는 id가 없으므로, 매핑은 이렇게 이루어진다).
      if (frame.type == FrameType.announce &&
          frame.ttl == announceTtl &&
          pkt.link.remoteShortId == null) {
        pkt.link.remoteShortId = frame.src;
      }

      if (frame.type.isLinkLocal) {
        await _handleLinkLocal(frame, pkt.link.id);
        return;
      }

      // 전달이 입증됨(서명된 영수증): 전달하거나, 릴레이하거나, 다시 저장하지
      // 않는다 — 오래 오프라인이던 폰이 이를 되살리지 못하게 하는 장치다. 다만
      // 전송 측이 여전히 우리에게 재전송하고 있다면, 그쪽 ACK가 유실된 것이다:
      // 멈출 수 있도록 다시 ACK한다(아래 중복 분기와 동일).
      if (_receipted.contains(frame.msgIdHex)) {
        if (frame.type == FrameType.text &&
            frame.ackRequested &&
            frame.dst == myId &&
            _deliveredIncoming.contains(frame.msgIdHex)) {
          await _sendMessageAck(frame.src, frame.msgId);
        }
        return;
      }

      final decision = router.handleIncoming(frame);
      if (decision.duplicate) {
        // 라우터가 이전에 본 프레임(루프 방지) — 하지만 "seen" ≠ "delivered".
        // 이 프레임이 우리 앞으로 온 것인데 우리가 보긴 했으나 앱까지 전달하지
        // 못했다면(복호화 실패 / 당시 키 없음), 재전송/재요청(re-pull)은 이를
        // 전달할 기회다: 버리지 말고 전달을 다시 수행한다. 이것이 깨진 사본 하나가
        // 메시지를 영영 잃게 하는 것을 막아준다.
        if (frame.dst == myId &&
            !_deliveredIncoming.contains(frame.msgIdHex) &&
            _pendingLocalDelivery.contains(frame.msgIdHex)) {
          await _deliverLocal(frame);
          return;
        }
        // 우리가 이미 전달한 텍스트의 재전송: 전송 측의 첫 ACK가 유실됐을
        // 가능성이 크다. 멈출 수 있도록 다시 ACK한다. (seen-cache가 _deliverLocal
        // 이전에 프레임을 버리므로, 여기가 복구할 수 있는 유일한 지점이다.)
        if (frame.type == FrameType.text &&
            frame.ackRequested &&
            frame.dst == myId &&
            _deliveredIncoming.contains(frame.msgIdHex)) {
          await _sendMessageAck(frame.src, frame.msgId);
        }
        return;
      }

      if (decision.relay != null) {
        // 존재(presence)는 순간적이다: 실시간으로 릴레이하되 절대
        // store-and-forward하지 않는다(몇 시간 뒤에 전달되는 낡은 "주변" 정보는
        // 거짓말이 될 것이다).
        if (frame.type != FrameType.announce) {
          store.add(decision.relay!);
        }
        await transport.broadcast(
          decision.relay!.encode(),
          exceptLinkId: pkt.link.id,
        );
      }
      if (decision.deliverLocal) {
        await _deliverLocal(frame);
      }
    } catch (e) {
      _events.add(NodeError('Dropped malformed frame: $e'));
    }
  }

  Future<void> _handleLinkLocal(Frame frame, String linkId) async {
    switch (frame.type) {
      case FrameType.have:
        final remoteHave = MsgIdList.decode(frame.payload);
        final wanted = store.selectWanted(
          remoteHave,
          // "Seen"은 릴레이/전달된 프레임의 재요청(re-pull)을 막는다 — 단,
          // 우리 앞으로 왔고 우리가 보긴 했으나 끝내 전달하지 못한 메시지는
          // 예외다(복호화 실패 / 키 없음). 그런 것들은 새 사본을 계속 요청해야
          // 한다. 그러지 않으면 깨진 전달 한 번에 메시지를 영영 잃는다.
          alreadySeen: (hex) =>
              !_pendingLocalDelivery.contains(hex) &&
              (seen.contains(hex) || _receipted.contains(hex)),
        );
        if (wanted.isNotEmpty) {
          final want = Frame.create(
            type: FrameType.want,
            ttl: 1,
            src: myId,
            dst: PeerId.broadcast,
            payload: MsgIdList.encode(wanted),
          );
          await transport.sendToLink(linkId, want.encode());
        }
        break;
      case FrameType.want:
        final wanted = MsgIdList.decode(frame.payload);
        for (final f in store.framesForWanted(wanted)) {
          await transport.sendToLink(linkId, f.encode());
        }
        break;
      default:
        break;
    }
  }

  Future<void> _deliverLocal(Frame frame) async {
    Uint8List payload = frame.payload;
    if (frame.isEncrypted) {
      final kex = _knownKex[frame.src.hex];
      if (kex == null) {
        // 아직 전송 측의 키를 학습하지 못함(예: 메시지가 그들의 ANNOUNCE보다 더
        // 멀리 이동함). 프레임을 태워버리지 말고 — 잠시 보관(park)해두었다가
        // 그들의 ANNOUNCE가 도착하면 재시도한다([redeliverParked]).
        if (frame.dst == myId && !store.contains(frame.msgIdHex)) {
          store.add(frame);
          _events.add(NodeError('No key to decrypt from ${frame.src.short}'));
        }
        if (frame.dst == myId) _markPendingLocalDelivery(frame.msgIdHex);
        return;
      }
      try {
        payload = await crypto.decrypt(frame.payload, kex);
      } catch (_) {
        _events.add(NodeError('Decrypt failed from ${frame.src.short}'));
        // 손상된 페이로드(예: 불안정한 링크에서 유실된 프래그먼트): 영원히
        // 버리는 대신 새(FRESH) 사본을 계속 WANT한다. 여기서는 사본을 가지고
        // 있지 않으므로(이건 불량), [selectWanted]가 다시 요청할 수 있다.
        if (frame.dst == myId) _markPendingLocalDelivery(frame.msgIdHex);
        return;
      }
    }

    switch (frame.type) {
      case FrameType.announce:
        if (frame.src == myId) break; // 우리 자신의 플러딩이 되돌아온 것
        try {
          final ann = Announce.decode(payload);
          final contact = ContactIdentity.fromBundle(
            ann.publicBundle,
            displayName: ann.displayName,
          );
          _knownKex[contact.peerId.hex] = contact.kexPublic;
          _knownSigning[contact.peerId.hex] = contact.signingPublic;
          // TTL은 릴레이 한 번마다 하나씩 감소한다: 직접 = announceTtl, 릴레이
          // 하나 = announceTtl-1, … 다른 origin TTL을 쓰는 피어(구버전은 ttl 1로
          // announce함)의 프레임에 대비해 clamp한다.
          final hops = (announceTtl - frame.ttl + 1).clamp(1, announceTtl);
          _events.add(PeerAnnounced(contact, hops: hops));
          // 그들의 키가, 그들을 알기 전에 보관해둔 메시지를 열어줄 수 있다.
          unawaited(redeliverParked(from: contact.peerId));
        } catch (_) {}
        break;
      case FrameType.text:
        // 재전송 중인 전송 측이 멈출 수 있도록 항상 다시 ACK하되, 특정 메시지는
        // 앱에 한 번만 노출한다(재요청(re-pull)된 store-and-forward 프레임이
        // 중복을 만들어서는 안 된다).
        if (frame.ackRequested) {
          await _sendMessageAck(frame.src, frame.msgId);
        }
        if (_deliveredIncoming.contains(frame.msgIdHex)) break;
        _rememberDelivered(frame.msgIdHex);
        _clearPendingLocalDelivery(frame.msgIdHex); // 드디어 도착함
        final envelope = TextEnvelope.decode(payload);
        // sentAt=none은 레거시(LEGACY) 전송 측을 나타낸다(v1.5.16 이전 페이로드) —
        // "왜 전송 시각이 안 떠?"를 현장에서 진단하는 시그니처다.
        bleLogSink?.call('MSG recv ${frame.msgIdHex.substring(0, 8)} '
            '(${envelope.text.length} chars, '
            'sentAt=${envelope.sentAt?.toIso8601String() ?? 'none'})');
        _events.add(TextReceived(frame.src, envelope.text, frame.msgIdHex,
            sentAt: envelope.sentAt));
        // 릴레이들이 자기 사본을 버릴 수 있도록 이 텍스트가 도착했음을 메시 전체에
        // 알리고, 우리 자신도 다시는 이를 받아들이지 않는다.
        _tombstone(frame.msgIdHex);
        unawaited(_broadcastReceipt(frame.msgId));
        break;
      case FrameType.ack:
        await _handleAck(frame.src, payload);
        break;
      case FrameType.fileMeta:
        final meta = FileMeta.decode(payload);
        // 이미 진행 중이거나 완료된 전송의 재offer는 무시한다.
        if (_receivers.containsKey(meta.transferIdHex) ||
            _completedTransfers.contains(meta.transferIdHex)) {
          break;
        }
        // 피어가 제공한 manifest는 아무것도 신뢰하지 않는다: 전송 측은
        // [maxFileBytes]에서 상한을 두므로, 그보다 큰 fileSize는 잘못됐거나
        // 적대적이다. FileReceiver가 그 크기로 부분 파일을 미리 할당하기 전에
        // 거부한다.
        if (meta.fileSize < 0 || meta.fileSize > maxFileBytes) {
          bleLogSink?.call('FT recv rejected oversize meta: ${meta.fileSize}');
          break;
        }
        bleLogSink?.call(
          'FT recv meta: ${meta.name} chunks=${meta.totalChunks}',
        );
        _receivers[meta.transferIdHex] =
            FileReceiver(meta, incomingPartPath(meta.transferIdHex));
        _receiverPeers[meta.transferIdHex] = frame.src;
        _startReceiverRecovery(meta.transferIdHex, frame.src);
        _events.add(FileOffered(frame.src, meta));
        break;
      case FrameType.fileChunk:
        await _handleFileChunk(frame.src, payload);
        break;
      case FrameType.fileFastOffer:
        await _handleFastOffer(frame.src, payload);
        break;
      case FrameType.fileFastAccept:
        _handleFastAccept(payload);
        break;
      case FrameType.receipt:
        await _handleReceipt(frame, payload);
        break;
      default:
        break;
    }
  }

  /// 수신자가 [msgId]의 전달을 입증하기 위해 서명하는, 도메인 분리된 바이트.
  static Uint8List receiptSignedBytes(Uint8List msgId) =>
      Uint8List.fromList([...utf8.encode('SL-RECEIPT-v1'), ...msgId]);

  /// 서명된 전달 영수증을 플러딩하여, 전달된 텍스트의 사본을 아직 들고 있는 모든
  /// 릴레이가 이를 버릴 수 있게 한다("전파 삭제"). 텍스트처럼 durable하게
  /// 저장되므로, 이 정리 작업 자체도 결국 오래 오프라인이던 폰에까지 도달한다.
  Future<void> _broadcastReceipt(Uint8List msgId) async {
    final sig = await identity.sign(receiptSignedBytes(msgId));
    final payload = Uint8List(16 + 64)
      ..setRange(0, 16, msgId)
      ..setRange(16, 80, sig);
    await _dispatch(
      router.originate(
        type: FrameType.receipt,
        dst: PeerId.broadcast,
        ttl: durableTtl,
        payload: payload,
      ),
    );
  }

  /// 전달 영수증을 검증하고 적용한다: 유효한 서명은 메시지의 수신자만 만들 수
  /// 있으므로, 제3자가 영수증으로 검열할 수 없다.
  Future<void> _handleReceipt(Frame frame, Uint8List payload) async {
    if (payload.length < 80) return; // 잘못된 형식
    final msgId = Uint8List.fromList(payload.sublist(0, 16));
    final sig = Uint8List.fromList(payload.sublist(16, 80));
    final hex = MsgId.hex(msgId);
    if (_receipted.contains(hex)) return;
    final signer = _knownSigning[frame.src.hex];
    if (signer == null) return; // 검증 불가 → 계속 릴레이하고, 삭제하지 않는다
    if (!await Identity.verify(receiptSignedBytes(msgId), sig, signer)) {
      return; // 위조됨/손상됨
    }
    // 우리가 아직 메시지를 들고 있다면, 영수증은 반드시 그 수신자로부터 와야 한다.
    final held = store.frameFor(hex);
    if (held != null && held.dst != frame.src) return;
    _tombstone(hex);
  }

  /// 전달된 msgId를 묻는다(툼스톤): 저장된 사본을 버리고, 다시는 저장하거나
  /// 릴레이하거나 재요청(re-pull)하기를 거부한다.
  void _tombstone(String hex) {
    store.remove(hex);
    _receipted.add(hex);
    while (_receipted.length > _receiptedCap) {
      _receipted.remove(_receipted.first);
    }
  }

  /// 저장소가 시드된 뒤(앱 재시작) 영속화된 영수증을 다시 적용하여, 툼스톤이
  /// 별도의 테이블 없이도 재시작을 견디게 한다.
  Future<void> rebuildReceipts() async {
    for (final f in store.allFrames()) {
      if (f.type == FrameType.receipt) await _handleReceipt(f, f.payload);
    }
  }

  /// 당시 전송 측의 키를 몰라서 보관(park)해둔, 우리 앞으로 온 프레임들을
  /// 재시도한다(전달되면 툼스톤을 통해 제거된다).
  Future<void> redeliverParked({PeerId? from}) async {
    for (final f in store.allFrames()) {
      if (f.dst != myId) continue;
      if (from != null && f.src != from) continue;
      await _deliverLocal(f);
    }
  }

  Future<void> _sendMessageAck(PeerId dst, Uint8List ackedMsgId) async {
    final payload = Uint8List(1 + 16)
      ..[0] = _AckKind.message
      ..setRange(1, 17, ackedMsgId);
    final kex = _knownKex[dst.hex];
    final flags = kex != null ? FrameFlags.encrypted : 0;
    final body = kex != null ? await crypto.encrypt(payload, kex) : payload;
    await _dispatch(
      router.originate(
        type: FrameType.ack,
        // ACK는 텍스트가 온 거리만큼, store-and-forward 홉을 포함해 되돌아갈 수
        // 있어야 한다.
        ttl: durableTtl,
        dst: dst,
        payload: body,
        flags: flags,
      ),
    );
  }

  Future<void> _handleAck(PeerId from, Uint8List payload) async {
    if (payload.isEmpty) return;
    final kind = payload[0];
    if (kind == _AckKind.message) {
      if (payload.length < 17) return; // 잘못된 형식: 무시
      final ackedId = Uint8List.fromList(payload.sublist(1, 17));
      final hex = MsgId.hex(ackedId);
      store.remove(hex);
      _awaitingAck.remove(hex); // 재전송 중단
      if (_confirmedText.add(hex)) {
        if (_confirmedText.length > _deliveredIncomingCap) {
          _confirmedText.remove(_confirmedText.first);
        }
        bleLogSink?.call('MSG delivered ${hex.substring(0, 8)}');
        _events.add(DeliveryConfirmed(hex));
      }
    } else if (kind == _AckKind.file) {
      if (payload.length < 1 + 19) return; // 최소 FileAck (id16+flag+count2)
      final FileAck ack;
      try {
        ack = FileAck.decode(Uint8List.fromList(payload.sublist(1)));
      } catch (_) {
        return; // 잘못된 형식의 file ack
      }
      final sender = _senders[ack.transferIdHex];
      if (sender == null) return;
      final kex = _knownKex[from.hex];
      if (kex == null) return;
      // 어떤 ACK든 수신자가 살아 있다는 증거다 — 전송을 계속 진행한다.
      _armSenderWatchdog(ack.transferIdHex, sender.meta.name);
      if (ack.complete) {
        bleLogSink?.call('FT delivered: ${sender.meta.name}');
        _retireSender(ack.transferIdHex);
        _events.add(FileProgress(ack.transferIdHex, 1, true));
        _events.add(DeliveryConfirmed(ack.transferIdHex));
        return;
      }
      // 초기 버스트가 아직 스트리밍 중(BLE)이거나 fast lane이 회선을 소유하고
      // 있다: "누락"된 것은 모두 이미 가는 중이다. 지금 재전송하면 전송 전체가
      // BLE로 중복될 것이다.
      if (_streaming.contains(ack.transferIdHex) ||
          _fastActive.contains(ack.transferIdHex)) {
        return;
      }
      bleLogSink?.call('FT resend requested: ${ack.missing.length} chunks');
      for (final chunk in sender.chunksToResend(ack)) {
        if (!_senders.containsKey(ack.transferIdHex)) return; // 폐기됨
        final cipher = await crypto.encrypt(chunk.encode(), kex);
        await _dispatch(
          router.originate(
            type: FrameType.fileChunk,
            dst: from,
            payload: cipher,
            flags: FrameFlags.encrypted,
          ),
          persist: false,
        );
      }
    }
  }

  void _retireSender(String transferIdHex) {
    _senders.remove(transferIdHex)?.close();
    _senderTimers.remove(transferIdHex)?.cancel();
    _streaming.remove(transferIdHex);
  }

  // ---------------------------------------------------------------------------
  // Wi-Fi fast lane (수신 측). 협상은 BLE 메시를 타고 이루어지며; 파일 바이트만
  // Wi-Fi로 이동한다. 어떤 실패든 BLE 수신자 + 복구 타이머를 그대로 남겨두므로,
  // 전송은 대신 BLE로 완료된다.
  // ---------------------------------------------------------------------------

  /// 값이 클수록 = 선호됨. AP 없는 네이티브 P2P가 LAN 소켓보다 우선한다.
  static int _lanePreference(FastLaneKind k) =>
      k == FastLaneKind.lanSocket ? 1 : 2;

  Future<void> _handleFastOffer(PeerId from, Uint8List payload) async {
    if (fastLane == null || fastLane!.capabilities.isEmpty) return; // → BLE
    if (payload.length < 17) return;
    final transferId = Uint8List.fromList(payload.sublist(0, 16));
    final tid = MsgId.hex(transferId);
    // 실제로 이 전송을 기다리고 있고 아직 끝나지 않은 경우에만 동작한다.
    final receiver = _receivers[tid];
    if (receiver == null || _completedTransfers.contains(tid)) return;
    if (_fastActive.contains(tid)) return; // 이미 협상 중

    // capabilities를 교집합하고 선호도로 고른다: AP 없는 네이티브 P2P
    // (Wi-Fi Aware/Direct/Multipeer)가 LAN 소켓을 이긴다. 공유 액세스 포인트
    // 없이도 동작하며 "더 순수한" 직접 링크이기 때문이다.
    final senderMask = payload[16];
    FastLaneKind? chosen;
    for (final k in fastLane!.capabilities) {
      if ((senderMask & (1 << k.code)) != 0) {
        if (chosen == null || _lanePreference(k) > _lanePreference(chosen)) {
          chosen = k;
        }
      }
    }
    if (chosen == null) return; // 공유 전송 수단 없음 → BLE
    bleLogSink?.call('FT fast offer accepted: ${chosen.name} (tid $tid)');

    final kex = _knownKex[from.hex];
    if (kex == null) return;

    FastLaneInbound? inbound;
    try {
      inbound = await fastLane!.prepareInbound(tid, chosen);
    } catch (_) {
      inbound = null;
    }
    if (inbound == null) return; // 수신 대기 불가 → BLE

    _fastActive.add(tid);
    // ACCEPT: transferId(16) + chosenKind(1) + offerLen(2) + offerBlob.
    final blob = inbound.offer.blob;
    final accept = Uint8List(16 + 1 + 2 + blob.length);
    accept.setRange(0, 16, transferId);
    accept[16] = chosen.code;
    ByteData.view(accept.buffer).setUint16(17, blob.length, Endian.big);
    accept.setRange(19, 19 + blob.length, blob);
    await _dispatch(
      router.originate(
        type: FrameType.fileFastAccept,
        dst: from,
        payload: await crypto.encrypt(accept, kex),
        flags: FrameFlags.encrypted,
      ),
      persist: false,
    );

    // 백그라운드에서 fast lane으로 파일을 읽는다.
    unawaited(_receiveFast(from, tid, kex, inbound));
  }

  Future<void> _receiveFast(
    PeerId from,
    String tid,
    Uint8List kex,
    FastLaneInbound inbound,
  ) async {
    FastLaneSession? session;
    try {
      session = await inbound.session;
      if (session == null) {
        bleLogSink?.call('FT fast recv: no session (peer never connected) → BLE');
        _fastActive.remove(tid);
        return; // 전송 측이 끝내 연결하지 않음 → BLE 복구 타이머가 처리한다
      }
      bleLogSink?.call('FT fast recv connected, reading…');
      // 4바이트 길이 접두를 읽은 뒤 그만큼의 암호문 바이트를 읽는다. 조각들은
      // 두 번만 조립되므로(헤더 파싱 + 완료), 100MB 전송이 복사에서 O(n²)이 되지
      // 않는다.
      final buf = BytesBuilder(copy: false);
      int? total; // 4 + 암호문 길이, 헤더가 도착하면 알 수 있다
      var lastPct = 0;
      await for (final part in session.incoming) {
        buf.add(part);
        _rxLastChunk[tid] = DateTime.now(); // idle 감시 타이머에 먹여준다
        if (total == null && buf.length >= 4) {
          final head = buf.takeBytes();
          total = ByteData.view(head.buffer, head.offsetInBytes)
                  .getUint32(0, Endian.big) +
              4;
          buf.add(head);
          bleLogSink?.call('FT fast recv expecting ${total}B');
        }
        if (total == null) continue;
        final pct = (buf.length * 100) ~/ total;
        if (pct >= lastPct + 5 && buf.length < total) {
          lastPct = pct;
          _events.add(FileProgress(tid, buf.length / total, false));
        }
        if (buf.length >= total) {
          final all = buf.takeBytes();
          final cipher = Uint8List.sublistView(all, 4, total);
          final receiver = _receivers[tid];
          // BLE 청크가 이미 이 전송을 finalize로 몰고 갔다면 건너뛴다
          // ([_handleFileChunk]와 공유하는 가드); 이중 finalize를 방지한다.
          if (receiver == null || !_finalizing.add(tid)) return;
          try {
            final bytes = await crypto.decrypt(cipher, kex);
            // 평문을 부분 파일에 쓰고 manifest 해시를 검증한다(finalize). 그래야
            // 아래의 ACK가 진짜 완료가 된다.
            receiver.seedAssembled(bytes);
            final path = await receiver.finalize();
            bleLogSink?.call('FT fast recv complete: ${receiver.meta.name}');
            _events.add(FileProgress(tid, 1.0, false));
            _events.add(FileReceived(from, receiver.meta, path));
            _completeReceiver(tid);
            _rememberCompleted(tid);
            // BLE 완료 경로를 그대로 재사용한다: 서명된 "complete" ACK가 전송
            // 측을 멈추고 그쪽 말풍선을 전달됨으로 바꾼다.
            await _sendFileAck(from, receiver.buildAck());
          } finally {
            _finalizing.remove(tid);
          }
          return;
        }
      }
    } catch (e) {
      bleLogSink?.call('FT fast recv error: $e — falling back to BLE');
      // BLE 수신자 + 복구 타이머를 계속 돌게 둔다: 누락된 청크를 ACK하면 전송
      // 측이 BLE로 다시 보낸다.
    } finally {
      _fastActive.remove(tid);
      await session?.close();
    }
  }

  void _handleFastAccept(Uint8List payload) {
    if (payload.length < 19) return;
    final tid = MsgId.hex(Uint8List.fromList(payload.sublist(0, 16)));
    final waiter = _fastAcceptWaiters[tid];
    if (waiter == null || waiter.isCompleted) return;
    final kind = FastLaneKind.fromCode(payload[16]);
    if (kind == null) return;
    final blobLen = ByteData.view(
      payload.buffer,
      payload.offsetInBytes,
    ).getUint16(17, Endian.big);
    if (payload.length < 19 + blobLen) return;
    final blob = Uint8List.fromList(payload.sublist(19, 19 + blobLen));
    waiter.complete(_FastAccept(FastLaneOffer(kind, blob)));
  }

  Future<void> _handleFileChunk(PeerId from, Uint8List payload) async {
    // fast lane이 이 전송의 바이트를 소유한다 — 떠도는 BLE 청크는 모두 무시한다.
    // (폴백 도중 두 경로가 순간적으로 경쟁할 수 있다.)
    final FileChunk chunk;
    try {
      chunk = FileChunk.decode(payload);
    } catch (_) {
      return; // 잘못된 형식의 청크
    }
    final tidHex = MsgId.hex(chunk.transferId);
    final receiver = _receivers[tidHex];
    if (receiver == null) {
      // 이미 완료한 전송에 대한 떠도는 청크: 전송 측이 우리의 완료 ACK를 받지
      // 못한 것이다. 전송 측이 멈출 수 있도록 다시 보낸다.
      if (_completedTransfers.contains(tidHex)) {
        await _sendFileAck(from, FileAck(chunk.transferId, true, const []));
      }
      return; // 아직 META를 보지 못함(또는 이미 완료됨)
    }
    final isNew = receiver.offer(chunk);
    _rxLastChunk[tidHex] = DateTime.now();
    // 진행률 이벤트를 조절한다: 청크마다가 아니라 퍼센트마다 하나씩.
    final pct = (receiver.progress * 100).floor();
    if (isNew && (pct != _rxLastPct[tidHex] || receiver.isComplete)) {
      _rxLastPct[tidHex] = pct;
      _events.add(FileProgress(tidHex, receiver.progress, false));
    }

    // `_finalizing.add`는 이 전송에 대해 이미 finalize가 돌고 있으면 false를
    // 반환한다(중복 청크가 finalize의 await 창으로 끼어들었거나, fast lane이
    // 이를 마무리하는 중) — 이중 finalize를 하지 않도록 건너뛴다.
    if (receiver.isComplete && _finalizing.add(tidHex)) {
      try {
        final path = await receiver.finalize();
        bleLogSink?.call('FT recv complete: ${receiver.meta.name}');
        _events.add(FileReceived(from, receiver.meta, path));
        _completeReceiver(tidHex);
        _rememberCompleted(tidHex);
        await _sendFileAck(from, receiver.buildAck());
      } catch (_) {
        // 모든 청크가 다 있는데 파일 해시가 불일치. 청크별 GCM은 이를 거의
        // 불가능하게 만든다; "complete"로 잘못 ACK하기보다는(그러면 전송 측이
        // 멈춘다) 복구 불가능한 실패로 처리한다.
        receiver.discard();
        _completeReceiver(tidHex);
        _events.add(NodeError('File integrity check failed; discarded'));
      } finally {
        _finalizing.remove(tidHex);
      }
    }
    // 여기서는 인밴드 부분 ACK를 하지 않는다: 큰 파일에서 N 청크마다 ACK하면
    // 거대한 누락 목록으로 역방향 경로를 넘치게 하고, 아직 전송 중인 청크의
    // 중복 재전송을 유발한다. 대신 [_startReceiverRecovery]의 복구 타이머가
    // idle/하트비트에 맞춰 ACK한다.
  }

  /// 앱에 전달된 메시지 id의 경계가 있는(bounded) 기록(라우팅 seen-cache의 더
  /// 짧은 TTL을 넘어서는 중복 제거).
  void _rememberDelivered(String msgIdHex) {
    _deliveredIncoming.add(msgIdHex);
    while (_deliveredIncoming.length > _deliveredIncomingCap) {
      _deliveredIncoming.remove(_deliveredIncoming.first);
    }
  }

  /// [_pendingLocalDelivery] 참고. 경계가 있음(bounded).
  void _markPendingLocalDelivery(String msgIdHex) {
    if (_deliveredIncoming.contains(msgIdHex)) return;
    if (_pendingLocalDelivery.add(msgIdHex)) {
      onPendingLocalChanged?.call(msgIdHex, true);
    }
    while (_pendingLocalDelivery.length > _pendingLocalDeliveryCap) {
      final evicted = _pendingLocalDelivery.first;
      _pendingLocalDelivery.remove(evicted);
      onPendingLocalChanged?.call(evicted, false);
    }
  }

  void _clearPendingLocalDelivery(String msgIdHex) {
    if (_pendingLocalDelivery.remove(msgIdHex)) {
      onPendingLocalChanged?.call(msgIdHex, false);
    }
  }

  /// 완료된 전송을 기억해 유실된 최종 ACK를 다시 보낼 수 있게 하며, 오래 도는
  /// 세션 동안 집합이 무한정 커지지 않도록 크기를 제한한다.
  void _rememberCompleted(String tidHex) {
    _completedTransfers.add(tidHex);
    const cap = 256;
    while (_completedTransfers.length > cap) {
      _completedTransfers.remove(_completedTransfers.first);
    }
  }

  /// 완료/중단된 전송에 대한 수신 측 상태를 모두 정리한다.
  void _completeReceiver(String tidHex) {
    _receivers.remove(tidHex);
    _receiverPeers.remove(tidHex);
    _rxTimers.remove(tidHex)?.cancel();
    _rxLastChunk.remove(tidHex);
    _rxLastAck.remove(tidHex);
    _rxLastPct.remove(tidHex);
  }

  /// 전송이 미완료인 동안, 전송 측이 조용해지면(버스트가 끝났거나 멈춤) 누락된
  /// seq를 ACK하고, 활성 버스트 중에는 느린 하트비트를 더한다. 들어오는 청크가
  /// 전혀 없는 채로 [_transferIdleTimeout]이 지난 뒤에야 포기한다 — 여전히
  /// 진전이 있는 큰 파일은 결코 타임아웃되지 않는다.
  void _startReceiverRecovery(String tidHex, PeerId from) {
    _rxTimers[tidHex]?.cancel();
    _rxLastChunk[tidHex] = DateTime.now();
    _rxLastAck[tidHex] = DateTime.now();
    _rxTimers[tidHex] = Timer.periodic(_fileAckInterval, (t) async {
      final receiver = _receivers[tidHex];
      if (receiver == null || receiver.isComplete) {
        t.cancel();
        return;
      }
      final now = DateTime.now();
      final idle = now.difference(_rxLastChunk[tidHex] ?? now);
      if (idle > _transferIdleTimeout) {
        t.cancel();
        bleLogSink?.call('FT recv timeout: ${receiver.meta.name}');
        receiver.discard();
        _completeReceiver(tidHex);
        _events.add(FileFailed(tidHex, receiver.meta.name, incoming: true));
        _events.add(
          NodeError('Incoming file timed out: ${receiver.meta.name}'),
        );
        return;
      }
      // fast lane이 전달하는 동안에는 BLE 청크가 예상되지 않는다 — 지금 누락
      // 목록 ACK를 보내면 중복 BLE 재전송만 유발한다. 위의 idle 타임아웃은
      // 여전히 적용된다(fast 조각들이 [_rxLastChunk]에 먹여준다).
      if (_fastActive.contains(tidHex)) return;
      final sinceAck = now.difference(_rxLastAck[tidHex] ?? now);
      if (idle >= _ackIdleGap || sinceAck >= _ackHeartbeat) {
        _rxLastAck[tidHex] = now;
        await _sendFileAck(from, receiver.buildAck(maxMissing: _ackMaxMissing));
      }
    });
  }

  Future<void> _sendFileAck(PeerId dst, FileAck ack) async {
    final raw = ack.encode();
    final payload = Uint8List(1 + raw.length)
      ..[0] = _AckKind.file
      ..setRange(1, 1 + raw.length, raw);
    final kex = _knownKex[dst.hex];
    final flags = kex != null ? FrameFlags.encrypted : 0;
    final body = kex != null ? await crypto.encrypt(payload, kex) : payload;
    // File ACK는 잦은 복구 트래픽이다 — store-and-forward할 가치가 없다.
    await _dispatch(
      router.originate(
        type: FrameType.ack,
        dst: dst,
        payload: body,
        flags: flags,
      ),
      persist: false,
    );
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

/// 수신 측의 fast-lane ACCEPT. 대기 중인 전송 측에게 전달된다.
class _FastAccept {
  final FastLaneOffer offer;
  _FastAccept(this.offer);
}
