part of 'mesh_transport.dart';

/// [MeshTransport]의 GATT Central 스캔/듀티 사이클, 기기 발견/Apple 프로브,
/// GATT 링크 수립, 대기 재연결(Pending Reconnect) 및 OS 본딩 유도 책임.
extension _MeshTransportCentral on MeshTransport {
  void _rememberPeer(String uuid) {
    _knownPeers.remove(uuid);
    _knownPeers.add(uuid);
    while (_knownPeers.length > MeshTransport._maxKnownPeers) {
      // 가장 오래된 것부터 밀어내되, 본딩된 id는 건너뛴다 — 주소 회전에도
      // 죽지 않는 유일한 재장전 후보를 뜨내기 id가 밀어내면 안 된다.
      final victim = _knownPeers.firstWhere(
          (id) => !_bondedPeers.containsValue(id),
          orElse: () => _knownPeers.first);
      _knownPeers.remove(victim);
    }
    knownPeersSave?.call(_knownPeers.toList());
  }

  /// iOS: 영속화된 모든 피어에 대해 pending connect를 세워 둔다. 걸려 있는
  /// connect들이 scan으로 생기는 링크의 [maxLinks] 슬롯을 굶기지 않도록
  /// 상한을 둔다.
  Future<void> _reconnectKnownPeers() async {
    try {
      final saved = await knownPeersLoad?.call() ?? const <String>[];
      if (saved.isEmpty) return;
      _knownPeers.addAll(saved);
      final budget = maxLinks - _links.length - _connecting.length - 2;
      var armed = 0;
      for (final uuid in MeshTransport.pendingReconnectOrder(saved, budget,
          bonded: _bondedPeers.values.toSet())) {
        try {
          final peripheral = await _central.getPeripheral(uuid);
          if (_links.containsKey('C:$uuid') || _connecting.contains(uuid)) {
            continue;
          }
          // 좀비 출생 경로 차단: 이전 프로세스/세션이 남긴 반쯤 죽은 시스템
          // ACL 위로 connect가 즉시 "성공"하면 트래픽 0의 좀비로 태어난다
          // (2026-07-19 19:40:06 관찰 — 부팅 3초 만에 link up, write 전부
          // 타임아웃). 링크 부기가 없는 peripheral의 잔존 연결은 정의상
          // 죽은 것이므로, 걸기 전에 끊어 새 ACL을 강제한다.
          try {
            await _central
                .disconnect(peripheral)
                .timeout(const Duration(seconds: 2));
          } catch (_) {}
          _pendingReconnect(peripheral);
          armed++;
        } catch (_) {} // 형식이 잘못됐거나 알 수 없는 id — 대신 scan이 찾아준다
      }
      if (armed > 0) _log('BLE known-peer reconnect armed x$armed');
    } catch (_) {}
  }

  Future<void> _ensureBondedImpl(String peerHex) async {
    if (!_started || _bondAttempted.contains(peerHex)) return;
    MeshLink? link;
    for (final l in _links.values) {
      if (l.role == LinkRole.central &&
          l.remoteShortId?.hex == peerHex &&
          l.remoteBond != null &&
          l.peripheral != null) {
        link = l;
        break;
      }
    }
    if (link == null) return; // 직접 central 링크 없음(멀티홉 또는 구버전 피어)
    _bondAttempted.add(peerHex);
    // 양쪽이 동시에 SMP를 개시해 충돌하지 않도록 id 사전순으로 시차를 둔다 —
    // 늦은 쪽은 이미 암호화된 링크를 만나 조용히 성공한다.
    final delay = myShortId.hex.compareTo(peerHex) < 0
        ? const Duration(seconds: 1)
        : const Duration(seconds: 8);
    await Future<void>.delayed(delay);
    if (!_started || !_links.containsKey(link.id)) {
      _bondAttempted.remove(peerHex); // 링크가 사라짐 — 다음 링크에서 재시도
      return;
    }
    try {
      // 상한에는 사용자가 페어링 다이얼로그에서 고민할 시간도 포함된다.
      final targetLink = link;
      Future<Uint8List> read() => _central
          .readCharacteristic(targetLink.peripheral!, targetLink.remoteBond!)
          .timeout(const Duration(seconds: 60));
      // 이 읽기는 페어링 창이 떠 있는 동안(최대 60초) 끝나지 않는다. 링크
      // 직렬화 큐에 넣으면 그동안 이 링크의 모든 송신(ANNOUNCE·메시지)이 뒤에서
      // 기다린다. 한 번에 GATT 작업 하나만 받는 스택(Android)에서는 그래도
      // 큐가 낫다 — 큐 밖에서 쓰면 쓰기가 busy로 실패해 링크가 잘린다. 스택이
      // 스스로 줄을 세우는 곳(CoreBluetooth)에서는 큐를 비켜 송신을 막지 않는다.
      await (profile.serializesGattOps ? targetLink.enqueueOp(read) : read());
      final key = targetLink.id.substring(2);
      _bondedPeers[peerHex] = key;
      bondedPeersSave?.call(Map.of(_bondedPeers));
      _log('BLE bonded with peer $peerHex ($key)');
    } catch (e) {
      // 거절/타임아웃/링크 소실 — 이번 세션은 조용히 물러난다.
      _log('BLE bond attempt failed for $peerHex: $e');
    }
  }

  void _scheduleReconnect(Peripheral peripheral, String key) {
    if (!profile.usesPendingConnect || _disposed || !_started) return;
    final attempt = (_reconnectAttempts[key] ?? 0) + 1;
    _reconnectAttempts[key] = attempt;
    final delay = switch (attempt) {
      1 => const Duration(seconds: 5),
      2 => const Duration(seconds: 15),
      3 => const Duration(seconds: 60),
      _ => const Duration(minutes: 5),
    };
    _log('BLE reconnect retry #$attempt in ${delay.inSeconds}s: $key');
    _reconnectTimers[key]?.cancel();
    _reconnectTimers[key] = Timer(delay, () {
      _reconnectTimers.remove(key);
      if (_disposed || !_started) return;
      _pendingReconnect(peripheral);
    });
  }

  Future<void> _startScanning() async {
    // connect handshake가 진행 중인 동안은 미뤄둔다(Android 133 수정) —
    // connect의 finally 블록이 scanning을 재개한다.
    if (_scanPausedForConnect) return;
    // 이 창에 걸어야 할 필터를 먼저 계산한다 — no-op 판정의 기준이 "스캔 중인가"가
    // 아니라 "원하는 모드로 스캔 중인가"여야 한다([_scanningUnfiltered] 참고).
    //
    // OS가 허용하는 한 언제나 UNFILTERED로 scan하고, SpotLink 여부는
    // 소프트웨어에서 매칭한다(see [_isSpotLink]):
    // - Android: 하드웨어 service-UUID 필터가 iPhone의 overflow 영역
    //   advertisement을 아예 매칭하지 못한다(Results=0).
    // - iOS 포그라운드: iOS 27(beta 24A5380h)에서는 다른 iPhone의 128비트
    //   service UUID가 필터에 매칭되지도, 파싱된 advertisement에 드러나지도
    //   않는다(관찰됨: unfiltered scan은 그 피어를 name-'SL'만 있는 패킷으로
    //   보는 반면, filtered scan은 bluetoothd에 "0 advertisements delivered"를
    //   남긴다). 거기서 iPhone 피어를 실제로 찾아내는 것은 이름 매칭이다.
    // - iOS 백그라운드: unfiltered scan은 아무것도 전달하지 않으므로(OS
    //   규칙) UUID 필터가 필요하다 — [setForeground]가 모드를 바꿔준다.
    final unfiltered = profile.useUnfilteredScan(
      foreground: _foregroundScan,
      overflowPhase: _overflowPhase,
      diagOverride: _diagUnfilteredScan,
    );
    if (_scanning) {
      if (_scanningUnfiltered == unfiltered) return; // 이미 원하는 모드다
      // 모드를 바꿔야 한다: 네이티브 스캔을 진짜로 교체한다. 이것이 없으면
      // 호출자가 phase만 뒤집고 라디오는 옛 필터로 계속 도는 상태가 된다.
      await _stopScanning();
    }
    _scanning = true;
    try {
      await _central.startDiscovery(
        serviceUUIDs: unfiltered ? null : [BleConstants.serviceUuid],
      );
      _scanningUnfiltered = unfiltered;
      _log('BLE scanning started (${unfiltered ? 'unfiltered' : 'filtered'})');
    } catch (e) {
      // 다음 시도가 실제로 재시도되도록 플래그를 내려둔다 — 실패한 start
      // 이후 여기서 "true"에 막혀 있으면(예: 어댑터가 headless 엔진과 UI 엔진
      // 사이에서 handoff 중이었음) 무선이 영원히 벙어리가 됐다.
      _scanning = false;
      _scanningUnfiltered = null;
      _log('BLE startDiscovery failed: $e');
    }
  }

  Future<void> _stopScanning() async {
    if (!_scanning) return;
    _scanning = false;
    _scanningUnfiltered = null;
    try {
      await _central.stopDiscovery();
    } catch (_) {}
  }

  /// Android: connect handshake 동안 scan을 멈춰, 무선이 scanning과
  /// connecting으로 갈라지지 않게 한다(`status 133`의 원인). refcount 방식이라
  /// 겹치는 connect들이 한 번만 pause하고 한 번만 resume한다.
  Future<void> _pauseScanForConnect() async {
    _connectDepth++;
    if (_connectDepth == 1) {
      _scanPausedForConnect = true;
      await _stopScanning();
    }
  }

  void _resumeScanForConnect() {
    if (_connectDepth > 0) _connectDepth--;
    if (_connectDepth > 0 || !_scanPausedForConnect) return;
    _scanPausedForConnect = false;
    if (!_started) return;
    if (_powerMode == PowerMode.active) {
      unawaited(_startScanning());
    } else {
      _beginDutyCycle();
    }
  }

  void _beginDutyCycle() {
    _dutyTimer?.cancel();
    // scan window, 그다음 idle window, 반복.
    Future<void> onTick() async {
      await _startScanning();
      _dutyTimer = Timer(MeshTransport._saverScanOn, () async {
        await _stopScanning();
        _dutyTimer = Timer(MeshTransport._saverScanOff, onTick);
      });
    }

    onTick();
  }

  /// iOS 포그라운드 scan 모드 교대를 wide window로 시작하며 (재)시작한다.
  /// See [_scanModeTimer]. iOS/포그라운드/active가 아니면 no-op(saver duty
  /// cycle과 백그라운드 filtered scan이 나머지를 커버한다).
  void _beginScanModeCycle() {
    _scanModeTimer?.cancel();
    _scanModeTimer = null;
    _overflowPhase = false;
    if (!profile.alternatesScanWindows || _diagUnfilteredScan) return;
    if (!_started || !_foregroundScan || _powerMode != PowerMode.active) {
      return;
    }
    void schedule() {
      _scanModeTimer = Timer(
          _overflowPhase
              ? MeshTransport._overflowScanWindow
              : MeshTransport._wideScanWindow, () {
        if (!_started || !_foregroundScan || _powerMode != PowerMode.active) {
          return;
        }
        _overflowPhase = !_overflowPhase;
        unawaited(_stopScanning().then((_) => _startScanning()));
        schedule();
      });
    }

    schedule();
  }

  void _wireCentral() {
    _subs.add(_central.discovered.listen((e) => _onDiscovered(e)));

    _subs.add(_central.connectionStateChanged.listen((e) {
      if (e.state == ConnectionState.disconnected) {
        final key = e.peripheral.uuid.toString();
        final hadLink = _links.containsKey('C:$key');
        _tearDown('C:$key');
        _connecting.remove(key);
        // iOS: 두 앱이 모두 백그라운드면 scan 기반 재발견은 눈이 먼다 —
        // 백그라운드 peripheral의 advertisement은 overflow 영역으로 옮겨가고,
        // 그건 *포그라운드* 스캐너만 볼 수 있다. 하지만 알려진 peripheral로
        // 향한 pending connect()는 절대 타임아웃되지 않고 피어가 범위 안으로
        // 돌아오는 즉시 백그라운드에서 완료되므로, 확립된 링크가 끊길 때마다
        // 하나 다시 걸어둔다.
        if (hadLink) _pendingReconnect(e.peripheral);
      }
    }));

    _subs.add(_central.characteristicNotified.listen((e) {
      if (e.characteristic.uuid != BleConstants.rxCharacteristicUuid) return;
      final link = _links['C:${e.peripheral.uuid}'];
      if (link != null) _ingest(link, e.value);
    }));
  }

  /// unfiltered Android scan은 근처의 모든 BLE 기기를 드러낸다 — peripheral이
  /// 실제로 SpotLink일 때만 받아들인다: scan 레코드에 우리 service UUID가
  /// 있거나, (UUID가 overflow 영역에 숨은 iOS 피어의 경우) 우리가 advertise한
  /// local name 'SL'이 있을 때.
  bool _isSpotLink(Advertisement adv) {
    if (adv.serviceUUIDs.contains(BleConstants.serviceUuid)) return true;
    if (adv.name == BleConstants.advertisedName) return true;
    // 일부러 manufacturer id로는 매칭하지 않는다: 우리 것은 0xFFFF(예약/테스트
    // id)인데, 잡다한 기기들도 이를 내보낸다 — KT GiGA Genie 스피커가
    // 매칭되어 "SpotLink 피어"로 dial됐다(관찰됨). 진짜 SpotLink
    // advertisement은 언제나 service UUID 그리고/또는 이름을 담는다;
    // manufacturer data는 이미 매칭된 뒤의 shortId 힌트일 뿐이다.
    return false;
  }

  bool _isIosProbeCandidate(DiscoveredEventArgs e) {
    if (!profile.probesAppleDevices) return false;
    if (e.rssi < -70) return false; // 가까운 기기만 dial할 가치가 있다
    if (_activeProbes.length >= MeshTransport._maxConcurrentProbes) return false;
    final uuid = e.peripheral.uuid.toString();
    final missedAt = _probeMisses[uuid];
    if (missedAt != null &&
        DateTime.now().difference(missedAt) < MeshTransport._probeMissTtl) {
      return false;
    }
    final failedAt = _probeBackoff[uuid];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < MeshTransport._probeFailBackoff) {
      return false;
    }
    return e.advertisement.manufacturerSpecificData.any((m) =>
        m.id == MeshTransport._appleManufacturerId &&
        MeshTransport.isProbeableAppleData(m.data));
  }

  Future<void> _onDiscovered(DiscoveredEventArgs e) async {
    _sawTotal++;
    if (_isSpotLink(e.advertisement)) _sawSpotLink++;
    if (e.advertisement.manufacturerSpecificData
        .any((m) => m.id == MeshTransport._appleManufacturerId)) {
      _sawApple++;
    }
    if (_logBle) {
      final a = e.advertisement;
      _log('BLE saw ${e.peripheral.uuid.toString().substring(0, 8)} '
          'name=${a.name} svc=${a.serviceUUIDs.length}'
          '${a.serviceUUIDs.isNotEmpty ? "[${a.serviceUUIDs.first}]" : ""} '
          'mfr=${a.manufacturerSpecificData.length} rssi=${e.rssi} '
          'match=${_isSpotLink(a)}');
    }
    // iOS에서는 하드웨어에서 필터링되고, Android의 unfiltered scan에서는
    // 소프트웨어에서 처리되어 잡다한 헤드폰/beacon을 절대 dial하지 않는다.
    // 아주 가까운 Apple 기기는 대신 probe dial을 받는다: 백그라운드 iPhone의
    // advertisement에는 SpotLink 표식이 전혀 없으므로(see
    // [_isIosProbeCandidate]) — GATT discovery만이 판별할 수 있는 유일한
    // 방법이다.
    final probe = !_isSpotLink(e.advertisement);
    if (probe && !_isIosProbeCandidate(e)) return;

    final remoteId = _shortIdFromAdvertisement(e.advertisement);

    // 우리 자신의 advertisement에는 절대 연결하지 않는다(일부 스택에서 발생할 수 있다).
    if (remoteId != null && remoteId == myShortId) return;

    // advertisement은 실시간 신호 세기 측정값을 담고 있다 — 이를 근접 UI로
    // 드러낸다(adv에 manufacturer id가 없으면 peer는 null이다).
    if (!_disposed) _rssiSamples.add(RssiSample(remoteId, e.rssi));

    // 여기서는 일부러 tie-break을 하지 않는다. 크로스 플랫폼 discovery는
    // 비대칭이다: iOS는 manufacturer data를 벗겨내고 128비트 service UUID를
    // Android가 자주 파싱하지 못하는 overflow 영역에 넣으므로, iOS advertiser는
    // Android에게 보이지 않을 수 있다. "우리 id가 더 크다"는 이유로 connect를
    // 건너뛰면, Android<->iOS 쌍이 아예 링크 없는 상태로 끝날 수 있다.
    // 대신 모든 노드는 자기가 discover할 수 있는 모든 SpotLink peripheral에
    // 연결한다. 중복되는 역방향 링크(예: 두 Android 기기 사이)는 무해하다:
    // 라우터가 msgId로 중복 제거하므로 무엇도 두 번 전달되지 않는다 — 그저
    // 연결 하나가 더 드는 것뿐이다. docs/ARCHITECTURE.md §11 참고.

    // 배터리/메모리 사용을 제한하기 위해 링크 상한을 지킨다. 진행 중인
    // (in-flight) 연결도 함께 센다. 그러지 않으면 discovery 폭주가 상한을 넘길
    // 수 있다(어떤 connect도 완료되기 전에는 모든 이벤트가 _links를 여전히 빈
    // 상태로 본다) — 다만 걸려 있는 pending-reconnect는 세지 않는다: 죽은 rotate된
    // 주소로 향한 pending이 살아 있는 discovery를 굶겨서는 절대 안 된다(그것이
    // 조용히 모든 피어를 오프라인으로 만들었다).
    if (_links.length + (_connecting.length - _pendingKeys.length) >=
        maxLinks) {
      return;
    }

    final key = e.peripheral.uuid.toString();
    if (_links.containsKey('C:$key') || _connecting.contains(key)) return;
    // discovery 폭주가 실패 폭풍이 되지 않도록 키별로 rate-limit한다 — 다만
    // 점점 커지는 백그라운드 backoff(최대 5분)가 이 경로를 억누르게 두지는
    // 않는다: discovery는 피어가 지금 당장 물리적으로 존재한다는 뜻이므로,
    // 짧은 쿨다운이면 충분하다. (이것이 "브리지를 죽이면 모두가 5분간 오프라인이
    // 되는" 버그였다.) 지금 당장 행동하는 것이 예약된 재시도를 대체하므로,
    // 그것을 취소한다.
    final last = _lastDialAt[key];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 12)) {
      return;
    }
    _lastDialAt[key] = DateTime.now();
    _lastRadioProgress = DateTime.now(); // 무선이 살아 있다는 증거
    _reconnectTimers.remove(key)?.cancel();
    _connecting.add(key);
    _log(probe
        ? 'BLE probing Apple device $key (rssi=${e.rssi})'
        : 'BLE discovered $key (shortId=$remoteId)');
    await _establishLink(e.peripheral, key, remoteId: remoteId, probe: probe);
  }

  /// 링크된 적 있는 피어에 대해 백그라운드에서도 견디는 연결을 다시 걸어둔다.
  /// iOS 전용이다: 다른 곳에서는 (포그라운드 서비스) 스캐너가 문제없이
  /// reconnect하고, Android의 connect()는 재시도하는 동안 무선 슬롯을 막을 수
  /// 있다. pending 시도는 [_connecting] 슬롯을 하나 차지해 discovery가 이와
  /// 경쟁하지 않게 한다; 피어가 다시 나타나면 언제든 완료된다 — 몇 분 뒤여도
  /// 괜찮다.
  void _pendingReconnect(Peripheral peripheral) {
    if (!profile.usesPendingConnect) return;
    if (_disposed || !_started) return;
    final key = peripheral.uuid.toString();
    if (_links.containsKey('C:$key') || _connecting.contains(key)) return;
    // 걸려 있는 pending들에 상한을 두고, 가장 오래된 것을 밀어낸다 — rotate된
    // (죽은) 주소가 흔한 경우이고, 가장 최신 것이 살아 있을 가능성이 가장 높다.
    while (_pendingKeys.length >= MeshTransport._maxPendingReconnects) {
      final oldest = _pendingKeys.first;
      final old = _pendingPeripherals[oldest];
      // 축출도 만료와 같은 이유로 즉시 슬롯을 푼다(아래 disconnect가 connect
      // future를 완료시키지 못할 수 있다).
      _releasePendingSlot(oldest);
      _log('BLE pending reconnect evicted $oldest');
      if (old != null) {
        // 취소하면 그것의 connect()가 throw하게 되고; 그러면 establishLink
        // 정리 과정이 _connecting 슬롯을 풀어준다.
        unawaited(_central.disconnect(old).then((_) {}, onError: (_) {}));
      }
    }
    _connecting.add(key);
    _pendingKeys.add(key);
    _pendingPeripherals[key] = peripheral;
    _pendingTimers[key]?.cancel();
    _pendingTimers[key] = Timer(
        MeshTransport._pendingStaleTimeout, () => _expireStalePending(key));
    _log('BLE pending reconnect armed $key');
    unawaited(_establishLink(peripheral, key));
  }

  /// [_pendingTimers] 참고. 걸려 있는 pending connect가 링크를 만들지 못한 채
  /// [_pendingStaleTimeout]을 넘겼을 때 발동한다: 슬롯을 풀어주고, strike가 두
  /// 번 쌓이면 식별자를 잊어버려 매번의 deep-heal / 부팅에서 다시 ARM되지 않게
  /// 한다.
  void _expireStalePending(String key) {
    _pendingTimers.remove(key);
    if (_links.containsKey('C:$key')) return; // 그 사이에 연결됨
    if (!_pendingKeys.contains(key)) return; // 이미 해소됨 / 밀려남
    if (_bondedPeers.containsValue(key)) {
      // 본딩된 피어의 식별자는 주소 회전으로 죽지 않는다 — 만료는 상대가
      // 지금 범위 밖/전원 꺼짐이라는 뜻일 뿐이다. 슬롯은 풀되 절대 잊지
      // 않는다(잊으면 본딩의 존재 이유가 사라진다).
      _log('BLE pending reconnect expired $key (bonded — identifier kept)');
    } else {
      final strikes = (_pendingStaleStrikes[key] ?? 0) + 1;
      _pendingStaleStrikes[key] = strikes;
      if (strikes >= 2 && _knownPeers.remove(key)) {
        knownPeersSave?.call(_knownPeers.toList());
        _pendingStaleStrikes.remove(key);
        _log('BLE forgetting stale peer identifier $key '
            '(no link in ${MeshTransport._pendingStaleTimeout.inSeconds}s x$strikes)');
      } else {
        _log('BLE pending reconnect expired $key (strike $strikes)');
      }
    }
    final p = _pendingPeripherals[key];
    // 슬롯을 **여기서 즉시** 푼다. 예전에는 disconnect가 connect future를
    // throw시켜 establishLink의 finally가 풀어주길 기대했는데, CoreBluetooth는
    // 아직 성립되지 않은 pending connect를 취소해도 그 future를 완료시키지
    // 않는 경우가 있다(네이티브 initialize()는 아예 completion 클로저를
    // 버린다). 그러면 키가 _connecting에 영원히 남아 **그 피어에 대한 모든
    // 재연결·발견 다이얼이 조용히 건너뛰어진다** — 스캔·광고·부스트는 정상
    // 동작하므로 겉보기엔 멀쩡하다(2026-07-26 heavy: 10:49 만료 후 50분간
    // links=0, 부스트를 눌러도 재무장 0건).
    _releasePendingSlot(key);
    if (p != null) {
      unawaited(_central.disconnect(p).then((_) {}, onError: (_) {}));
    }
  }

  /// 대기 연결 슬롯 부기를 즉시 해제한다(멱등). 늦게 완료되는 establishLink의
  /// finally가 다시 호출해도 무해하다.
  void _releasePendingSlot(String key) {
    _connecting.remove(key);
    _pendingKeys.remove(key);
    _pendingPeripherals.remove(key);
    _pendingTimers.remove(key)?.cancel();
  }

  /// SpotLink peripheral에 연결하고 GATT 링크를 올린다. 호출자는 [key]를
  /// [_connecting]에 추가해 두었어야 한다; 완료되면 여기서 제거된다.
  Future<void> _establishLink(Peripheral peripheral, String key,
      {PeerId? remoteId, bool probe = false}) async {
    final linkId = 'C:$key';
    var connected = false; // _central.connect가 성공했는가?
    var serviceMissing = false; // 연결됐지만 SpotLink service가 없음
    var linked = false; // 링크가 성립해 _links에 올라갔는가?
    if (probe) _activeProbes.add(key);
    final pauseScan = profile.pausesScanWhileConnecting;
    try {
      // Android: connect 동안 scanning을 멈춰, 무선이 scan + connect로 갈라지지
      // 않게 한다(status 133). iOS는 계속 scan한다 — 그 pending reconnect는
      // 설계상 오래 사는 것이고 CoreBluetooth가 중재해준다.
      if (pauseScan) await _pauseScanForConnect();
      try {
        // 무작위 Apple 기기로 향한 probe dial이 GATT 클라이언트 슬롯을 쥔 채
        // Android의 꽉 찬 ~30초 connectGatt 타임아웃 동안 매달려 있어서는 안
        // 된다 — 그래서 상한을 둔다. Android의 non-probe connect에도 상한을 둬,
        // 막힌 dial이 scan을 영원히 일시정지된 채로 붙들지 못하게 한다; iOS의
        // non-probe connect는 상한 없이 둔다(pending reconnect는 설계상 몇 분 뒤에
        // 완료된다).
        final connectBudget =
            probe ? const Duration(seconds: 8) : profile.connectTimeout;
        if (connectBudget != null) {
          await _central.connect(peripheral).timeout(connectBudget);
        } else {
          await _central.connect(peripheral);
        }
      } finally {
        if (pauseScan) _resumeScanForConnect();
      }
      connected = true;
      // OS 레벨 connect 이후의 모든 것에는 상한이 있다: 응답 프레임 하나(discovery
      // 응답, CCCD ack)만 유실돼도 예전에는 이 await 체인이 영원히 매달렸다 —
      // _connecting 슬롯이 계속 점유된 채라, 앱을 재시작하기 전까지는 그 피어를
      // 다시 dial할 수 없었다(관찰됨: idle 상태의 두 폰이 establish 도중 서로 20분
      // 넘게 막혀 있었다). 위의 connect()는 non-probe 경로에서 일부러 상한 없이
      // 둔다 — iOS의 pending reconnect는 설계상 몇 분 뒤에 완료된다.
      final (tx, rx, bond, info, maxPacket) = await () async {
        var services = await _central.discoverGATT(peripheral);
        var hasSvc = services.any((s) => s.uuid == BleConstants.serviceUuid);
        // SpotLink service가 없는 SpotLink advertiser는 거의 언제나 재실행
        // 도중인 iOS 앱이다: iOS가 백그라운드에서 앱을 죽이면, 상태 복원이 앱
        // 대신 계속 advertising하지만, GATT service는 재실행된 앱이 그것을 다시
        // publish해야만 돌아온다 — 우리의 connect(바로 그 앱을 깨우는 이벤트)
        // 몇 초 뒤에 말이다. 즉시 연결을 끊으면 앱을 곧바로 다시 suspend시켜
        // 영원히 루프를 돈다("connect → service not found → disconnect"를 15초마다,
        // 몇 시간 동안 관찰됨). 연결을 유지하면 앱에 백그라운드 실행 시간을
        // 준다: 포기하기 전에 기다렸다 다시 살펴본다.
        if (!hasSvc && !probe) {
          for (var attempt = 0; attempt < 2 && !hasSvc; attempt++) {
            await Future<void>.delayed(const Duration(seconds: 4));
            services = await _central.discoverGATT(peripheral);
            hasSvc = services.any((s) => s.uuid == BleConstants.serviceUuid);
          }
          if (hasSvc) _log('BLE service appeared after relaunch wait: $key');
        }
        if (!hasSvc) {
          serviceMissing = true;
          throw StateError('service not found');
        }
        final svc =
            services.firstWhere((s) => s.uuid == BleConstants.serviceUuid);
        GATTCharacteristic? tx, rx, bond, info;
        for (final c in svc.characteristics) {
          if (c.uuid == BleConstants.txCharacteristicUuid) tx = c;
          if (c.uuid == BleConstants.rxCharacteristicUuid) rx = c;
          if (c.uuid == BleConstants.bondCharacteristicUuid) bond = c;
          if (c.uuid == BleConstants.infoCharacteristicUuid) info = c;
        }
        if (tx == null || rx == null) {
          throw StateError('characteristics not found');
        }

        var maxPacket = BleConstants.defaultMaxPacketSize;
        try {
          await _central
              .requestMTU(peripheral, mtu: 247)
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
        try {
          maxPacket = await _central.getMaximumWriteLength(
            peripheral,
            type: GATTCharacteristicWriteType.withoutResponse,
          );
        } catch (_) {
          maxPacket = BleConstants.targetMaxPacketSize;
        }

        await _central.setCharacteristicNotifyState(peripheral, rx,
            state: true);
        return (tx, rx, bond, info, maxPacket);
      }()
          .timeout(const Duration(seconds: 25));

      // 연결을 기다리는 동안 stop/dispose됐을 수 있다. _links를 되살리거나 닫힌
      // 컨트롤러에 emit하지 말고 — 그냥 disconnect한다.
      if (!_started) {
        try {
          await _central.disconnect(peripheral);
        } catch (_) {}
        return;
      }

      final link = MeshLink(
        id: linkId,
        role: LinkRole.central,
        peripheral: peripheral,
        remoteTx: tx,
        remoteRx: rx,
        remoteBond: bond,
        remoteInfo: info,
        maxPacketSize: maxPacket.clamp(BleConstants.defaultMaxPacketSize, 512),
      )..remoteShortId = remoteId;
      _links[linkId] = link;
      linked = true;
      _emitUp(link);
      if (probe) _log('BLE probe hit: $key is a SpotLink peer');
      _reconnectAttempts.remove(key);
      _reconnectTimers.remove(key)?.cancel();
      _pendingStaleStrikes.remove(key); // 링크 성립 → 식별자가 살아있음이 입증됨
      _probeMisses.remove(key);
      _probeBackoff.remove(key);
      _rememberPeer(key);
    } catch (err) {
      try {
        await _central.disconnect(peripheral);
      } catch (_) {}
      if (probe) {
        if (connected && serviceMissing) {
          // 확정적으로 SpotLink가 아님(연결됐지만 service 없음) — 이 Apple
          // 기기를 더 이상 dial하지 않도록 TTL 전체 동안 차단한다.
          _probeMisses[key] = DateTime.now();
          _log('BLE probe miss $key (not SpotLink)');
        } else {
          // connect 자체가 실패함 — 진짜 SpotLink iPhone도 일시적 타임아웃을
          // 끊임없이 만난다(CBError 6). 10분간 blocklist하지는 말되, 짧은
          // backoff를 걸어, 붐비는 방이 이 같은 기기를 12초마다 다시 dial해
          // status-133 폭풍으로 진짜 피어를 굶기지 못하게 한다.
          _probeBackoff[key] = DateTime.now();
          _log(
              'BLE probe connect failed $key: $err (backoff ${MeshTransport._probeFailBackoff.inSeconds}s)');
        }
      } else {
        _log('BLE connect failed $key: $err');
        if (_isUnknownIdentifier(err)) {
          // Darwin이 illegalArgument를 throw함: 식별자가 시스템의 peripheral
          // 캐시에 없다(rotate된/잊힌 주소 — 재시작한 Android 피어의 전형적
          // 사례). 살아 있는 scan이 피어를 다시 발견하기 전까지는 어떤 재시도도
          // 결코 성공할 수 없으므로, 걸려 있는 재시도와, 실행 때마다 그것을
          // 되살리는 영속화된 식별자를 함께 버린다.
          _reconnectAttempts.remove(key);
          if (_knownPeers.remove(key)) {
            knownPeersSave?.call(_knownPeers.toList());
            _log('BLE forgetting dead peer identifier $key');
          }
        } else {
          // 일시적 실패는 일어난다(피어가 자기 GATT 데이터베이스를 다시
          // publish 중, 무선 경합). backoff를 두고 계속 시도한다 — 조용히
          // 침묵하는 SpotLink 피어는 iOS에서 걸려 있는 reconnect를 유지할 만한
          // 가치가 있다.
          _scheduleReconnect(peripheral, key);
        }
      }
    } finally {
      _connecting.remove(key);
      _pendingKeys.remove(key);
      _pendingPeripherals.remove(key);
      _pendingTimers.remove(key)?.cancel(); // 해소됨 → watchdog가 더는 필요 없음
      if (probe) {
        _activeProbes.remove(key);
        // 타임아웃된 probe(깨끗한 disconnect가 아님)는 pending connectGatt를
        // 남긴다 — GATT 클라이언트 슬롯이 풀리도록 강제로 해제한다.
        if (MeshTransport.releasesProbeConnection(linked: linked)) {
          unawaited(
              _central.disconnect(peripheral).then((_) {}, onError: (_) {}));
        }
      }
    }
  }

  /// Darwin의 connect()는 peripheral 식별자가 시스템 캐시에 알려져 있지 않을 때
  /// `illegalArgument`를 throw한다 — 그 식별자에 대한 영구적 실패이지, 일시적
  /// 무선 오류가 아니다. (이 파일이 flutter/services 의존성을 갖지 않도록
  /// 문자열로 매칭한다.)
  bool _isUnknownIdentifier(Object err) =>
      profile.isUnknownIdentifierError(err);

  PeerId? _shortIdFromAdvertisement(Advertisement adv) {
    for (final m in adv.manufacturerSpecificData) {
      if (m.id == BleConstants.manufacturerId &&
          m.data.length >= PeerId.wireLength) {
        return PeerId(Uint8List.fromList(m.data));
      }
    }
    return null;
  }
}
