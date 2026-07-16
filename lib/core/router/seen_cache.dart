/// 이미 처리한 메시지 id를, 시간과 크기로 제한하는 캐시.
///
/// [Router]는 이를 사용해 플러딩 중 여러 이웃을 통해 도착하는 중복 프레임을
/// 버려서, 라우팅 루프와 재브로드캐스트 폭풍을 방지한다.
///
/// 시간은 [nowMs]를 통해 주입되므로, 실제 시계 없이도 캐시를 완전히 테스트할 수
/// 있다.
class SeenCache {
  final int maxEntries;
  final int ttlMs;
  final int Function() nowMs;

  // 삽입 순서를 유지하는 맵: key -> 만료 타임스탬프.
  final Map<String, int> _entries = <String, int>{};

  SeenCache({
    this.maxEntries = 4096,
    this.ttlMs = 10 * 60 * 1000, // 10분
    required this.nowMs,
  });

  /// [key]가 이미 관찰되었고(그리고 아직 유효하면) true를 반환한다. 그렇지
  /// 않으면 이를 기록하고 false를 반환한다. 라우터가 의존하는 원자적
  /// "check-and-mark"이다.
  bool checkAndMark(String key) {
    final now = nowMs();
    _evictExpired(now);
    final expiry = _entries[key];
    if (expiry != null && expiry > now) {
      return true;
    }
    _entries.remove(key); // 삽입 순서를 갱신
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
        // 맵은 삽입 순서를 보존한다; 가장 먼저 삽입된 것이 먼저 검사되지만 만료는
        // 삽입별로 단조 증가하므로, ttl이 일정할 때에만 살아 있는 항목을 만나는
        // 즉시 멈출 수 있다. 단순하고 올바르게 유지한다: 전부 스캔한다. 캐시에는
        // 상한이 있으므로 이는 계속 저렴하다.
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
