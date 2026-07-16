import 'dart:typed_data';

import '../model/frame.dart';

/// 저장-후-전달(store-and-forward) 발신함. docs/ARCHITECTURE.md §7.3 참고.
///
/// 프레임을 지금 당장 목적지로 전달할 수 없을 때(목적지가 현재 이웃이 아닐 때),
/// 노드는 나중에 알맞은 피어에게 넘겨줄 수 있도록 사본을 보관한다. 두 노드가
/// 연결되면 HAVE 인벤토리를 교환하고 자신에게 없는 것을 (WANT로) 요청한다.
///
/// 두 계층 (DTN 방식의 "결국은 전달됨"):
/// - **Durable(내구성)** (text / ack / receipt — 아주 작은 프레임): 전달
///   (RECEIPT)되거나, 밀려나거나, 사용자가 지울 때까지 만료 없이 보관된다. 앱
///   계층이 [onDurableChanged] + [seed]로 이 계층을 영속화하므로, 재시작을
///   견디고 메시지가 며칠 동안 함께 실려 갈 수 있다.
/// - **Expiring(만료성)** (파일 meta/chunk — 부피 큼): 최대 [ttlMs](24시간)까지
///   보관되므로, 릴레이가 다른 사람의 큰 파일로 가득 차는 일이 없다.
///
/// 로직을 테스트할 수 있도록 시간은 [nowMs]를 통해 주입된다.
class StoreForward {
  final int maxEntries;
  final int ttlMs;

  /// 내구성 계층의 상한. 텍스트 프레임은 암호화 시 ~250B이므로, 기본 상한도
  /// 릴레이 저장소로 겨우 ~1MB에 불과하다.
  final int durableMaxEntries;
  final int Function() nowMs;

  /// 영속화를 위한 내구성 계층의 변경: `frame == null`은 제거를 뜻한다.
  /// [seed](이미 영속화된 것을 로드) 또는 [clearDurable](호출자가 자신의
  /// 영속화도 함께 지움) 시에는 발생하지 않는다.
  void Function(String msgIdHex, Frame? frame)? onDurableChanged;

  final Map<String, _Entry> _store = {};

  StoreForward({
    // 256 × ~4KB 청크 프레임 ≈ 1MB 상한으로, 부피 큰 만료성 계층을 위한 것 —
    // 낯선 사람의 파일 청크를 릴레이하는 것은 최선 노력(best-effort)이며,
    // 릴레이하는 폰의 서스펜드 상태 메모리 점유(jetsam)를 절대 키워서는 안 된다.
    this.maxEntries = 256,
    this.ttlMs = 24 * 60 * 60 * 1000, // 24시간
    this.durableMaxEntries = 4096,
    required this.nowMs,
  });

  static bool _isDurable(FrameType t) =>
      t == FrameType.text || t == FrameType.ack || t == FrameType.receipt;

  /// 나중에 전달하기 위해 프레임을 저장한다. 종단 간(라우팅 가능) 프레임만
  /// 해당한다; 링크-로컬 프레임은 결코 저장되지 않으며, 존재 알림도 마찬가지다 —
  /// 몇 시간 뒤에 전달되는 오래된 ANNOUNCE는 거짓 "근처"를 표시하게 된다.
  void add(Frame frame) {
    if (frame.type.isLinkLocal || frame.type == FrameType.announce) return;
    prune();
    final key = frame.msgIdHex;
    final durable = _isDurable(frame.type);
    final existing = _store[key];
    if (existing != null) {
      if (existing.expiry != null) {
        existing.expiry = nowMs() + ttlMs; // 만료성 계층을 갱신
      }
      return;
    }
    if (durable) {
      if (_durableCount() >= durableMaxEntries) _evictOldestDurable();
      _store[key] = _Entry(frame, null, nowMs());
      onDurableChanged?.call(key, frame);
    } else {
      if (_expiringCount() >= maxEntries) _evictSoonestExpiring();
      _store[key] = _Entry(frame, nowMs() + ttlMs, nowMs());
    }
  }

  /// 이전에 영속화된 내구성 프레임을 로드한다([onDurableChanged]를 발생시키지
  /// 않는다 — 이미 영속화되어 있으므로).
  void seed(Iterable<Frame> frames) {
    for (final f in frames) {
      if (f.type.isLinkLocal || f.type == FrameType.announce) continue;
      _store.putIfAbsent(f.msgIdHex, () => _Entry(f, null, nowMs()));
    }
  }

  /// 종단 간으로 전달되었음을 알게 되면 프레임을 제거한다(예: RECEIPT).
  void remove(String msgIdHex) {
    final e = _store.remove(msgIdHex);
    if (e != null && e.expiry == null) onDurableChanged?.call(msgIdHex, null);
  }

  /// 사용자가 시작한 내구성 릴레이 메일함 비우기. 자신의 영속화를 함께 지우는
  /// 것은 호출자의 책임이다(콜백은 발생하지 않는다).
  void clearDurable() => _store.removeWhere((_, e) => e.expiry == null);

  int get durableCount => _durableCount();
  int get durableBytes => _store.values
      .where((e) => e.expiry == null)
      .fold(0, (sum, e) => sum + e.frame.payload.length + 40);

  int _durableCount() =>
      _store.values.where((e) => e.expiry == null).length;
  int _expiringCount() =>
      _store.values.where((e) => e.expiry != null).length;

  void _evictOldestDurable() {
    String? evict;
    int? oldest;
    for (final e in _store.entries) {
      if (e.value.expiry != null) continue;
      if (oldest == null || e.value.storedAt < oldest) {
        oldest = e.value.storedAt;
        evict = e.key;
      }
    }
    if (evict != null) {
      _store.remove(evict);
      onDurableChanged?.call(evict, null);
    }
  }

  void _evictSoonestExpiring() {
    String? evict;
    int? soonest;
    for (final e in _store.entries) {
      final exp = e.value.expiry;
      if (exp == null) continue;
      if (soonest == null || exp < soonest) {
        soonest = exp;
        evict = e.key;
      }
    }
    if (evict != null) _store.remove(evict);
  }

  bool contains(String msgIdHex) {
    final e = _store[msgIdHex];
    if (e == null) return false;
    return e.expiry == null || e.expiry! > nowMs();
  }

  /// 우리가 현재 보관 중인 msgId 집합(HAVE 광고용).
  List<Uint8List> inventory() {
    prune();
    return _store.values.map((e) => e.frame.msgId).toList();
  }

  /// 원격 피어의 HAVE 인벤토리가 주어지면, 우리가 원하는(아직 보관하지 않은) id들.
  /// [alreadySeen]는 우리가 처리했지만 더 이상 저장하지 않는 id도 호출자가
  /// 제외할 수 있게 하여, 이미 전달된 메시지를 다시 당겨오는 것을 방지한다.
  List<Uint8List> selectWanted(
    List<Uint8List> remoteHave, {
    bool Function(String msgIdHex)? alreadySeen,
  }) {
    final wanted = <Uint8List>[];
    for (final id in remoteHave) {
      final hex = MsgId.hex(id);
      if (contains(hex)) continue;
      if (alreadySeen != null && alreadySeen(hex)) continue;
      wanted.add(id);
    }
    return wanted;
  }

  /// 원격 피어의 WANT 요청에 부합하는 프레임들.
  List<Frame> framesForWanted(List<Uint8List> wanted) {
    final out = <Frame>[];
    for (final id in wanted) {
      final e = _store[MsgId.hex(id)];
      if (e != null && (e.expiry == null || e.expiry! > nowMs())) {
        out.add(e.frame);
      }
    }
    return out;
  }

  void prune() {
    final now = nowMs();
    _store.removeWhere((_, e) => e.expiry != null && e.expiry! <= now);
  }

  /// [msgIdHex]에 대해 저장된 프레임(있는 경우; 내구성이거나 아직 만료되지 않음).
  Frame? frameFor(String msgIdHex) {
    final e = _store[msgIdHex];
    if (e == null) return null;
    if (e.expiry != null && e.expiry! <= nowMs()) return null;
    return e.frame;
  }

  /// 저장된 모든 프레임(재시작 시 영속화된 영수증을 다시 적용하는 데 사용).
  List<Frame> allFrames() => _store.values.map((e) => e.frame).toList();

  int get length => _store.length;
  void clear() => _store.clear();
}

class _Entry {
  final Frame frame;

  /// null = 내구성(전달되거나 비워질 때까지 보관).
  int? expiry;
  final int storedAt;
  _Entry(this.frame, this.expiry, this.storedAt);
}

/// HAVE / WANT 페이로드용 코덱: count(u16) 뒤에 그 개수만큼의 16바이트
/// msgId가 이어진다.
class MsgIdList {
  static Uint8List encode(List<Uint8List> ids) {
    final out = Uint8List(2 + ids.length * 16);
    ByteData.view(out.buffer).setUint16(0, ids.length, Endian.big);
    var off = 2;
    for (final id in ids) {
      out.setRange(off, off + 16, id);
      off += 16;
    }
    return out;
  }

  static List<Uint8List> decode(Uint8List data) {
    if (data.length < 2) return const [];
    final count = ByteData.view(data.buffer, data.offsetInBytes).getUint16(0, Endian.big);
    final out = <Uint8List>[];
    var off = 2;
    for (var i = 0; i < count && off + 16 <= data.length; i++) {
      out.add(Uint8List.fromList(data.sublist(off, off + 16)));
      off += 16;
    }
    return out;
  }
}
