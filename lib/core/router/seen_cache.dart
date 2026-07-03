/// A time- and size-bounded cache of message ids we have already processed.
///
/// The [Router] uses it to drop duplicate frames that arrive via multiple
/// neighbours during flooding, preventing routing loops and rebroadcast
/// storms.
///
/// Time is injected via [nowMs] so the cache is fully testable without a real
/// clock.
class SeenCache {
  final int maxEntries;
  final int ttlMs;
  final int Function() nowMs;

  // Insertion-ordered map: key -> expiry timestamp.
  final Map<String, int> _entries = <String, int>{};

  SeenCache({
    this.maxEntries = 4096,
    this.ttlMs = 10 * 60 * 1000, // 10 minutes
    required this.nowMs,
  });

  /// Returns true if [key] was already seen (and still valid). Otherwise
  /// records it and returns false. This is the atomic "check-and-mark" the
  /// router relies on.
  bool checkAndMark(String key) {
    final now = nowMs();
    _evictExpired(now);
    final expiry = _entries[key];
    if (expiry != null && expiry > now) {
      return true;
    }
    _entries.remove(key); // refresh insertion order
    _entries[key] = now + ttlMs;
    _evictOverflow();
    return false;
  }

  bool contains(String key) {
    final expiry = _entries[key];
    return expiry != null && expiry > nowMs();
  }

  void _evictExpired(int now) {
    if (_entries.isEmpty) return;
    final dead = <String>[];
    for (final e in _entries.entries) {
      if (e.value <= now) {
        dead.add(e.key);
      } else {
        // Map preserves insertion order; the earliest inserted are checked
        // first but expiry is monotonic per insertion, so we can stop once we
        // hit a live entry only if ttl is constant. Keep it simple & correct:
        // scan all. Cache is bounded so this stays cheap.
      }
    }
    for (final k in dead) {
      _entries.remove(k);
    }
  }

  void _evictOverflow() {
    while (_entries.length > maxEntries) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest);
    }
  }

  int get length => _entries.length;

  void clear() => _entries.clear();
}
