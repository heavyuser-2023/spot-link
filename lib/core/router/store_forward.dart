import 'dart:typed_data';

import '../model/frame.dart';

/// Store-and-forward outbox. See docs/ARCHITECTURE.md §7.3.
///
/// When a frame cannot be delivered to its destination right now (the
/// destination is not a current neighbour), nodes keep a copy so it can be
/// handed to the right peer later. When two nodes connect they exchange HAVE
/// inventories and request (WANT) whatever they are missing.
///
/// Time is injected via [nowMs] to keep the logic testable.
class StoreForward {
  final int maxEntries;
  final int ttlMs;
  final int Function() nowMs;

  final Map<String, _Entry> _store = {};

  StoreForward({
    this.maxEntries = 512,
    this.ttlMs = 24 * 60 * 60 * 1000, // 24h
    required this.nowMs,
  });

  /// Store a frame for later forwarding. End-to-end (routable) frames only;
  /// link-local frames are never stored.
  void add(Frame frame) {
    if (frame.type.isLinkLocal) return;
    prune();
    final key = frame.msgIdHex;
    if (_store.containsKey(key)) {
      _store[key]!.expiry = nowMs() + ttlMs; // refresh
      return;
    }
    if (_store.length >= maxEntries) {
      // Evict the entry closest to expiry.
      String? evict;
      int? soonest;
      for (final e in _store.entries) {
        if (soonest == null || e.value.expiry < soonest) {
          soonest = e.value.expiry;
          evict = e.key;
        }
      }
      if (evict != null) _store.remove(evict);
    }
    _store[key] = _Entry(frame, nowMs() + ttlMs);
  }

  /// Remove a frame once we know it was delivered end-to-end (e.g. RECEIPT).
  void remove(String msgIdHex) => _store.remove(msgIdHex);

  bool contains(String msgIdHex) {
    final e = _store[msgIdHex];
    return e != null && e.expiry > nowMs();
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
      if (e != null && e.expiry > nowMs()) out.add(e.frame);
    }
    return out;
  }

  void prune() {
    final now = nowMs();
    _store.removeWhere((_, e) => e.expiry <= now);
  }

  int get length => _store.length;
  void clear() => _store.clear();
}

class _Entry {
  final Frame frame;
  int expiry;
  _Entry(this.frame, this.expiry);
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
