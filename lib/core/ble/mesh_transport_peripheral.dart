part of 'mesh_transport.dart';

/// [MeshTransport]의 GATT Peripheral 서비스 등록, 광고 시작/슬롯 양보,
/// 원격 Central 요청/구독 처리 및 패킷 분할 송신(`_sendTo`) 책임.
extension _MeshTransportPeripheral on MeshTransport {
  Future<void> _sendTo(MeshLink link, Uint8List frameBytes) async {
    // 너무 작거나 아직 협상 중인 MTU가 잘못된 split을 만들지 못하게 한다.
    final size = link.maxPacketSize < BleConstants.minUsablePacketSize
        ? BleConstants.minUsablePacketSize
        : link.maxPacketSize;
    final List<Uint8List> packets;
    try {
      packets = L2Framing.split(frameBytes, size);
    } catch (_) {
      return; // 이 링크에서 framing하기엔 프레임이 너무 큼
    }
    await link.enqueueOp(() async {
      if (_disposed || !_links.containsKey(link.id)) return;
      // withResponse flush는 '버스트'(여러 패킷으로 쪼개지는 파일 청크)에서만
      // 필요하다: iOS가 큐가 차면 write-without-response를 조용히 버리므로,
      // ATT 왕복으로 큐를 비워줘야 청크가 증발하지 않는다. 반면 단일 패킷
      // 제어 프레임(ANNOUNCE·ACK·짧은 텍스트)은 버스트가 아니므로 flush가
      // 불필요하다 — 그런데도 6번째마다 withResponse를 강제하면, 삼성 One UI의
      // 백그라운드 GATT 서버가 그 ATT 응답을 10초 안에 못 줘 링크 전체가
      // 절단되고 재연결 플랩 루프에 빠진다(2026-07-24 12:38~ 삼성 최신폰:
      // C링크 39회 write-timeout 절단, ANNOUNCE 교환 불가 → "못 찾음").
      // 그래서 단일 패킷 프레임은 언제나 withoutResponse로 보낸다.
      final isBurst = packets.length > 1;
      for (final p in packets) {
        if (_disposed || !_links.containsKey(link.id)) return;
        try {
          if (link.role == LinkRole.central) {
            // 버스트일 때만 몇 패킷마다 response write로 큐를 비운다.
            final bool flush;
            if (isBurst) {
              link.txBurst++;
              flush = link.txBurst >= 6;
              if (flush) link.txBurst = 0;
            } else {
              flush = false;
            }
            await _central
                .writeCharacteristic(
                  link.peripheral!,
                  link.remoteTx!,
                  value: p,
                  type: flush
                      ? GATTCharacteristicWriteType.withResponse
                      : GATTCharacteristicWriteType.withoutResponse,
                )
                .timeout(const Duration(seconds: 10));
          } else {
            if (!link.centralSubscribed || _localRx == null) {
              // 원격 central이 RX 구독(CCCD write)보다 TX write를 수 ms 먼저
              // 보내거나, GATT 서비스 재발행 직후 재구독 전에 패킷을 흘리는
              // 경우(iOS↔Android 및 iOS간 레이스에서 빈번히 발생):
              // 아직 수신(rx)이 활발히 들어오고 있는 신생/수신 전용 P-링크를
              // 즉시 _tearDown하면 link.reassembler까지 파괴되어 다중 패킷
              // 프레임(ANNOUNCE, 메시지)이 영구히 조립 실패한다(2026-10-18
              // gold_ble.log에서 56ms 간격 P-링크 연속 파괴 확인).
              // 따라서 최근 수신 활동(15초 이내)이 있는 동안은 부기와
              // reassembler를 보존하고 송신만 건너뛴다(상대 구독이 도착하거나
              // 우리 쪽 C-링크로 응답이 나간다).
              final recentRx = link.rxPackets > 0 &&
                  DateTime.now().difference(link.lastActivity) <
                      const Duration(seconds: 15);
              if (recentRx) {
                _log('BLE send deferred on ${link.id} '
                    '(central not yet subscribed, rx active)');
                return;
              }
              // 절대 조용히 버리지 않는다: 이 링크로는 내보낼 수 없다는 뜻이고,
              // 그대로 두면 "연결됨"으로 보이면서 우리 메시지만 사라진다.
              // 부기를 지워 상대가 재연결·재구독하게 만든다.
              _log('BLE send skipped on ${link.id} '
                  '(central not subscribed) — dropping half-open link');
              _tearDown(link.id);
              return;
            }
            await _peripheral
                .notifyCharacteristic(
                  link.central!,
                  _localRx!,
                  value: p,
                )
                .timeout(const Duration(seconds: 10));
          }
        } catch (e) {
          // write 실패/타임아웃은 링크가 죽었다는 뜻이다. 부기 제거에 그치지
          // 않고 물리 절단+재연결 재장전까지 — 죽은 ACL을 남겨두면 상대는
          // 광고를 안 하고(자기 쪽 링크가 살아있다고 믿음) 우리는 스캔만
          // 도는 3분짜리 상호 교착이 된다(2026-07-19 09:46 관찰).
          _log('BLE send failed on ${link.id} ($e) — cutting');
          _cutLink(link);
          return;
        }
      }
    });
  }

  Future<void> _setupPeripheral() async {
    final rx = GATTCharacteristic.mutable(
      uuid: BleConstants.rxCharacteristicUuid,
      properties: [GATTCharacteristicProperty.notify],
      permissions: [GATTCharacteristicPermission.read],
      descriptors: [],
    );
    final tx = GATTCharacteristic.mutable(
      uuid: BleConstants.txCharacteristicUuid,
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );
    final info = GATTCharacteristic.immutable(
      uuid: BleConstants.infoCharacteristicUuid,
      value: infoValue,
      descriptors: [],
    );
    // 본딩 유도 특성: 암호화 읽기 전용. 미본딩 central이 읽으면 OS가
    // 페어링을 개시하고(iOS: readEncryptionRequired, Android: 포크 패치로
    // PERMISSION_READ_ENCRYPTED), 본딩 후에는 조용히 성공한다. 값은 무의미 —
    // 읽기가 성공했다는 사실 자체가 "링크가 암호화됐다"의 증명이다.
    final bond = GATTCharacteristic.mutable(
      uuid: BleConstants.bondCharacteristicUuid,
      properties: [GATTCharacteristicProperty.read],
      permissions: [GATTCharacteristicPermission.readEncrypted],
      descriptors: [],
    );
    final service = GATTService(
      uuid: BleConstants.serviceUuid,
      isPrimary: true,
      includedServices: [],
      characteristics: [rx, tx, info, bond],
    );
    _localRx = rx;
    try {
      await _peripheral.removeAllServices();
    } catch (_) {}
    try {
      await _peripheral.addService(service);
      _servicePublished = true;
      _log('BLE service published');
    } catch (e) {
      _servicePublished = false;
      _log('BLE addService failed: $e');
    }
  }

  /// 어느 스택에서든 나오는 "Already advertising" — advertisement이 살아
  /// 있다는 뜻이고, 그것이 바로 재확립(re-assert)이 원하는 것이므로; 성공으로
  /// 취급한다.
  /// (Darwin에서는 "Advertising has already started"; Android에서는 error code 3 =
  /// ADVERTISE_FAILED_ALREADY_STARTED.)
  static bool _isAlreadyAdvertising(Object e) {
    final s = e.toString();
    return s.contains('already started') || s.contains('error code: 3');
  }

  Future<void> _startAdvertising({bool restart = false}) async {
    // 재시작은 오직 명시적 요청일 때만(포그라운드 wake, GATT republish).
    // Android에서 stop+start는 무해한 refresh가 아니다: start할 때마다 새
    // 랜덤 주소(RPA)를 할당하고, 링크 없음 self-heal은 15초마다 재확립한다 —
    // 매번 재시작하면 이 노드가 *백그라운드* 상태의 iPhone이 dial을 끝낼 수
    // 있는 것보다 더 빠르게 주소를 갈아치우게 되고(백그라운드
    // discovery→connect는 매번 15초 경쟁에서 진다), 그래서 idle 상태의 두 폰은
    // 한쪽이 포그라운드로 오기 전까지 결코 다시 링크할 수 없었다. 기본 경로는
    // 살아 있는 advertisement을 건드리지 않고 둔다.
    if (restart) {
      try {
        await _peripheral.stopAdvertising();
        _advertising = false;
      } catch (_) {}
    }
    // NAME + service UUID만 advertise한다. 예전에는 short id도 manufacturer
    // data에 넣어 보냈지만, 128비트 service UUID(18B) + 이름(4B) + flags(3B)만
    // 으로 이미 레거시 31바이트 advertisement을 거의 다 채우기 때문에,
    // manufacturer data 12B가 더해지자 Android가 한계를 넘겨 모든
    // startAdvertising이 DATA_TOO_LARGE(error code 1)로 실패했다 — 그러면
    // 노드는 어차피 정확히 이 패킷으로 fallback했다. 피어는 링크가 올라오는
    // 순간 보내는 ANNOUNCE에서 우리 short id를 알게 되므로 잃는 것은 없다;
    // service UUID를 남기는 이유는 iOS 피어의 백그라운드 scan이 그것으로
    // 필터링되기 때문이며(우리를 discover하는 유일한 수단), 이름은 iOS
    // 포그라운드 discovery를 이끈다. (Darwin은 manufacturer-data advertising을
    // 지원한 적이 없다.)
    if (await _tryAdvertise()) return;
    // 재시도할 가치가 있는 실패는 **슬롯 경합(code 2)** 하나뿐이다: 웨이크
    // 토치가 단일 광고 슬롯을 쥐고 있는 Samsung 사례([advertiseSlotYield]).
    // 토치를 양보시키고 한 번 더 건다 — 발견되지 못하는 노드는 아무것도 할 수
    // 없으므로 메시 광고가 토치를 이긴다. 다른 코드(데이터 초과·미지원 등)는
    // 재시도해도 같은 결과라 로그로만 남긴다.
    if (_lastAdvertiseError == MeshTransport._advertiseTooManyAdvertisers &&
        advertiseSlotYield != null) {
      _log('BLE advertise slot contended (code 2) — yielding wake torch');
      try {
        await advertiseSlotYield!();
      } catch (_) {}
      // stopAdvertising은 바인더 호출이 돌아온 뒤에도 컨트롤러가 슬롯을 실제로
      // 반납하기까지 잠깐 걸린다 — 곧바로 다시 걸면 같은 code 2를 맞는다.
      // 놓쳐도 다음 self-heal 틱(15초)이 토치가 내려간 상태에서 다시 건다.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (await _tryAdvertise()) {
        _log('BLE advertising recovered after torch yield');
      }
    }
  }

  /// 광고를 한 번 시도한다. 성공(또는 이미 광고 중)이면 true.
  Future<bool> _tryAdvertise() async {
    final named = _advertiseWithName;
    try {
      var op = _peripheral.startAdvertising(Advertisement(
        name: named ? BleConstants.advertisedName : null,
        serviceUUIDs: [BleConstants.serviceUuid],
      ));
      if (profile.advertiseNameOptional) {
        op = op.timeout(MeshTransport._advertiseStartTimeout);
      }
      await op;
      _advertising = true;
      _lastAdvertiseError = null;
      _log('BLE advertising started '
          '(${named ? 'name + service uuid' : 'service uuid only'})');
      return true;
    } catch (e) {
      if (_isAlreadyAdvertising(e)) {
        _advertising = true; // 이미 올라와 있다 = 목표 달성
        _lastAdvertiseError = null;
        return true;
      }
      _advertising = false;
      _lastAdvertiseError = MeshTransport.advertiseErrorCode(e);
      _log('BLE startAdvertising failed '
          '(code=${_lastAdvertiseError ?? '?'}): $e');
      if (named &&
          MeshTransport.dropsAdvertiseName(e,
              nameOptional: profile.advertiseNameOptional)) {
        _advertiseWithName = false;
        _log('BLE advertise name step failed — '
            'falling back to service uuid only');
        return _tryAdvertise();
      }
      return false;
    }
  }

  void _wirePeripheral() {
    _subs.add(_peripheral.characteristicReadRequested.listen((e) async {
      // mutable 특성의 read 요청. BOND에 요청이 도달했다는 것 자체가 OS가
      // 이미 암호화(=페어링)를 마쳤다는 뜻이므로 상수로 답한다. INFO는
      // immutable이라 대개 스택이 캐시로 응답하지만, 이벤트를 올리는
      // 플랫폼을 위해 같은 값을 준다.
      try {
        if (e.characteristic.uuid == BleConstants.bondCharacteristicUuid) {
          await _peripheral.respondReadRequestWithValue(e.request,
              value: Uint8List.fromList('SLB1'.codeUnits));
        } else if (e.characteristic.uuid ==
            BleConstants.infoCharacteristicUuid) {
          await _peripheral.respondReadRequestWithValue(e.request,
              value: infoValue);
        } else {
          await _peripheral.respondReadRequestWithError(e.request,
              error: GATTError.readNotPermitted);
        }
      } catch (_) {}
    }));

    _subs.add(_peripheral.characteristicWriteRequested.listen((e) async {
      // 원격 central이 우리의 TX characteristic에 패킷을 write했다.
      if (e.characteristic.uuid != BleConstants.txCharacteristicUuid) {
        try {
          await _peripheral.respondWriteRequestWithError(e.request,
              error: GATTError.writeNotPermitted);
        } catch (_) {}
        return;
      }
      try {
        await _peripheral.respondWriteRequest(e.request);
      } catch (_) {}
      final link = _peripheralLinkFor(e.central);
      _ingest(link, e.request.value);
    }));

    _subs.add(_peripheral.characteristicNotifyStateChanged.listen((e) async {
      if (e.characteristic.uuid != BleConstants.rxCharacteristicUuid) return;
      final key = e.central.uuid.toString();
      final id = _peripheralLinkId(e.central);
      if (!e.state) {
        // 구독 해제(또는 iOS에서 원격 central 연결 종료): 새 P-링크를 만들지
        // 않고 기존 링크만 즉시 정리한다. 예전에는 e.state == false에서도
        // _peripheralLinkFor를 호출해 centralSubscribed=false인 반쪽 좀비
        // 링크를 새로 만들고 _emitUp까지 쏘아 올렸다.
        _subscribedCentrals.remove(key);
        final existing = _links[id];
        if (existing != null) {
          existing.centralSubscribed = false;
          _tearDown(id);
        }
        return;
      }
      // 구독 성립: _peripheralLinkFor보다 먼저 _subscribedCentrals에 등록해
      // 새로 만들어지는 링크가 처음부터 centralSubscribed=true를 갖게 한다.
      _subscribedCentrals.add(key);
      final existing = _links[id];
      final wasUnsubscribed = existing != null && !existing.centralSubscribed;
      var resolvedMaxPacket = BleConstants.defaultMaxPacketSize;
      // notification 하나당 얼마나 밀어넣을 수 있는지 먼저 알아내, 초기
      // ANNOUNCE/HAVE부터 협상된 MTU로 나가게 한다.
      try {
        final maxNotify =
            await _peripheral.getMaximumNotifyLength(e.central);
        if (maxNotify > BleConstants.minUsablePacketSize) {
          resolvedMaxPacket =
              maxNotify.clamp(BleConstants.minUsablePacketSize, 512);
        }
      } catch (_) {
        resolvedMaxPacket = BleConstants.targetMaxPacketSize;
      }
      if (_disposed || !_started || !_subscribedCentrals.contains(key)) {
        return;
      }
      final link = _peripheralLinkFor(
        e.central,
        initialMaxPacketSize: resolvedMaxPacket,
      );
      link.centralSubscribed = true;
      if (resolvedMaxPacket > link.maxPacketSize) {
        link.maxPacketSize = resolvedMaxPacket;
      }
      // TX write가 구독보다 수 ms 먼저 도착해 centralSubscribed=false로
      // 생성됐던 링크라면, 구독이 성립된 지금 다시 link-up을 알려 ANNOUNCE와
      // 대기 중인 메시지가 즉시 전송되게 한다.
      if (wasUnsubscribed) {
        _emitUp(link);
      }
    }));

    // Android 전용: central disconnect를 추적해 구독 상태와 링크를 정리한다.
    try {
      _subs.add(_peripheral.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected) {
          _subscribedCentrals.remove(e.central.uuid.toString());
          _tearDown(_peripheralLinkId(e.central));
        }
      }));
    } on UnsupportedError {
      // iOS/macOS: peripheral 연결 콜백이 없다; 대신 centralDidUnsubscribe
      // (characteristicNotifyStateChanged(false))와 write 실패로 정리된다.
    }
  }

  MeshLink _peripheralLinkFor(Central central, {int? initialMaxPacketSize}) {
    final id = _peripheralLinkId(central);
    final existing = _links[id];
    if (existing != null) return existing;
    // 이 central로부터의 첫 접촉(subscribe 또는 write). link-up을 내보내
    // mesh가 자기 ANNOUNCE/HAVE를 돌려보내게 하고 — 결정적으로 — [_links]가
    // 비어 있지 않게 만들어, 링크 없음 self-heal이 GATT service를 republish하며
    // 바로 이 연결을 허물어버리는 것을 막는다("central이 붙어 있는데도 우리는
    // 링크가 없다고 여기는" 루프로, iPhone↔Android를 단방향으로 만들었던
    // 원인이다).
    final link = MeshLink(
      id: id,
      role: LinkRole.peripheral,
      central: central,
      maxPacketSize: initialMaxPacketSize ?? BleConstants.defaultMaxPacketSize,
    )
      // 이 central이 이미 구독 중이라면 그 사실을 물려받는다 — 링크 객체가
      // 교체돼도 상대는 재구독하지 않는다([_subscribedCentrals] 참고).
      ..centralSubscribed =
          _subscribedCentrals.contains(central.uuid.toString());
    _links[id] = link;
    _emitUp(link);
    return link;
  }

  String _peripheralLinkId(Central central) => 'P:${central.uuid}';
}
