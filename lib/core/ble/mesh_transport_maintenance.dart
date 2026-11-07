part of 'mesh_transport.dart';

/// [MeshTransport]의 유지보수(Self-heal) 타이머, 하드 리셋, RSSI 폴링,
/// 어댑터 상태 감시, 링크 헬스 및 패킷 수집/절단 처리 책임.
extension _MeshTransportMaintenance on MeshTransport {
  /// 상태가 바뀔 때만 로그를 남긴다 — 다음 사건에서 사람이 로그를 손으로
  /// 해독하지 않고 "왜 못 찾았는지"를 바로 읽을 수 있게 하는 것이 목적이다.
  void _logHealthTransition() {
    final now = health;
    if (now == _lastHealth) return;
    _lastHealth = now;
    _log('BLE health: ${now.name} '
        '(links=${_links.length} '
        'sinceProgress=${DateTime.now().difference(_lastRadioProgress).inSeconds}s '
        'profile=${profile.name})');
  }

  /// 유지보수 타이머(15초): 좀비 링크 절단 → 광고·스캔 재확립 → deep heal →
  /// 하드리셋으로 이어지는 복구 사다리 전체가 이 틱 위에서 돈다.
  void _startMaintenanceTimer() {
    _selfHealTimer?.cancel();
    // 첫 틱은 15초 뒤다. 하트비트를 지금 찍어두지 않으면 10초마다 도는
    // 감시자가 부팅 직후 '한 번도 안 돌았다'며 불필요한 재기동을 건다
    // (2026-07-27 22:29:04 관찰: 부팅 10초 만에 last tick never로 오탐,
    // Android였다면 이 시점에 광고 주소까지 회전됐을 것).
    _lastMaintenanceTick = DateTime.now();
    _selfHealTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_started) return;
      _lastMaintenanceTick = DateTime.now();
      _logHealthTransition();
      // 좀비 peripheral 링크: 어떤 스택도 모든 곳에서 신뢰할 만한 "central
      // 이 떠남" 콜백을 쏘지 않으며, 죽은 P-링크는 UI에 거짓말을 하는 동시에
      // 새로 들어오는 연결에 대해 GATT 서버를 막아버릴 수 있다(삼성에서
      // 관찰됨: 낡은 링크가 남아 있는 동안 새 central들이 CBError 6으로
      // 타임아웃난다). ANNOUNCE heartbeat은 약 15초마다 도착하므로, 몇 분간의
      // 침묵은 central이 떠났다는 뜻이다.
      for (final link in _links.values.toList()) {
        // ANNOUNCE heartbeat는 ~15초마다 도착한다 — 6회(90초) 침묵이면 죽은
        // 링크다. 예전 3분은 죽은 P-링크가 "링크 있음"으로 버티는 동안
        // self-heal이 침묵해, 상대와의 상호 교착을 그만큼 연장시켰다.
        if (link.role == LinkRole.peripheral &&
            DateTime.now().difference(link.lastActivity) >
                const Duration(seconds: 90)) {
          _log('BLE peripheral link stale (silent 90s) — dropping ${link.id}');
          _tearDown(link.id);
        }
      }
      if (_links.isNotEmpty) {
        _linklessTicks = 0;
        // 링크가 있어도 라디오를 완전히 방치하면 안 된다: iOS는 긴 세션에서
        // scan 결과 전달을 조용히 멈출 수 있고, 광고도 격이 떨어질 수 있다 —
        // 이 상태로는 이미 연결된 피어와는 잘 지내지만 **세 번째 기기를 영영
        // 발견하지 못한다**. 2분마다 한 번 부드럽게 재확립한다(멱등 광고
        // start + scan 재활용; 기존 링크는 건드리지 않는다).
        _linkedTicks++;
        if (_linkedTicks % 8 == 0) {
          _log('BLE upkeep (linked): re-asserting discovery');
          if (_peripheral.state == BluetoothLowEnergyState.poweredOn &&
              _servicePublished) {
            unawaited(_startAdvertising());
          }
          if (_powerMode == PowerMode.active) {
            if (profile.alternatesScanWindows) {
              unawaited(_stopScanning().then((_) => _startScanning()));
            } else {
              unawaited(_startScanning());
            }
          }
        }
        return;
      }
      _linkedTicks = 0;
      _linklessTicks++;
      var scannerBlind = false;
      // 링크 0이 이어질 때, **무선이 무엇을 보고는 있는지**를 주기적으로
      // 남긴다. 예전에는 "안 붙는다"는 신고에 스캔 로그만 잔뜩 있고 상대를
      // 봤는지조차 알 수 없었다(2026-07-27 S21: heavy 로그에 S21 흔적 0,
      // 발견 자체가 없었는지 발견 후 실패였는지 구분 불가).
      if (_linklessTicks % 4 == 0) {
        scannerBlind = _sawTotal == 0;
        final seen = _lastDialAt.length;
        // scan= 은 **라디오에 실제로 걸려 있는 필터**다. fg= 와 함께 남긴다:
        // 이 둘이 어긋난 채(백그라운드인데 무필터 / 포그라운드인데 필터) 오래
        // 도는 것이 "친구가 근처인데 발견 0건"의 직접 원인이었고, 예전 로그로는
        // 그 상태를 사후에 확인할 방법이 없었다(2026-07-30 heavy).
        // saw/spot/apple: 지난 60초 동안 스캐너에 실제로 전달된 광고 수.
        // saw=0 = 스캐너가 아무것도 못 받음(모드 오류/세션 노화),
        // saw>0 spot=0 = 무선은 살아 있는데 상대의 SpotLink 광고가 없음
        // (상대 쪽 광고 문제) — 이 구분이 릴리즈 로그에서 가능해야 한다.
        _log('BLE linkless ${_linklessTicks * 15}s: '
            'dialed=$seen connecting=${_connecting.length} '
            'pending=${_pendingKeys.length} known=${_knownPeers.length} '
            'probeMiss=${_probeMisses.length} '
            'fg=$_foregroundScan scan=${_scanningUnfiltered == null ? 'off' : (_scanningUnfiltered! ? 'unfiltered' : 'filtered')} '
            'adv=${_advertising ? 'ok' : 'FAIL${_lastAdvertiseError ?? '?'}'} '
            'saw=$_sawTotal spot=$_sawSpotLink apple=$_sawApple');
        _sawTotal = 0;
        _sawSpotLink = 0;
        _sawApple = 0;
      }
      _log('BLE self-heal: no links — re-asserting radio');
      // Deep heal: 약 3분 연속 링크 없음 → GATT service도 republish한다.
      // 막히거나 낡은 서버(엔진 handoff 잔여물)는 들어오는 모든 connect를
      // 타임아웃나게 만든다; removeAll+add로 스택에 새 것을 준다.
      // 가벼운 heal(advertise/scan 재가동)은 15초 tick마다; 더 무거운 GATT
      // republish는 약 2분마다만 해서 connect 중인 피어를 방해하지 않게 한다.
      // 하드리셋 워치독: 링크도 발견도 몇 분간 전무하면 CoreBluetooth가
      // 조용히 죽은 것이다(iOS 27, ~19시간 세션에서 관찰). 스캔 stop→start와
      // GATT republish는 같은 네이티브 매니저 위에서 도는 것이라 이 상태를
      // 치료하지 못했다 — 앱 강제 재시작만이 답이었다(2026-07-25 13:09:
      // 재시작 4초 만에 gold와 링크, 밀린 메시지 18건 즉시 전달. 그전
      // 19.5시간 동안 발견 0건, 본딩 식별자 pending은 90초마다 만료 반복).
      // 네이티브 캐시(낡은 CBPeripheral 핸들 + 매달린 completion)를 비워
      // 프로세스 재시작 없이 같은 효과를 낸다.
      if (profile.needsStackHardReset) unawaited(_maybeHardResetCentral());
      final deep = _linklessTicks % 8 == 0;
      if (deep && _pendingKeys.isNotEmpty) {
        // 걸려 있는 pending들이 있는데도 몇 분간 링크 없음: 그것들은 죽은
        // rotate된 주소를 겨냥하고 있을 가능성이 높다. 전부 취소한다 —
        // 대신 scan/probe가 피어들의 살아 있는 주소를 찾아준다.
        _log('BLE deep heal: cancelling ${_pendingKeys.length} stale '
            'pending reconnects');
        for (final k in _pendingKeys.toList()) {
          final p = _pendingPeripherals[k];
          if (p != null) {
            unawaited(_central.disconnect(p).then((_) {}, onError: (_) {}));
          }
        }
        // 취소가 정리되고 나면 영속화된 목록에서 다시 건다. 취소만 해두면
        // 노드에 걸려 있는 connect가 전혀 없는 상태가 됐다 — 피어가 예전
        // 식별자로 돌아온다면(백그라운드, 같은 세션) 더 이상 그것을 기다리는
        // 게 아무것도 없었던 것이다.
        Timer(const Duration(seconds: 3), () {
          if (_started && profile.usesPendingConnect) {
            unawaited(_reconnectKnownPeers());
          }
        });
      }
      if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
        if (_servicePublished && !deep) {
          unawaited(_startAdvertising());
        } else {
          if (deep) _log('BLE self-heal: republishing GATT service');
          unawaited(_setupPeripheral()
              .then((_) => _startAdvertising(restart: true)));
        }
      }
      if (_powerMode == PowerMode.active) {
        // Android 7.0+는 30초 내 startScan이 5회 이상 호출되면
        // SCAN_FAILED_SCANNING_TOO_FREQUENTLY로 스캔을 조용히 죽인다.
        // connect마다 스캔을 일시정지하는 플랫폼(Android)에서 매 15초마다
        // 멀쩡한 스캔까지 강제로 껐다 켜면 30초 내 5회 제한에 걸려 영구
        // 스로틀링에 빠지므로, 평소에는 꺼져 있을 때만 켜고(_startScanning),
        // 60초간 아무 패킷도 못 받았을 때(scannerBlind)만 재활용한다.
        if (!profile.pausesScanWhileConnecting || scannerBlind) {
          unawaited(_stopScanning().then((_) => _startScanning()));
        } else {
          unawaited(_startScanning());
        }
      }
      // 아무것도 없을 때는 이전에 miss했던 Apple 기기를 더 빨리 다시 probe할
      // 수 있게 한다.
      if (_linklessTicks >= 4) {
        _probeMisses.clear();
        _probeBackoff.clear();
      }
    });
  }

  /// [_hardResetAfterSilence] 동안 발견·링크가 전무하면 네이티브 central
  /// 스택을 제자리에서 재초기화한다. 리셋 후에는 광고·스캔을 다시 세우고
  /// 알려진 피어 대기 연결을 재장전한다(식별자는 그대로 유효하다 — 죽은
  /// 것은 네이티브 핸들이었을 뿐이다).
  Future<void> _maybeHardResetCentral() async {
    if (_hardResetting || _disposed || !_started) return;
    // 판정을 단일 근거로 쓴다: 자체 복구가 필요한 상태(stackAged)에서만 돈다.
    // 링크 플랩(상대 스택 문제)이나 quiet(주변에 아무도 없음)에서 우리 스택을
    // 재초기화하는 것은 오진이다 — 판정 로직이 그 구분을 보증한다.
    if (!health.needsSelfRepair) return;
    final now = DateTime.now();
    final last = _lastHardReset;
    if (last != null && now.difference(last) < MeshTransport._hardResetMinGap) {
      return;
    }
    _hardResetting = true;
    _lastHardReset = now;
    try {
      _log('BLE hard reset: no discovery/link for '
          '${now.difference(_lastRadioProgress).inSeconds}s — '
          're-initialising native central');
      // 우리 쪽 부기부터 비운다: 네이티브가 모든 연결을 취소하므로 남겨두면
      // 유령 링크가 된다.
      for (final id in _links.keys.toList()) {
        _tearDown(id);
      }
      _connecting.clear();
      _pendingKeys.clear();
      _pendingPeripherals.clear();
      for (final t in _pendingTimers.values) {
        t.cancel();
      }
      _pendingTimers.clear();
      _lastDialAt.clear();
      _probeMisses.clear();
      _probeBackoff.clear();
      _scanning = false; // 네이티브가 스캔을 멈췄다
      try {
        await (_central as dynamic).hardReset();
      } on NoSuchMethodError {
        _log('BLE hard reset unsupported on this platform impl');
        return;
      }
      // 스캔·광고를 새로 세우고 알려진 피어를 다시 겨냥한다.
      await _startScanning();
      _beginScanModeCycle();
      if (_peripheral.state == BluetoothLowEnergyState.poweredOn) {
        await _startAdvertising(restart: true);
      }
      await _reconnectKnownPeers();
      _lastRadioProgress = DateTime.now(); // 재판정까지 유예
      _log('BLE hard reset done — rescanning + known peers re-armed');
    } catch (e) {
      _log('BLE hard reset failed: $e');
    } finally {
      _hardResetting = false;
    }
  }

  Future<void> _pollRssi() async {
    if (!_started) return;
    for (final link in _links.values.toList()) {
      if (link.role != LinkRole.central || link.peripheral == null) continue;
      try {
        final rssi = await link.enqueueOp(
          () => _central
              .readRSSI(link.peripheral!)
              .timeout(const Duration(seconds: 4)),
        );
        if (_disposed) return;
        _rssiFails.remove(link.id);
        if (link.remoteShortId != null) {
          _rssiSamples.add(RssiSample(link.remoteShortId, rssi));
        }
      } catch (_) {
        if (_disposed || !_links.containsKey(link.id)) return;
        // 반쯤 죽은 GATT 연결(suspend 도중 피어가 떠남, 스택 막힘)은
        // disconnect를 전혀 보고하지 않은 채 몇 분간 프레임을 삼킬 수 있다.
        // 연속 세 번의 read 실패 ≈ 15초의 침묵 — 우리가 직접 링크를 끊는다;
        // disconnect 경로가 pending reconnect를 다시 걸어준다.
        final fails = (_rssiFails[link.id] ?? 0) + 1;
        _rssiFails[link.id] = fails;
        if (fails >= MeshTransport._staleRssiFailures) {
          _log('BLE link stale ($fails failed RSSI reads) — cutting ${link.id}');
          _rssiFails.remove(link.id);
          try {
            await _central.disconnect(link.peripheral!);
          } catch (_) {
            // 무선이 disconnect마저 거부했다 — 로컬에서 teardown하고
            // reconnect를 직접 손으로 건다(disconnect 이벤트는 오지 않는다).
            _tearDown(link.id);
            _pendingReconnect(link.peripheral!);
          }
        }
      }
    }
  }

  /// 사용자가 블루투스를 껐다 다시 켤 때 자동으로 복구한다: 전원이 켜지면
  /// service를 다시 publish하고 다시 advertise/scan하며; 전원이 꺼지면 낡은
  /// 링크를 버린다.
  void _wireAdapterState() {
    _subs.add(_central.stateChanged.listen((e) async {
      if (!_started) return;
      if (e.state == BluetoothLowEnergyState.poweredOn) {
        if (_powerMode == PowerMode.active) {
          _beginScanModeCycle();
          await _startScanning();
        } else {
          _beginDutyCycle();
        }
      } else if (e.state == BluetoothLowEnergyState.poweredOff) {
        // saver duty-cycle 체인을 멈춘다. 그러지 않으면 _scanning을 계속
        // 뒤집으며 죽은 어댑터에 대고 실패가 뻔한 startDiscovery 호출을
        // 계속 날린다.
        _dutyTimer?.cancel();
        _dutyTimer = null;
        _scanModeTimer?.cancel();
        _scanModeTimer = null;
        _scanning = false;
        for (final id in _links.keys.toList()) {
          _tearDown(id);
        }
        _connecting.clear();
      }
    }));

    // peripheral 매니저 자체의 전원이 켜졌을 때만 GATT service를 publish하고
    // advertise한다 — 그 생명주기는 central의 것과 별개다.
    _subs.add(_peripheral.stateChanged.listen((e) async {
      _log('BLE peripheral state: ${e.state}');
      if (!_started) return;
      if (e.state == BluetoothLowEnergyState.poweredOn) {
        // 이미 publish되어 있으면 removeAllServices+addService를 다시 호출하지
        // 않는다 — Android/iOS에서 stateChanged(poweredOn)가 중복 전달될 때
        // 살아 있는 GATT 서비스와 원격 central의 구독 핸들을 날려버리는 것을 막는다.
        if (!_servicePublished) {
          await _setupPeripheral();
        }
        // start()에서와 같은 유령 교체(ghost-replacement): peripheral 매니저의
        // 전원이 늦게 켜질 때(iOS 상태 복원)의 부팅 경로다.
        await _startAdvertising(restart: true);
      } else {
        // poweredOn이 아닌 모든 상태에서 publish된 GATT 데이터베이스와 원격
        // 구독 상태가 사라진 것으로 본다 — 꺼짐만이 아니다. iOS는 bluetoothd가
        // 재시작되는 resetting(Dart에선 unknown)과 권한 회수(unauthorized)에서도
        // GATT 서비스를 지운다. 여기서 publish 표시를 남겨 두면 위의 중복
        // poweredOn 가드가 재등록을 건너뛰어, 광고는 나가는데 서비스가 없는
        // 상태로 deep heal(무링크 ~2분)까지 상대가 "service not found"로 실패한다.
        _servicePublished = false;
        _subscribedCentrals.clear();
      }
    }));
  }

  void _ingest(MeshLink link, Uint8List packet) {
    if (_disposed) return;
    link.lastActivity = DateTime.now();
    link.rxPackets++;
    final full = link.reassembler.offer(packet);
    if (full != null) {
      _inbound.add(InboundPacket(link, full));
    }
  }

  void _emitUp(MeshLink link) {
    if (_disposed) return;
    _lastRadioProgress = DateTime.now();
    _log('BLE link up ${link.id} (${link.role.name})');
    _logHealthTransition();
    _linkEvents.add(LinkEvent(link, true));
    // 신생 링크 좀비 워치독: 정상이면 상대 ANNOUNCE가 수 초 내 도착한다.
    // link up 후 이 창 동안 단 한 패킷도 안 왔다면 반쯤 죽은 ACL이다 —
    // 이런 링크는 write-without-response를 조용히 삼켜 아무 에러도 없이
    // 수 분간 "연결됨"으로 남는다(2026-07-18 19:23·07-19 09:46 heavy↔gold:
    // 앱 재시작으로만 복구되던 사건). 부기만 지우지 말고 물리 절단까지.
    //
    // 역할별 창: central(우리가 dial → GATT 셋업까지 끝내고 link up)은
    // 통신 준비가 이미 완료돼 12초 무수신이면 진짜 좀비다. peripheral(상대가
    // 우리에게 붙음 — subscribe만 해도 link up)은 상대가 우리 128비트
    // 서비스를 discover하고 TX write handle을 확보하기까지 더 걸린다. 특히
    // 삼성 One UI는 이 준비가 12초를 넘겨, 12초 컷이 삼성이 준비를 끝내려는
    // 찰나마다 끊고 삼성은 새 주소로 재연결 — 무한 재연결 루프가 됐다
    // (2026-07-24 12:38 삼성 최신폰 관찰: 5분간 P링크 up→12초 컷 반복,
    // 단 한 번도 안정화 못 함). 30초를 줘 상대의 느린 준비를 견딘다.
    final window = link.role == LinkRole.central
        ? const Duration(seconds: 12)
        : const Duration(seconds: 30);
    Timer(window, () {
      final l = _links[link.id];
      if (l == null || !identical(l, link) || l.rxPackets > 0) return;
      _log('BLE link zombie (no rx ${window.inSeconds}s) — cutting ${link.id}');
      _cutLink(l);
    });
    // 능동 생존 확인(central 링크): link up 직후에는 MeshNode가 초기
    // ANNOUNCE + HAVE를 즉시 전송하므로, 동시에 readCharacteristic을 호출하면
    // Android BluetoothGatt의 단일 busy 락과 충돌해 연결되자마자 링크가
    // 절단된다. 따라서 4초 뒤까지 아무 수신 패킷(rxPackets == 0)이 없을 때만
    // 링크 직렬화 큐(enqueueOp)를 통해 INFO를 읽어 생존을 확인한다.
    if (link.role == LinkRole.central &&
        link.peripheral != null &&
        link.remoteInfo != null) {
      Timer(const Duration(seconds: 4), () {
        final l = _links[link.id];
        if (l == null || !identical(l, link) || l.rxPackets > 0) return;
        unawaited(l
            .enqueueOp(() => _central
                .readCharacteristic(l.peripheral!, l.remoteInfo!)
                .timeout(const Duration(seconds: 8)))
            .then((_) {}, onError: (_) {
          final current = _links[link.id];
          if (current == null ||
              !identical(current, link) ||
              current.rxPackets > 0) {
            return;
          }
          _log('BLE liveness probe failed — cutting ${link.id}');
          _cutLink(current);
        }));
      });
    }
  }

  /// 링크를 진짜로 끊는다. [_tearDown](부기 제거)에 더해, central 링크는
  /// 물리 disconnect를 시도해 죽은 ACL이 다음 dial에 재사용되는 것을 막고
  /// pending reconnect를 다시 걸어준다 — 예전 send-실패 경로는 부기만 지워서,
  /// iOS가 살려둔 반쯤 죽은 ACL로 재-dial이 즉시 "성공"하며 좀비가 재발했다.
  /// peripheral 링크는 기록 제거만으로 linkless self-heal(광고 재확립)이
  /// 다시 돌기 시작한다 — 좀비를 쥔 3분 동안 광고가 침묵하던 것의 수정.
  void _cutLink(MeshLink link) {
    final peripheral =
        link.role == LinkRole.central ? link.peripheral : null;
    final key = link.id.substring(2);
    _tearDown(link.id);
    if (peripheral == null || !_started) return;

    // 플랩 차단기: 같은 상대를 90초 안에 세 번 이상 잘랐다면, 즉시 재연결을
    // 걸어봤자 또 잘린다(삼성 One UI의 느린 GATT 서버 = link up→write
    // 타임아웃→절단→재연결 타이트 루프, 2026-07-24 관찰). 이때는 즉시
    // 재연결을 재장전하지 않고 잠시 쉰다 — 상대는 자기 쪽 링크(우리 P:
    // 방향)로 여전히 우리에게 닿고, 이후 정식 discovery가 백오프를 두고
    // 다시 붙여준다. (gold의 반쯤 죽은 링크 1회성 복구는 임계 미만이라
    // 그대로 즉시 재연결된다.)
    final now = DateTime.now();
    final hist = _cutHistory[key] ??= [];
    hist.removeWhere((t) => now.difference(t) > MeshTransport._flapWindow);
    hist.add(now);
    final flapping = hist.length >= MeshTransport._flapCutThreshold;

    unawaited(_central
        .disconnect(peripheral)
        .then((_) {}, onError: (_) {})
        .whenComplete(() {
      if (!_started || _disposed) return;
      if (flapping) {
        _log(
            'BLE flap breaker: resting ${MeshTransport._flapRest.inSeconds}s on $key '
            '(${hist.length} cuts/${MeshTransport._flapWindow.inSeconds}s)');
        // dial 쿨다운을 미래로 밀어, discovery가 곧바로 다시 dial하지 못하게.
        _lastDialAt[key] = now.add(MeshTransport._flapRest);
        _cutHistory.remove(key); // 카운터 리셋 — 쉰 뒤 새로 판단
      } else {
        _pendingReconnect(peripheral);
      }
    }));
  }

  void _tearDown(String linkId) {
    _rssiFails.remove(linkId);
    // 이 피어의 dial 쿨다운을 지워, 그 advertisement이 다시 나타나는 즉시 곧바로
    // 다시 dial될 수 있게 한다(linkId는 'C:<key>'이다).
    if (linkId.startsWith('C:')) _lastDialAt.remove(linkId.substring(2));
    final link = _links.remove(linkId);
    if (link != null && !_disposed) {
      _log('BLE link down $linkId');
      _linkEvents.add(LinkEvent(link, false));
    }
  }
}
