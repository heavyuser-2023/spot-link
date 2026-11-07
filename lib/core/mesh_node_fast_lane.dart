part of 'mesh_node.dart';

/// [MeshNode]의 Wi-Fi FastLane (Multipeer / Wi-Fi Direct / LAN 소켓) 협상,
/// 세그먼트 스트리밍, 배치 연속 전송 및 송신자-호스트 다이얼 처리 책임.
extension _MeshNodeFastLane on MeshNode {
  /// [turnTimeout]은 "차례 대기"에만 적용된다(자기 body 실행 시간은 무제한 —
  /// 큰 파일 스트리밍을 중간에 포기시키면 안 된다). 앞 body가 어떤 이유로든
  /// 영영 안 끝나면(네이티브 응답 유실 등) 시간이 찬 파일은 차례를 포기하고
  /// [onTurnTimeout]의 값을 반환하며, 자기 gate를 즉시 열어 뒤 파일들도
  /// 굶지 않게 한다 — 락 체인 정지가 더는 전체 전송 정지가 되지 않는다
  /// (2026-07-17 22:22 관찰: 앞 파일 완료 직후 서스펜드와 겹치며 체인이 굳어
  /// 4번째 파일이 영구 대기).
  Future<T> _withFastLaneLock<T>(
    Future<T> Function() body, {
    Duration? turnTimeout,
    T Function()? onTurnTimeout,
  }) {
    final gate = Completer<void>();
    final prev = _fastLaneChain;
    _fastLaneChain = gate.future;
    // 앞 사람의 에러가 뒤 사람의 body 실행을 건너뛰게 두면 안 된다 —
    // 대기열 전체가 조용히 굶는다.
    var timedOut = false;
    Future<void> waited = prev.catchError((_) {});
    if (turnTimeout != null) {
      waited = waited.timeout(turnTimeout, onTimeout: () {
        timedOut = true;
      });
    }
    return waited.then((_) {
      if (timedOut) {
        // 차례 포기: 체인은 계속 흘려보내고, 늦게 차례가 와도 재실행 없음
        // (waited는 이미 완료됐으므로 이 then은 다시 돌지 않는다).
        if (!gate.isCompleted) gate.complete();
        return Future<T>.value(onTurnTimeout!());
      }
      return body();
    }).whenComplete(() {
      if (!gate.isCompleted) gate.complete();
    });
  }

  /// 전송 측 fast path: BLE로 offer하고, ACCEPT를 기다리고, Wi-Fi로 연결한 뒤,
  /// 전체 암호문을 스트리밍한다. 피어가 바이트를 확인한 경우에만 true를 반환한다.
  /// 호출자는 [_withFastLaneLock]으로 감싸 동시 Multipeer 세션을 막아야 한다.
  Future<bool> _trySendFast(
    FileSender sender,
    PeerId dst,
    Uint8List kex,
  ) async {
    final tid = sender.meta.transferIdHex;
    // 대기열에서 기다리는 사이 취소/타임아웃됐을 수 있다 — 죽은 전송이
    // fast lane을 점유하지 않게 한다.
    if (!_senders.containsKey(tid)) return false;
    if (_batchDelivered.remove(tid)) return true; // 앞 파일의 세션에 편승 완료
    // 이 파일은 이제 락 소유자다 — 배치 후보 목록에서 자신을 뺀다.
    _fastBatchCandidates[dst.hex]?.remove(tid);
    bool cooled(FastLaneKind k) {
      final until = _fastLaneCooldownUntil['${dst.hex}/${k.name}'];
      return until != null && DateTime.now().isBefore(until);
    }

    // 협상 → 연결. 선택된 수단의 연결이 실패하면 그 수단을 제외하고 한 번 더
    // 오퍼한다 — 예: multipeer가 라디오 혼잡으로 죽어도 같은 Wi-Fi의
    // lanSocket이 파일을 살린다. 수신 측은 새 오퍼 마스크에서 자기 대기 수단이
    // 빠진 것을 보고 남은 교집합으로 재협상한다([_handleFastOffer]).
    final excluded = <FastLaneKind>{};
    FastLaneSession? session;
    _FastAccept? accept;
    for (var attempt = 0; attempt < 2 && session == null; attempt++) {
      final caps = fastLane!.capabilities
          .difference(excluded)
          .where((k) => !cooled(k))
          .toSet();
      if (caps.isEmpty) {
        bleLogSink?.call('FT fast skip (all kinds cooling): '
            '${sender.meta.name}');
        break;
      }
      // Offer 페이로드: transferId(16) + capsBitmask(1) + flags(1).
      // flags bit0: lanSocket tid 프리앰블 지원 — 구버전 수신자는 여분
      // 바이트를 무시한다.
      var bitmask = 0;
      for (final k in caps) {
        bitmask |= 1 << k.code;
      }
      final offerPlain = Uint8List(18)
        ..setRange(0, 16, sender.meta.transferId)
        ..[16] = bitmask
        ..[17] = 0x01;
      final waiter = _fastAcceptWaiters[tid] = Completer<_FastAccept>();
      await _dispatch(
        router.originate(
          type: FrameType.fileFastOffer,
          dst: dst,
          payload: await crypto.encrypt(offerPlain, kex),
          flags: FrameFlags.encrypted,
        ),
        persist: false,
      );

      // 협상 창: OFFER/ACCEPT 왕복은 BLE(때로 멀티홉)를 타므로 홉 수에
      // 비례해 늘린다 — 직접 5초, 홉당 +2초, 상한 11초. 고정 5초는 2홉
      // 혼잡 상황에서 ACCEPT가 오는 중인데도 BLE로 포기하게 만들었다.
      final hops = _lastHops[dst.hex] ?? 1;
      final window = MeshNode.fastLaneNegotiateWindow +
          Duration(seconds: 2 * (hops - 1).clamp(0, 3));
      try {
        accept = await waiter.future.timeout(window);
      } catch (_) {
        _fastAcceptWaiters.remove(tid);
        return false; // 제때 ACCEPT 없음 → BLE
      } finally {
        _fastAcceptWaiters.remove(tid);
      }

      bleLogSink?.call('FT fast accept: ${accept.offer.kind.name}');
      session = accept.offer.kind == FastLaneKind.wifiDirectHosted
          ? await _hostAndAwaitDial(sender, dst, kex)
          : await fastLane!.connect(tid, accept.offer);
      if (session == null) {
        excluded.add(accept.offer.kind);
        // 실패한 그 수단만 식힌다 — 다른 수단·다른 파일의 시도는 막지 않는다.
        _fastLaneCooldownUntil['${dst.hex}/${accept.offer.kind.name}'] =
            DateTime.now().add(const Duration(seconds: 15));
        final remaining = fastLane!.capabilities.difference(excluded);
        bleLogSink?.call('FT fast connect null (${accept.offer.kind.name})'
            '${remaining.isEmpty ? ' → BLE' : ' → 남은 수단으로 재오퍼'}');
      }
    }
    if (session == null || accept == null) {
      return false;
    }
    final acc = accept; // non-null 프로모션
    try {
      _fastLaneCooldownUntil
          .remove('${dst.hex}/${acc.offer.kind.name}'); // 성공 → 쿨다운 해제
      _fastActive.add(tid);
      // idle 워치독 급식은 [_deliverFile]의 feeder가 대기열~스트림 전 구간을
      // 덮는다.
      bleLogSink?.call('FT fast connected: ${acc.offer.kind.name}');
      _events.add(TransferLane(tid, 'wifi'));
      if (acc.wantsPreamble) {
        // 수신자의 lanSocket 리스너가 이 16바이트로 우리를 식별한다.
        await session.add(sender.meta.transferId);
      }
      if (acc.segmented && !MeshNode.debugForceLegacyFastLane) {
        // 세그먼트 스트리밍: [매직 u32][segLen u32][seg GCM]…[0 u32].
        // RAM에는 세그먼트 하나(기본 4MB)의 평문+암호문만 머문다 — 예전의
        // 파일 전체 GCM은 대용량에서 파일 크기 2배의 순간 점유로 jetsam을
        // 불렀다. 세그먼트별 암호문은 순서 조작 시 조립 결과가 달라질 뿐이고,
        // 무결성은 finalize의 매니페스트 SHA-256이 파일 전체로 검증한다.
        await session.add(_u32be(MeshNode.fastLaneMagicSegmented));
        final size = sender.meta.fileSize;
        var lastPct = 0;
        for (var off = 0; off < size; off += MeshNode.fastLaneSegmentBytes) {
          final len = min(MeshNode.fastLaneSegmentBytes, size - off);
          final cipher =
              await crypto.encrypt(await sender.readRange(off, len), kex);
          await session.add(_u32be(cipher.length));
          // add를 기다리는 것이 곧 백프레셔다 — 전송 계층에 실제로 넘어간
          // 뒤에야 다음 세그먼트를 디스크에서 읽는다. 그 덕에 송신 진행률도
          // 실제 전송 속도를 따라간다(예전엔 0%→100% 점프).
          await session.add(cipher);
          final sentBytes = min(off + MeshNode.fastLaneSegmentBytes, size);
          final pct = (sentBytes * 100) ~/ size;
          if (pct >= lastPct + 5 && sentBytes < size) {
            lastPct = pct;
            _events.add(FileProgress(tid, sentBytes / size, true));
          }
        }
        await session.add(_u32be(0)); // 종료 마커
        if (acc.batch) {
          // 같은 상대에게 줄 서 있는 파일들을 이 세션으로 이어 보낸다 —
          // 연속 협상이 사라져 multipeer 잔상 광고 실패의 근원이 차단된다.
          await _streamBatchTail(session, dst, kex);
        }
      } else {
        // 레거시 수신자(ACCEPT에 flags 없음): 파일 전체를 하나의 암호화된
        // 길이 접두 blob으로 보낸다 — 구버전 호환 경로.
        final cipher = await crypto.encrypt(await sender.readAll(), kex);
        await session.add(_u32be(cipher.length));
        await session.add(cipher);
      }
      await session.finishSending();
      // 전송 계층이 아직 큐에 쌓인 바이트를 내보내는 중일 수 있다 — Multipeer는
      // .reliable 전송을 비동기로 큐잉하므로, 지금 연결을 끊으면 아직 라디오를
      // 떠나지 않은 바이트가 유실된다. 수신 측은 파일을 다 조립하면 자기 쪽을
      // 닫으므로, 우리 쪽을 닫기 전에 그 EOF를 기다린다 — 또는 완료 ACK를
      // 기다린다(권위 있는 신호; MC의 연결 해제 통지는 두 세션이 같은 피어 쌍을
      // 공유할 때 ~30초까지 지연될 수 있다). 예산은 크기에 비례해 늘어나므로
      // (하한 ~512KB/s) 큰 파일이 중간에 끊기지 않는다.
      try {
        await Future.any([
          session.incoming.drain<void>(),
          _senderRetired(tid),
        ]).timeout(
            Duration(seconds: 30 + sender.meta.fileSize ~/ (512 * 1024)));
      } catch (_) {}
      bleLogSink?.call('FT fast send done: ${sender.meta.name} '
          '(${sender.meta.fileSize}B via ${acc.offer.kind.name})');
      // 수신 측의 완료 ACK를 기다린다(BLE로 도착) — 끝내 오지 않으면 감시
      // 타이머가 이미 전송을 실패로 처리한다.
      _events.add(FileProgress(tid, 1.0, true));
      return true;
    } catch (e) {
      bleLogSink?.call('FT fast send error: $e');
      return false;
    } finally {
      _fastActive.remove(tid);
      await session.close();
      // 락 체인 정지 진단용 경계 마커: 이 줄이 없고 'send done'만 있으면
      // close 경로 어딘가에 매달린 것이다.
      bleLogSink?.call('FT fast session closed: ${sender.meta.name}');
    }
  }

  /// 같은 상대에게 fast-lane 차례를 기다리는 세그먼트-지원 파일들을 방금 쓴
  /// 세션으로 이어 스트리밍한다. 각 파일: [연속 매직][tid 16B][세그먼트
  /// 스트림]. 개별 완료 ACK는 기존대로 BLE로 도착해 각 sender를 은퇴시킨다.
  /// 여기서의 실패는 앞서 성공한 파일들에 영향을 주지 않는다 — 남은 파일은
  /// 각자의 차례에서 새로 협상한다.
  Future<void> _streamBatchTail(
      FastLaneSession session, PeerId dst, Uint8List kex) async {
    while (true) {
      final list = _fastBatchCandidates[dst.hex];
      if (list == null || list.isEmpty) return;
      final tid = list.removeAt(0);
      final sender = _senders[tid];
      if (sender == null || !_fastQueued.contains(tid)) continue; // 취소됨
      bleLogSink?.call('FT batch: ${sender.meta.name} on same session');
      _fastActive.add(tid);
      try {
        _events.add(TransferLane(tid, 'wifi'));
        await session.add(_u32be(MeshNode.fastLaneMagicNext));
        await session.add(sender.meta.transferId);
        await session.add(_u32be(MeshNode.fastLaneMagicSegmented));
        final size = sender.meta.fileSize;
        var lastPct = 0;
        for (var off = 0; off < size; off += MeshNode.fastLaneSegmentBytes) {
          final len = min(MeshNode.fastLaneSegmentBytes, size - off);
          final cipher =
              await crypto.encrypt(await sender.readRange(off, len), kex);
          await session.add(_u32be(cipher.length));
          await session.add(cipher);
          final sentBytes = min(off + MeshNode.fastLaneSegmentBytes, size);
          final pct = (sentBytes * 100) ~/ size;
          if (pct >= lastPct + 5 && sentBytes < size) {
            lastPct = pct;
            _events.add(FileProgress(tid, sentBytes / size, true));
          }
        }
        await session.add(_u32be(0));
        _batchDelivered.add(tid);
        bleLogSink?.call('FT batch send done: ${sender.meta.name} '
            '(${sender.meta.fileSize}B)');
        _events.add(FileProgress(tid, 1.0, true));
      } catch (e) {
        // 세션이 중간에 죽음: 이 파일과 나머지는 각자의 차례에서 재협상한다.
        bleLogSink?.call('FT batch error: $e — remaining files renegotiate');
        return;
      } finally {
        _fastActive.remove(tid);
      }
    }
  }

  /// 값이 클수록 = 선호됨. multipeer(iOS끼리, 셋업 최속) > Wi-Fi Direct/
  /// Aware(그룹 생성+접속) > 송신자-호스트 역방향(HOSTINFO 한 라운드 추가)
  /// > LAN 소켓(공유 AP 필요하지만 가장 값쌈 — 단 기내엔 AP가 없다).
  static int _lanePreference(FastLaneKind k) => switch (k) {
        FastLaneKind.multipeer => 4,
        FastLaneKind.wifiAware || FastLaneKind.wifiDirect => 3,
        FastLaneKind.wifiDirectHosted => 2,
        FastLaneKind.lanSocket => 1,
      };

  static Uint8List _u32be(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.big);

  Future<void> _handleFastOffer(PeerId from, Uint8List payload) async {
    if (fastLane == null || fastLane!.inboundCapabilities.isEmpty) {
      return; // → BLE
    }
    if (payload.length < 17) return;
    final transferId = Uint8List.fromList(payload.sublist(0, 16));
    final tid = MsgId.hex(transferId);
    // 실제로 이 전송을 기다리고 있고 아직 끝나지 않은 경우에만 동작한다.
    final receiver = _receivers[tid];
    if (receiver == null || _completedTransfers.contains(tid)) return;
    if (_fastActive.contains(tid)) {
      // 이미 협상/수신 중. 단, 송신자가 연결 실패 후 그 수단을 빼고 다시
      // 오퍼한 경우라면([_trySendFast]의 재오퍼) 남은 교집합으로 재협상한다.
      // 실제 바이트 수신 중(pending 없음)이거나, 대기 중인 수단이 여전히
      // 마스크에 있으면(리스너/광고가 살아 있으니) 무시한다.
      final pending = _pendingInboundKind[tid];
      if (pending == null ||
          payload.length < 17 ||
          (payload[16] & (1 << pending.code)) != 0) {
        return;
      }
      bleLogSink
          ?.call('FT fast re-offer without ${pending.name} — renegotiate');
      _fastActive.remove(tid);
      _pendingInboundKind.remove(tid);
      // 버려진 리스너/광고는 각자의 타임아웃으로 정리된다.
    }

    // 수신 측은 네트워크 대기(connect)를 앱 전역 락으로 감싸지 않는다 —
    // 송신 측이 같은 락을 잡고 ACCEPT를 기다리면 교착이 난다. 송신 직렬화 +
    // 네이티브 single-flight로 동시 advertiser 폭주를 막는다.
    //
    // capabilities 교집합을 선호도 순으로 시도: 네이티브 P2P 우선, 실패 시
    // 같은 Wi-Fi의 LAN 소켓.
    final senderMask = payload[16];
    // OFFER flags(bit0: tid 프리앰블 지원) — 구버전 송신자의 오퍼에는 없다.
    final senderFlags = payload.length >= 18 ? payload[17] : 0;
    // 수신 후보 = 우리가 '수신 호스트'가 될 수 있는 수단 ∩ 송신자 마스크.
    // 송신/수신 능력은 비대칭일 수 있다(예: iOS는 wifiDirect 송신만 가능).
    final candidates = fastLane!.inboundCapabilities
        .where((k) => (senderMask & (1 << k.code)) != 0)
        .toList()
      ..sort((a, b) => _lanePreference(b).compareTo(_lanePreference(a)));
    if (candidates.isEmpty) return; // 공유 전송 수단 없음 → BLE

    final kex = _knownKex[from.hex];
    if (kex == null) return;

    FastLaneInbound? inbound;
    FastLaneKind? chosen;
    var armedPreamble = false;
    for (final k in candidates) {
      // 송신자가 지원할 때만 lanSocket 리스너에 tid 프리앰블 검증을 무장한다
      // (구버전 송신자는 프리앰블을 안 보내므로 요구하면 안 된다).
      final wantPre =
          (senderFlags & 0x01) != 0 && k == FastLaneKind.lanSocket;
      try {
        inbound = await fastLane!.prepareInbound(tid, k, tidPreamble: wantPre);
      } catch (_) {
        inbound = null;
      }
      if (inbound != null) {
        chosen = k;
        armedPreamble = wantPre;
        break;
      }
      bleLogSink?.call('FT fast prepareInbound failed: ${k.name}');
    }
    if (inbound == null || chosen == null) return; // 전부 실패 → BLE

    bleLogSink?.call('FT fast offer accepted: ${chosen.name} (tid $tid)');

    _fastActive.add(tid);
    _pendingInboundKind[tid] = chosen;
    // ACCEPT: transferId(16) + chosenKind(1) + offerLen(2) + offerBlob
    //         + flags(1, bit0: 세그먼트 스트리밍 수신 지원,
    //                 bit1: tid 프리앰블 검증 무장 — 첫 16바이트 필수).
    // 구버전 송신자는 blob 뒤의 여분 바이트를 무시하고 레거시 형식으로 보낸다.
    final blob = inbound.offer.blob;
    final accept = Uint8List(16 + 1 + 2 + blob.length + 1);
    accept.setRange(0, 16, transferId);
    accept[16] = chosen.code;
    ByteData.view(accept.buffer).setUint16(17, blob.length, Endian.big);
    accept.setRange(19, 19 + blob.length, blob);
    accept[19 + blob.length] = 0x01 | (armedPreamble ? 0x02 : 0) | 0x04;
    await _dispatch(
      router.originate(
        type: FrameType.fileFastAccept,
        dst: from,
        payload: await crypto.encrypt(accept, kex),
        flags: FrameFlags.encrypted,
      ),
      persist: false,
    );

    // 백그라운드에서 fast lane으로 파일을 읽는다.
    unawaited(_receiveFast(from, tid, kex, inbound));
  }

  Future<void> _receiveFast(
    PeerId from,
    String tid,
    Uint8List kex,
    FastLaneInbound inbound,
  ) async {
    FastLaneSession? session;
    try {
      session = await inbound.session;
      // 소유권: 재오퍼가 이미 새 협상을 시작했다면(다른 수단이 pending) 이
      // 인바운드는 유령이다 — 새 협상의 상태(_fastActive 등)를 건드리면 안
      // 된다.
      final owner = _pendingInboundKind[tid] == inbound.offer.kind;
      if (owner) _pendingInboundKind.remove(tid);
      if (session == null) {
        bleLogSink?.call('FT fast recv: no session (peer never connected) → BLE');
        if (owner) _fastActive.remove(tid);
        return; // 전송 측이 끝내 연결하지 않음 → BLE 복구 타이머가 처리한다
      }
      bleLogSink?.call('FT fast recv connected, reading…');
      _events.add(TransferLane(tid, 'wifi'));
      // 와이어 형식(첫 u32로 구분):
      //  - 세그먼트(매직 0xFFFFFFFF): [segLen u32][seg GCM]… [0 u32] — 세그먼트를
      //    도착 즉시 복호화해 부분 파일에 기록하므로 RAM에는 세그먼트 하나만
      //    머문다. 파일 전체 무결성은 finalize의 매니페스트 해시가 검증한다.
      //  - 레거시: [cipherLen u32][파일 전체 GCM] — 구버전 송신자 호환.
      final q = ListQueue<Uint8List>();
      var qLen = 0;
      // 큐 앞에서 정확히 n바이트를 꺼낸다(각 바이트는 한 번만 복사됨).
      Uint8List take(int n) {
        final out = Uint8List(n);
        var off = 0;
        while (off < n) {
          final head = q.removeFirst();
          final want = n - off;
          if (head.length <= want) {
            out.setRange(off, off + head.length, head);
            off += head.length;
          } else {
            out.setRange(off, n, Uint8List.sublistView(head, 0, want));
            q.addFirst(Uint8List.sublistView(head, want));
            off = n;
          }
        }
        qLen -= n;
        return out;
      }

      int u32(Uint8List b) =>
          ByteData.view(b.buffer, b.offsetInBytes).getUint32(0, Endian.big);

      // 완료 공통 경로: manifest 해시 검증(finalize) 후 서명된 "complete" ACK로
      // 전송 측을 멈추고 그쪽 말풍선을 전달됨으로 바꾼다(BLE 경로 재사용).
      Future<void> completeReceive(FileReceiver receiver, String tidHex) async {
        final path = await receiver.finalize();
        bleLogSink?.call('FT fast recv complete: ${receiver.meta.name}');
        _events.add(FileProgress(tidHex, 1.0, false));
        _events.add(FileReceived(from, receiver.meta, path));
        _completeReceiver(tidHex);
        _rememberCompleted(tidHex);
        final completeAck = receiver.buildAck();
        await _sendFileAck(from, completeAck);
        _repeatCompletionAck(from, completeAck);
      }

      bool? segmented; // 첫 u32를 읽으면 결정된다
      int? need; // 다음에 기대하는 바이트 수(레거시: 전체, 세그먼트: 하나)
      var plainOff = 0; // 세그먼트 모드: 지금까지 기록한 평문 오프셋
      var lastPct = 0;
      var curTid = tid; // 배치 연속 시 현재 스트리밍 중인 전송
      // 배치 연속 하위 상태: 0=일반, 1=종료 마커 뒤 u32 대기(EOF or 연속 매직),
      // 2=다음 tid(16B) 대기, 3=다음 파일의 세그먼트 매직 대기.
      var nextState = 0;
      await for (final part in session.incoming) {
        q.add(part);
        qLen += part.length;
        _rxLastChunk[curTid] = DateTime.now(); // idle 감시 타이머에 먹여준다
        while (true) {
          if (nextState == 1) {
            // 앞 파일 완료 — 같은 세션으로 다음 파일이 이어질 수 있다.
            if (qLen < 4) break;
            final v = u32(take(4));
            if (v != MeshNode.fastLaneMagicNext) {
              bleLogSink?.call('FT fast recv: unexpected trailer — closing');
              return;
            }
            nextState = 2;
            continue;
          }
          if (nextState == 2) {
            if (qLen < 16) break;
            final nextTid = MsgId.hex(take(16));
            final receiver = _receivers[nextTid];
            if (receiver == null) {
              // META가 아직 없거나 이미 완료된 전송 — 이 세션으로는 더
              // 진행할 수 없다. 남은 파일은 각자의 협상으로 온다.
              bleLogSink?.call('FT batch recv: no receiver for $nextTid');
              return;
            }
            curTid = nextTid;
            _fastActive.add(curTid);
            _events.add(TransferLane(curTid, 'wifi'));
            bleLogSink?.call('FT batch recv: ${receiver.meta.name}');
            nextState = 3;
            continue;
          }
          if (nextState == 3) {
            if (qLen < 4) break;
            if (u32(take(4)) != MeshNode.fastLaneMagicSegmented) {
              bleLogSink?.call('FT batch recv: bad segment magic — closing');
              return;
            }
            plainOff = 0;
            lastPct = 0;
            need = null;
            nextState = 0;
            continue;
          }
          if (segmented == null) {
            if (qLen < 4) break;
            final v = u32(take(4));
            if (v == MeshNode.fastLaneMagicSegmented) {
              segmented = true;
            } else {
              segmented = false;
              need = v;
              bleLogSink?.call('FT fast recv expecting ${v}B (legacy)');
            }
            continue;
          }
          if (segmented) {
            if (need == null) {
              if (qLen < 4) break;
              need = u32(take(4));
              if (need == 0) {
                // 종료 마커 — 모든 세그먼트가 부분 파일에 기록됐다.
                // BLE 청크가 이미 finalize로 몰고 갔다면 건너뛴다(이중 방지).
                final receiver = _receivers[curTid];
                if (receiver == null || !_finalizing.add(curTid)) return;
                try {
                  if (plainOff != receiver.meta.fileSize) {
                    throw StateError('segmented size mismatch: '
                        '$plainOff != ${receiver.meta.fileSize}');
                  }
                  receiver.sealSeeded();
                  await completeReceive(receiver, curTid);
                } finally {
                  _finalizing.remove(curTid);
                  _fastActive.remove(curTid);
                }
                // 반환하지 않는다 — 배치 연속(다음 파일)이 이어질 수 있다.
                // 송신자가 끝냈다면 스트림 EOF로 루프가 자연 종료된다.
                need = null;
                nextState = 1;
                continue;
              }
              continue;
            }
            if (qLen < need) break;
            final segCipher = take(need);
            need = null;
            final plain = await crypto.decrypt(segCipher, kex);
            // decrypt를 기다리는 동안 BLE 경로가 완주했을 수 있다 — 재확인.
            final receiver = _receivers[curTid];
            if (receiver == null) return;
            receiver.seedSegment(plainOff, plain);
            plainOff += plain.length;
            final pct = (plainOff * 100) ~/ receiver.meta.fileSize;
            if (pct >= lastPct + 5 && plainOff < receiver.meta.fileSize) {
              lastPct = pct;
              _events.add(FileProgress(
                  curTid, plainOff / receiver.meta.fileSize, false));
            }
            continue;
          }
          // 레거시: 파일 전체 암호문이 모일 때까지 누적한 뒤 한 번에 복호화.
          if (qLen < need!) break;
          final cipher = take(need);
          final receiver = _receivers[tid];
          if (receiver == null || !_finalizing.add(tid)) return;
          try {
            final bytes = await crypto.decrypt(cipher, kex);
            receiver.seedAssembled(bytes);
            await completeReceive(receiver, tid);
          } finally {
            _finalizing.remove(tid);
          }
          return;
        }
        if (segmented == false && need != null) {
          final pct = (qLen * 100) ~/ need;
          if (pct >= lastPct + 5) {
            lastPct = pct;
            _events.add(FileProgress(tid, qLen / need, false));
          }
        }
      }
    } catch (e) {
      bleLogSink?.call('FT fast recv error: $e — falling back to BLE');
      // BLE 수신자 + 복구 타이머를 계속 돌게 둔다: 누락된 청크를 ACK하면 전송
      // 측이 BLE로 다시 보낸다.
    } finally {
      // 세션 없이 끝난 유령 인바운드(재협상으로 대체됨)는 위의 owner 가드가
      // 이미 정리를 결정했다 — 여기서 새 협상의 표식을 지우면 안 된다.
      if (session != null) _fastActive.remove(tid);
      await session?.close();
    }
  }

  /// 송신자-호스트 모드: 그룹(SoftAP)+리스너를 만들고 접속 정보를 HOSTINFO
  /// 프레임으로 보낸 뒤, 수신자가 조인해 다이얼해 오기를 기다린다.
  /// 인증: 접속 정보는 E2E 암호화로만 전달되고 그룹은 WPA2 암호로 잠겨
  /// 있으므로, 조인 자체가 곧 수신자 인증이다(tid 프리앰블 불필요).
  Future<FastLaneSession?> _hostAndAwaitDial(
      FileSender sender, PeerId dst, Uint8List kex) async {
    final host = await fastLane!.prepareOutboundHost(
        sender.meta.transferIdHex, FastLaneKind.wifiDirectHosted);
    if (host == null) return null;
    final blob = host.offer.blob;
    final info = Uint8List(16 + 1 + 2 + blob.length);
    info.setRange(0, 16, sender.meta.transferId);
    info[16] = FastLaneKind.wifiDirectHosted.code;
    ByteData.view(info.buffer).setUint16(17, blob.length, Endian.big);
    info.setRange(19, 19 + blob.length, blob);
    await _dispatch(
      router.originate(
        type: FrameType.fileFastHostInfo,
        dst: dst,
        payload: await crypto.encrypt(info, kex),
        flags: FrameFlags.encrypted,
      ),
      persist: false,
    );
    bleLogSink?.call('FT hosted: group up, HOSTINFO sent — awaiting dial');
    try {
      return await host.session;
    } catch (_) {
      return null;
    }
  }

  /// 수신자 측: 송신자-호스트 접속 정보 도착 — 그룹에 조인하고 다이얼한다.
  /// 성공 시 레인이 [FastLaneInterface.prepareInbound]의 세션 future를
  /// 완성시켜, 이미 대기 중인 [_receiveFast]가 이어서 바이트를 읽는다.
  Future<void> _handleFastHostInfo(Uint8List payload) async {
    if (fastLane == null || payload.length < 19) return;
    final tid = MsgId.hex(Uint8List.fromList(payload.sublist(0, 16)));
    final kind = FastLaneKind.fromCode(payload[16]);
    if (kind == null) return;
    final blobLen = ByteData.view(payload.buffer, payload.offsetInBytes)
        .getUint16(17, Endian.big);
    if (payload.length < 19 + blobLen) return;
    final blob = Uint8List.fromList(payload.sublist(19, 19 + blobLen));
    final ok = await fastLane!.connectToHost(tid, kind, blob);
    bleLogSink?.call('FT hosted connect ${ok ? 'ok' : 'failed'} (tid $tid)');
  }

  void _handleFastAccept(Uint8List payload) {
    if (payload.length < 19) return;
    final tid = MsgId.hex(Uint8List.fromList(payload.sublist(0, 16)));
    final waiter = _fastAcceptWaiters[tid];
    if (waiter == null || waiter.isCompleted) return;
    final kind = FastLaneKind.fromCode(payload[16]);
    if (kind == null) return;
    final blobLen = ByteData.view(
      payload.buffer,
      payload.offsetInBytes,
    ).getUint16(17, Endian.big);
    if (payload.length < 19 + blobLen) return;
    final blob = Uint8List.fromList(payload.sublist(19, 19 + blobLen));
    // blob 뒤 flags 바이트(신버전 수신자) — 없으면 0(레거시).
    final flagsOff = 19 + blobLen;
    final flags = payload.length > flagsOff ? payload[flagsOff] : 0;
    waiter.complete(_FastAccept(FastLaneOffer(kind, blob), flags));
  }
}

/// 수신 측의 fast-lane ACCEPT. 대기 중인 전송 측에게 전달된다.
class _FastAccept {
  final FastLaneOffer offer;

  /// ACCEPT 꼬리의 기능 비트(bit0: 세그먼트 스트리밍 수신 지원).
  /// 구버전 수신자의 ACCEPT에는 없다 → 0 → 레거시 한 덩어리 형식.
  final int flags;
  _FastAccept(this.offer, [this.flags = 0]);

  bool get segmented => flags & 0x01 != 0;

  /// 수신자가 배치 연속([MeshNode.fastLaneMagicNext])을 이해한다 — 같은
  /// 세션으로 여러 파일을 이어 보낼 수 있다.
  bool get batch => flags & 0x04 != 0;

  /// 수신자가 lanSocket tid 프리앰블 검증을 무장했다 — 첫 16바이트로
  /// transferId를 보내야 세션으로 인정받는다.
  bool get wantsPreamble => flags & 0x02 != 0;
}
