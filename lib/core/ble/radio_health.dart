/// 무선이 "왜" 연결되지 않았는지에 대한 판정. 이번 주 실기기 사건 세 건
/// (좀비 링크 / 삼성 플랩 루프 / CoreBluetooth 세션 노화)에서 사람이 로그를
/// 손으로 읽어 도출했던 분류를 코드로 굳힌 것이다.
///
/// 왜 필요한가: "연결 안 됨"은 증상이지 원인이 아니다. 원인별로 조치가 완전히
/// 다르다 — 상대가 없으면 기다려야 하고, 링크가 플랩하면 상대 스택 문제이며,
/// 진전이 장기간 전무하면 우리 스택이 죽은 것이라 재초기화해야 한다. 그
/// 구분을 사람이 매번 로그로 하지 않게, 관측 신호에서 자동 분류한다.
enum RadioHealth {
  /// 링크 있음 — 정상.
  linked,

  /// 최근 발견/링크 진전이 있다. 아직 링크는 없지만 무선은 일하고 있다.
  searching,

  /// 스캔·광고는 정상인데 아무 광고도 보이지 않는다 = **주변에 아무도 없다**.
  /// 이것은 고장이 아니다 — 사용자에게 "친구가 근처에 없다"고 말할 수 있는
  /// 유일하게 정직한 상태다(예전엔 이 상태와 아래 [stackAged]를 구분하지 못해
  /// 프리워밍 웨이크마다 "주변에 친구가 있어요" 오탐을 냈다).
  quiet,

  /// 발견은 되는데 링크가 반복해서 끊긴다 — 대개 상대 스택 문제
  /// (2026-07-24: 삼성 One UI의 느린 GATT 서버로 39회 절단·재연결 루프).
  /// 우리 쪽 조치는 재연결 억제(플랩 차단기)이지, 더 세게 두드리는 것이 아니다.
  linkFlapping,

  /// 진전이 오래 전무하다 → 우리 네이티브 스택이 조용히 죽었을 가능성
  /// (2026-07-25: iOS 19.5시간 세션에서 스캔 전달과 pending connect 완료가
  /// 동시에 정지, 앱 재시작만 치료됨). 하드리셋 대상.
  stackAged,

  /// 블루투스가 꺼져 있다 — 사용자만 해결할 수 있다.
  radioOff,

  /// 권한이 없다 — 사용자만 해결할 수 있다.
  unauthorized,

  /// 아직 시작되지 않음.
  stopped;

  /// 사용자가 직접 조치해야 하는 상태(배너·안내를 띄울 근거).
  bool get needsUserAction =>
      this == RadioHealth.radioOff || this == RadioHealth.unauthorized;

  /// 우리 스택을 고쳐야 하는 상태(자동 복구 대상).
  bool get needsSelfRepair => this == RadioHealth.stackAged;

  /// "주변에 친구가 있다"고 말해도 되는 상태인가. [quiet]에서 알림을 보내면
  /// 오탐이 된다.
  bool get hasPeerEvidence =>
      this == RadioHealth.linked ||
      this == RadioHealth.searching ||
      this == RadioHealth.linkFlapping;

  /// 관측 신호에서 상태를 판정한다. 순수 함수 — 모든 조합을 단위 테스트로
  /// 고정할 수 있다(test/radio_health_test.dart).
  ///
  /// 판정 순서가 곧 우선순위다: 사용자 조치가 필요한 것 → 정상 → 상대 문제 →
  /// 우리 스택 문제 → 관측 불가.
  static RadioHealth classify({
    required bool started,
    required bool poweredOff,
    required bool unauthorized,
    required int linkCount,
    required Duration sinceProgress,
    required bool flapping,
    required Duration searchingGrace,
    required Duration agedAfter,
  }) {
    if (poweredOff) return RadioHealth.radioOff;
    if (unauthorized) return RadioHealth.unauthorized;
    if (!started) return RadioHealth.stopped;
    if (linkCount > 0) return RadioHealth.linked;
    // 플랩은 '발견은 되는데 유지가 안 되는' 상태 — 진전 시계가 계속 갱신되므로
    // searching과 겹친다. 조치가 다르므로 플랩을 먼저 본다.
    if (flapping) return RadioHealth.linkFlapping;
    if (sinceProgress >= agedAfter) return RadioHealth.stackAged;
    if (sinceProgress <= searchingGrace) return RadioHealth.searching;
    return RadioHealth.quiet;
  }
}
