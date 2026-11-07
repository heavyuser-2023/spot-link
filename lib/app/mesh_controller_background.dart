part of 'mesh_controller.dart';

/// [MeshController]의 백그라운드/전력/생명주기/비콘 웨이크/영속 스토어 배선.
mixin _MeshControllerBackground on _MeshControllerBase {
  /// [_battery] 참고. Android 전용; 수동 절약 토글이 켜져 있으면 no-op이다.
  Future<void> _evaluateAdaptivePower() async {
    if (!profile.usesAdaptivePower || powerSaver) return;
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

  /// 비콘/상태 복원에 의한 백그라운드 재기동은 didChangeAppLifecycleState를
  /// 한 번도 발화시키지 않은 채 lifecycleState가 null/inactive에 머문다 —
  /// 부트 3초 재확인은 paused류만 백그라운드로 취급해 이 경우를 놓치고,
  /// 그 결과 깨어난 앱이 포그라운드용 무필터 스캔(백그라운드에서는 iOS가
  /// 아무것도 전달하지 않음)을 잠들 때까지 돌렸다(2026-07-17 gold 19:22,
  /// 4.5분 관찰). 수신 알림 라우팅도 같은 플래그를 쓰므로 알림 억제 오류도
  /// 함께 났다. 넛지와 같은 신호("부팅+10초면 진짜 포그라운드는 resumed")로
  /// 매 프레즌스 틱마다 플래그와 전송 스캔 모드를 실제 상태에 맞춘다.
  ///
  /// **전송 계층은 매 틱 무조건 구동한다**(이 함수의 자체 캐시 `_foreground`가
  /// 바뀌었을 때만이 아니다). 예전에는 이 비교가 게이트였는데, 두 계층이 부팅
  /// 시각에 서로 다른 규칙으로 초기화되기 때문에 **처음부터 어긋난 조합**이
  /// 만들어질 수 있었다: 컨트롤러는 `== resumed || == null`로, 전송은
  /// `!= paused/detached/hidden`으로 판정한다 → 백그라운드 재기동의 실제
  /// 시그니처인 `inactive`에서 컨트롤러는 false(정답), 전송은 true(오답)가 된다.
  /// 그러면 `resumed(false) == _foreground(false)`가 영구히 성립해 이 함수는
  /// 매 10초 즉시 return하고, 전송의 잘못된 모드는 **아무도 고치지 못한다**
  /// (2026-07-30 heavy: 로그 3310행 전체에 'reconciled' 0건, 그동안 백그라운드
  /// 에서 12초/18초를 iOS가 아무것도 전달하지 않는 무필터 스캔에 썼고 발견 0건).
  /// 전송의 setForeground는 자체적으로 변화 여부를 판정하므로 매 틱 호출은
  /// 값이 같으면 공짜다 — 그리고 어긋났을 때만 실제로 라디오를 바로잡는다.
  void _reconcileForegroundMode() {
    final resumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    node.setForeground(resumed); // 권위 있는 신호를 전송 계층에 그대로 전달
    if (resumed == _foreground) return;
    bleLogSink?.call('${DateTime.now().toIso8601String()} '
        'foreground flag reconciled -> $resumed (lifecycle drift)');
    _foreground = resumed;
    if (resumed && started) unawaited(node.wakeUp());
  }

  /// 복구 장치의 감시자. **복구 장치 자체가 죽는 경우**를 잡는다.
  ///
  /// 전송 계층의 유지보수 틱(15초) 위에 좀비 링크 절단·광고 재확립·deep heal·
  /// 하드리셋이 전부 얹혀 있다. 그 타이머가 조용히 멈추면 자가복구가 통째로
  /// 꺼지는데, 스캔·광고는 다른 타이머로 계속 돌아 **겉보기엔 정상**이다
  /// (2026-07-26 heavy: 13시간 동안 유지보수 0회, links=0인 채 메시지 전송
  /// 실패 — 부스트를 눌러도 재무장조차 되지 않았다).
  ///
  /// 이 컨트롤러의 10초 타이머는 같은 사건에서 정상 동작이 확인됐으므로
  /// 감시자로 쓴다. 하트비트가 45초 넘게 멈추면 전송 계층 유지보수를 다시
  /// 세운다(멱등).
  void _superviseMaintenance() {
    if (!started) return;
    final last = node.transport.lastMaintenanceTick;
    final stale = last == null ||
        DateTime.now().difference(last) > const Duration(seconds: 45);
    if (!stale) return;
    bleLogSink?.call('${DateTime.now().toIso8601String()} '
        'maintenance heartbeat stale — restarting transport maintenance');
    node.transport.restartMaintenance();
  }

  /// 웨이크 넛지의 친구 증거: 최근 비콘 리전 진입 또는 최근 SpotLink 광고
  /// 관측. 이벤트 타임스탬프는 UTC(Z)로 기록된다.
  Future<bool> _friendNearbyEvidence() async {
    // 1순위: 무선 판정. quiet/stackAged는 '상대 신호를 본 적 없음'이므로
    // 이 상태로 알림을 보내면 오탐이다([RadioHealth.hasPeerEvidence]).
    // 판정 자체가 최근 발견·링크 진전을 근거로 하므로 RSSI 관측과 겹치되,
    // 프리워밍/복원 웨이크를 걸러내는 기준이 코드 한 곳에 모인다.
    if (node.radioHealth.hasPeerEvidence) return true;
    final rssi = _lastRssiAt;
    if (rssi != null &&
        DateTime.now().difference(rssi) < const Duration(seconds: 60)) {
      return true;
    }
    try {
      final now = DateTime.now().toUtc();
      for (final e in await BeaconWake.wakeEvents()) {
        if (!e.startsWith('beacon-enter')) continue; // 복원 웨이크는 증거 아님
        final sp = e.lastIndexOf(' ');
        if (sp < 0) continue;
        final ts = DateTime.tryParse(e.substring(sp + 1));
        if (ts != null && now.difference(ts) < const Duration(minutes: 3)) {
          return true;
        }
      }
    } catch (_) {}
    bleLogSink?.call('${DateTime.now().toIso8601String()} '
        'wake nudge suppressed (no friend evidence)');
    return false;
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
    // 친구 증거 게이트: "백그라운드 재기동 + 링크 없음"만으로는 친구가
    // 근처라는 뜻이 아니다 — iOS 프리워밍·BLE 상태 복원도 같은 모양으로
    // 앱을 깨운다(2026-07-24 09:07 오탐 3연발 관찰). 알림은 (a) 최근
    // 몇 분 내 비콘 리전 진입(진짜 친구의 토치)으로 깨어났거나 (b) 최근
    // 60초 안에 SpotLink 광고를 실제로 봤을 때만 보낸다. 증거는 쿨다운
    // 스탬프를 태우기 전에 확인한다 — 증거가 늦게 도착하면 다음 10초
    // 폴에서 넛지가 나간다.
    if (!await _friendNearbyEvidence()) return;
    try {
      final dir = await AppPaths.dataDir();
      final stamp = File(p.join(dir.path, 'wake_nudge_at'));
      final now = DateTime.now().millisecondsSinceEpoch;
      if (stamp.existsSync()) {
        final last = int.tryParse(stamp.readAsStringSync().trim()) ?? 0;
        if (now - last < _MeshControllerBase._nudgeCooldown.inMilliseconds) {
          return;
        }
      }
      stamp.writeAsStringSync('$now');
    } catch (_) {
      return; // 영속화된 쿨다운 없음 → 알림 폭주 위험을 감수하지 않는다
    }
    bleLogSink?.call('${DateTime.now().toIso8601String()} wake nudge shown '
        '(background relaunch, linkless 10s, friend evidence ok)');
    await NotificationService.showMessage(
      conversationKey: 'wake-nudge',
      title: systemS.notifWakeNudgeTitle,
      body: systemS.notifWakeNudgeBody,
    );
    // 알림을 띄운 이 순간을 "스쳐간" 기록으로 남긴다. 비콘에는 신원이 없어
    // 미확인으로 남고, 곧이어 연결되면 그 친구로 승격된다.
    unawaited(_encounters?.onUnidentifiedNearby());
  }

  /// 마지막 링크가 방금 끊겼을 때: 디스크의 넛지 스탬프를 되감아 잔여
  /// 쿨다운을 최대 [_nudgeAfterDrop]으로 줄인다. 스탬프를 지우는 게 아니라
  /// 되감기만 하므로, 드롭이 반복돼도 넛지는 그 하한보다 잦아지지 않는다
  /// (2026-07-17 사례: 16:34 링크 다운 후 17분 단절 — 쿨다운이 남아 있으면
  /// 정작 재발견이 막힌 구간에 잠금화면 구제가 침묵한다).
  Future<void> _relaxWakeNudgeCooldown() async {
    if (!profile.supportsBeaconWake || headless) return;
    try {
      final dir = await AppPaths.dataDir();
      final stamp = File(p.join(dir.path, 'wake_nudge_at'));
      if (!stamp.existsSync()) return;
      final last = int.tryParse(stamp.readAsStringSync().trim()) ?? 0;
      final rewound = DateTime.now().millisecondsSinceEpoch -
          (_MeshControllerBase._nudgeCooldown -
                  _MeshControllerBase._nudgeAfterDrop)
              .inMilliseconds;
      if (last > rewound) stamp.writeAsStringSync('$rewound');
    } catch (_) {} // 스탬프를 못 만지면 기존 쿨다운 그대로 — 안전한 실패
  }

  /// [_linklessSince] 참고. iOS foreground 전용: [_linklessPulseAfter] 동안
  /// 링크를 하나도 갖지 못했을 때 wake torch를 펄스하여, 우리 비콘 리전 안에
  /// 갇힌 피어를 구조하고 멈춘 광고자를 풀어준다. 방해할 링크가 없다는 바로 그
  /// 이유로 단점이 없다.
  ///
  /// [force] = 사용자 명시 부스트(당겨서 새로고침): 30/60초 적응 임계를
  /// 기다리지 않고 즉시 펄스한다. 단 (1) 링크가 잠깐 끊겼다 바로 붙는 일시
  /// 블립에 40초 TX 블랙아웃을 낭비하지 않도록 무링크 10초 이상일 때만,
  /// (2) 연타가 펄스를 연쇄시켜 로테이션 웨이크를 계속 침묵시키지 않도록
  /// [_manualPulseCooldown] 안에 한 번만.
  void _maybeBeaconPulse({bool force = false}) {
    if (!profile.supportsBeaconWake ||
        headless ||
        !_foreground ||
        _beaconPulsing) {
      return;
    }
    final since = _linklessSince;
    if (since == null || linkCount > 0) return;
    if (force) {
      if (DateTime.now().difference(since) < const Duration(seconds: 10)) {
        return;
      }
      final last = _lastManualPulse;
      if (last != null &&
          DateTime.now().difference(last) <
              _MeshControllerBase._manualPulseCooldown) {
        return;
      }
      _lastManualPulse = DateTime.now();
    } else {
      final threshold = (_everLinked || _pulsedSinceBoot)
          ? _MeshControllerBase._pulseAfterDrop
          : _MeshControllerBase._pulseAfterBootLinkless;
      if (DateTime.now().difference(since) < threshold) return;
    }
    _beaconPulsing = true;
    _pulsedSinceBoot = true;
    bleLogSink?.call('${DateTime.now().toIso8601String()} '
        'beacon wake pulse (${force ? 'manual boost' : 'linkless auto'})');
    unawaited(BeaconWake.stopTx().then((_) {
      _beaconPulseTimer?.cancel();
      _beaconPulseTimer = Timer(_MeshControllerBase._beaconPulseGap, () {
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
        if (profile.usesAdaptivePower) unawaited(_evaluateAdaptivePower());
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
    // 전송 계층에는 `wasForeground` 게이트 없이 알린다. 부팅 낙관 기본값 때문에
    // `wasForeground`가 이미 true인 채로 진짜 포그라운드 진입이 오면, 예전에는
    // 이 호출까지 통째로 건너뛰어 전송이 백그라운드 모드(필터 스캔)에 갇혔다 —
    // iOS 27에서 필터 스캔은 포그라운드 iPhone을 볼 수 없으므로, 사용자가 앱을
    // 열고 쳐다보는 동안 친구를 영영 못 찾는 상태가 됐다. 값이 같으면 전송이
    // 스스로 no-op이라 공짜다.
    if (_foreground) node.setForeground(true);
    if (_foreground && !wasForeground) {
      // iOS가 우리를 서스펜드한 뒤 foreground로 복귀: 즉시 프레즌스를 다시
      // 알리고 디스커버리를 다시 걷어차, 우리(그리고 피어들)가 다음 15초 주기를
      // 기다리지 않고 온라인 상태를 회복하도록 한다.
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

  Future<void> _refreshBeaconStatus() async {
    final s = await BeaconWake.status();
    beaconMonitoring = s['monitoring'] == true;
    // 격하된 권한 상태를 UI에 드러낸다: 모니터링은 켜져 있지만 iOS가 "사용 중에만"
    // 권한만 줘서, 백그라운드에서는 아무것도 우리를 깨우지 못한다. 아래에서
    // 업그레이드 프롬프트를 여전히 띄우지만, 사용자가 한 번 거부하면 iOS는 그
    // 호출을 무시한다 — 그때는 배너 + 설정 바로가기가 유일한 탈출구다.
    beaconNeedsAlways =
        profile.supportsBeaconWake && beaconMonitoring && s['auth'] != 'always';
    // 모니터링은 기본값이 ON이지만(BeaconPlugin.swift 참고) "항상" 위치 권한이
    // 있어야만 동작한다 — 최초 실행 때 한 번 요청한다.
    // 비콘-웨이크 RX(리전 진입 시 종료된 앱을 재실행)는 authorizedAlways가
    // 필요하다. iOS는 첫 프롬프트에서 흔히 When-In-Use만 부여하는데 — 그러면
    // 모니터링은 백그라운드에서 쓸모없고, 예전 코드는 다시 요청하지 않았다.
    // whenInUse 상태에서 다시 요청하면 일회성 "항상 허용으로 변경?" 업그레이드
    // 프롬프트가 뜬다; 사용자가 거부하면 iOS는 이후 호출을 무시하므로, 반복해도
    // 무해하게 유지된다.
    if (profile.supportsBeaconWake &&
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
      final dir = await AppPaths.dataDir();
      // 재설치로 컨테이너 UUID가 바뀌어도 저장된 파일 경로가 살아나도록
      // 현재 Documents를 DB의 경로 재해석 기준으로 준다.
      AppDatabase.documentsDir = dir.path;
      // 데스크톱: sqflite 기본 경로가 TCC 보호 폴더라 DB를 열 수 없다 —
      // 항상 쓸 수 있는 앱 지원 디렉터리로 강제한다([AppPaths] 참고).
      // 모바일은 건드리지 않는다(기존 설치 데이터가 기본 경로에 있다).
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        AppDatabase.dbDir = dir.path;
      }
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
      // 완료된 수신 전송 id: 재시작 후 스토어가 재전달한 META를 알아보고
      // 유령 수신(바이트 없는 "수신 실패" 말풍선)을 만들지 않기 위해서다.
      final completedFile = File(p.join(dir.path, 'completed_transfers.json'));
      completedTransfersLoad = () async {
        try {
          if (!completedFile.existsSync()) return const <String>[];
          return (jsonDecode(await completedFile.readAsString()) as List)
              .cast<String>();
        } catch (_) {
          return const <String>[];
        }
      };
      completedTransfersSave = (tids) {
        try {
          completedFile.writeAsStringSync(jsonEncode(tids));
        } catch (_) {}
      };
      // 본딩 기록(peerHex → 식별자): 본딩된 식별자를 스테일 망각에서
      // 제외하고, 세션을 넘어 본딩 상태를 기억하기 위해서다.
      final bondFile = File(p.join(dir.path, 'bonded_peers.json'));
      bondedPeersLoad = () async {
        try {
          if (!bondFile.existsSync()) return const <String, String>{};
          return (jsonDecode(await bondFile.readAsString()) as Map)
              .cast<String, String>();
        } catch (_) {
          return const <String, String>{};
        }
      };
      bondedPeersSave = (peers) {
        try {
          bondFile.writeAsStringSync(jsonEncode(peers));
        } catch (_) {}
      };
    } catch (_) {} // 진단 수준의 영속화 — 시작을 절대 막지 않는다
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

  @override
  Future<void> boostDiscovery() async {
    if (!started) {
      // 메시가 아예 안 올라온 상태에서의 당김 = "다시 시도해 봐"라는 뜻.
      // 사용자가 방금 블루투스를 켰거나 권한을 줬을 수 있다 — 어댑터 이벤트를
      // 기다리지 않고 지금 시작을 재시도한다.
      await _onTransportAvailable(true);
      if (!started) return;
    }
    bleLogSink?.call('${DateTime.now().toIso8601String()} '
        'discovery boost (user pull-to-refresh)');
    await node.boostDiscovery();
    // 명시적 부스트는 웨이크 토치 펄스도 즉시 건다(임계 생략, 쿨다운으로
    // 연쇄 방지) — 스와이프킬로 우리 리전 안에 갇힌 상대는 스캔·대기연결로는
    // 절대 못 구하고 EXIT+ENTER만이 깨울 수 있다.
    _maybeBeaconPulse(force: true);
    if (profile.supportsScanPowerTuning) {
      // 60초 저지연 스캔 버스트: 적응형 전력의 "최근 토폴로지 변화" 창을
      // 재활용한다(수동 절약 토글이 켜져 있으면 그 하드 플로어가 이긴다).
      _lastTopoChange = DateTime.now();
      await _evaluateAdaptivePower();
    }
  }
}
