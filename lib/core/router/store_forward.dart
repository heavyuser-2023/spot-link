import 'dart:typed_data';

import '../model/frame.dart';

/// Store-and-forward outbox. See docs/ARCHITECTURE.md §7.3.
///
/// When a frame cannot be delivered to its destination right now (the
/// destination is not a current neighbour), nodes keep a copy so it can be
/// handed to the right peer later. When two nodes connect they exchange HAVE
/// inventories and request (WANT) whatever they are missing.
///
/// Two tiers (DTN-style "eventual delivery"):
/// - **Durable** (text / ack / receipt — tiny frames): kept with NO expiry
///   until delivered (RECEIPT), evicted, or the user clears them. The app
///   layer persists this tier via [onDurableChanged] + [seed], so it
///   survives restarts and a message can ride along for days.
/// - **Expiring** (file meta/chunks — bulky): kept [ttlMs] (24h) at most, so
///   relays never fill up with other people's large files.
///
/// Time is injected via [nowMs] to keep the logic testable.
class StoreForward {
  final int maxEntries;
  final int ttlMs;

  /// Cap for the durable tier. Text frames are ~250B encrypted, so even the
  /// default cap is only ~1MB of relay storage.
  final int durableMaxEntries;
  final int Function() nowMs;

  /// Durable-tier mutations, for persistence: `frame == null` means removed.
  /// Not fired for [seed] (loading what is already persisted) or
  /// [clearDurable] (the caller clears its own persistence alongside).
  void Function(String msgIdHex, Frame? frame)? onDurableChanged;

  final Map<String, _Entry> _store = {};

  StoreForward({
    this.maxEntries = 512,
    this.ttlMs = 24 * 60 * 60 * 1000, // 24h
    this.durableMaxEntries = 4096,
    required this.nowMs,
  });

  static bool _isDurable(FrameType t) =>
      t == FrameType.text || t == FrameType.ack || t == FrameType.receipt;

  /// Store a frame for later forwarding. End-to-end (routable) frames only;
  /// link-local frames are never stored, and neither is presence — a stale
  /// ANNOUNCE delivered hours later would show a false "nearby".
  void add(Frame frame) {
    if (frame.type.isLinkLocal || frame.type == FrameType.announce) return;
    prune();
    final key = frame.msgIdHex;
    final durable = _isDurable(frame.type);
    final existing = _store[key];
    if (existing != null) {
      if (existing.expiry != null) {
        existing.expiry = nowMs() + ttlMs; // refresh the expiring tier
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

  /// Load previously persisted durable frames (does not fire
  /// [onDurableChanged] — they are already persisted).
  void seed(Iterable<Frame> frames) {
    for (final f in frames) {
      if (f.type.isLinkLocal || f.type == FrameType.announce) continue;
      _store.putIfAbsent(f.msgIdHex, () => _Entry(f, null, nowMs()));
    }
  }

  /// Remove a frame once we know it was delivered end-to-end (e.g. RECEIPT).
  void remove(String msgIdHex) {
    final e = _store.remove(msgIdHex);
    if (e != null && e.expiry == null) onDurableChanged?.call(msgIdHex, null);
  }

  /// User-initiated purge of the durable relay mailbox. The caller is
  /// responsible for clearing its persistence too (no callbacks fired).
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

  /// The set of msgIds we currently hold (for a HAVE advertisement).
  List<Uint8List> inventory() {
    prune();
    return _store.values.map((e) => e.frame.msgId).toList();
  }

  /// Given a remote peer's HAVE inventory, the ids we want (don't already hold).
  /// [alreadySeen] lets the caller also exclude ids we've processed but no
  /// longer store, avoiding re-pulling delivered messages.
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

  /// Frames matching a remote peer's WANT request.
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

  /// The stored frame for [msgIdHex], if any (durable or unexpired).
  Frame? frameFor(String msgIdHex) {
    final e = _store[msgIdHex];
    if (e == null) return null;
    if (e.expiry != null && e.expiry! <= nowMs()) return null;
    return e.frame;
  }

  /// Every stored frame (used to re-apply persisted receipts on restart).
  List<Frame> allFrames() => _store.values.map((e) => e.frame).toList();

  int get length => _store.length;
  void clear() => _store.clear();
}

class _Entry {
  final Frame frame;

  /// null = durable (kept until delivered or purged).
  int? expiry;
  final int storedAt;
  _Entry(this.frame, this.expiry, this.storedAt);
}

/// Codec for HAVE / WANT payloads: count(u16) followed by that many 16-byte
/// msgIds.
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
