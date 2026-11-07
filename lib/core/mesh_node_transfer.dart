part of 'mesh_node.dart';

/// [MeshNode]의 BLE 청크 파일 전송 조율, 송수신 감시 타이머(Watchdog),
/// 누락 청크 재전송, 수신 복구 타이머 및 완료 ACK 처리 책임.
extension _MeshNodeTransfer on MeshNode {
  Future<String?> _startSend(FileSender sender, PeerId dst, Uint8List kex) async {
    final tid = sender.meta.transferIdHex;
    bleLogSink?.call(
      'FT send start: ${sender.meta.name} ${sender.meta.fileSize}B '
      'chunks=${sender.meta.totalChunks}',
    );
    _senders[tid] = sender;
    // 감시 타이머: 완료 ACK가 도착하지 않으면 sender를 폐기하여 영원히 새지
    // 않게 한다(예: 수신자가 떠났거나, 최종 ACK가 유실된 경우).
    _armSenderWatchdog(tid, sender.meta.name);

    // 1. META를 보낸다. 프레임 msgId를 기억해 전송이 끝나면(성공·실패·취소
    // ·보류 무관) 영속 사본을 스토어에서 지운다 — 지우지 않으면 수신자가
    // 재시작한 뒤 재전달돼 유령 수신을 만든다.
    final metaCipher = await crypto.encrypt(sender.meta.encode(), kex);
    final metaFrame = router.originate(
      type: FrameType.fileMeta,
      dst: dst,
      payload: metaCipher,
      flags: FrameFlags.encrypted,
    );
    _metaMsgIdByTid[tid] = metaFrame.msgIdHex;
    await _dispatch(metaFrame);

    // 2. 바이트를 전달한다. 큰 파일은 Wi-Fi fast lane을 시도한다; 어떤
    // 실패든(fast lane 없음, 공유 기능 없음, 연결/스트림 오류) BLE 청킹으로
    // 폴백한다. 호출자는 transferId를 즉시 받으므로, 경로와 무관하게 UI가
    // 말풍선 + 진행률을 표시한다.
    unawaited(_deliverFile(sender, dst, kex));
    return tid;
  }

  /// 가능하면 fast lane을, 아니면 BLE 청킹을 선택한다. 전송 하나당 항상 정확히
  /// 한 경로로 귀결된다.
  Future<void> _deliverFile(
    FileSender sender,
    PeerId dst,
    Uint8List kex,
  ) async {
    final tid = sender.meta.transferIdHex;
    if (fastLane != null &&
        fastLane!.capabilities.isNotEmpty &&
        sender.meta.fileSize >= MeshNode.fastLaneMinBytes) {
      // 락 대기열에서 차례를 기다리는 동안에도 이 전송은 살아 있다 — 여기서
      // 워치독을 계속 먹여주지 않으면, 앞 파일이 60초 이상 점유할 때 뒤
      // 파일이 시작도 못 해 보고 idle 타임아웃으로 죽는다(관찰: 파일 2개
      // 선택 시 두 번째가 타임아웃). 스트리밍 중 급식도 이 타이머가 겸한다.
      final feeder = Timer.periodic(const Duration(seconds: 20), (_) {
        if (_senders.containsKey(tid)) {
          _armSenderWatchdog(tid, sender.meta.name);
        }
      });
      final queuedAt = DateTime.now();
      _fastQueued.add(tid); // 시작 전 — 수신 측 조바심 ACK에 재전송 금지
      // 배치 후보 등록: 앞 파일의 락 소유자가 자기 세션으로 이어 보낼 수 있다.
      (_fastBatchCandidates[dst.hex] ??= []).add(tid);
      bool ok;
      try {
        // 협상·Wi-Fi 스트림만 직렬화. 실패 후 BLE 폴백은 락 밖에서 병행 가능.
        ok = await _withFastLaneLock(
          () {
            final waited = DateTime.now().difference(queuedAt);
            if (waited > const Duration(seconds: 2)) {
              bleLogSink?.call(
                  'FT fast lane queue waited ${waited.inSeconds}s: '
                  '${sender.meta.name}');
            }
            return _trySendFast(sender, dst, kex);
          },
          turnTimeout: const Duration(seconds: 90),
          onTurnTimeout: () {
            bleLogSink?.call('FT fast lane turn timeout (90s) → BLE: '
                '${sender.meta.name}');
            return false;
          },
        );
      } catch (e) {
        // 어떤 예외도 파일 하나를 조용히 증발시키면 안 된다 — BLE로 살린다.
        bleLogSink?.call('FT fast path error: $e → BLE: ${sender.meta.name}');
        ok = false;
      } finally {
        feeder.cancel();
        _fastQueued.remove(tid);
        _fastBatchCandidates[dst.hex]?.remove(tid);
      }
      if (ok) return; // fast lane이 전달을 완수함(전달 ACK는 BLE로 도착)
      // 차례 타임아웃(90초) 등으로 락에서 밀려났지만 그 사이 앞 파일의
      // 세션에 편승해 이미 전송됐을 수 있다 — BLE 중복 전송 금지.
      if (_batchDelivered.remove(tid)) return;
      if (!_senders.containsKey(tid)) return; // 그 사이에 취소됨/폐기됨
      bleLogSink?.call(
        'FT fast lane unavailable → BLE fallback: ${sender.meta.name}',
      );
    }
    // 멀티홉 BLE 예산 게이트: Wi-Fi가 못 살린 대용량은 중계 노드들을 수 분간
    // 점유하는 대신 보류한다 — 상대가 직접 나타나면 자동 재전송된다.
    final hops = _lastHops[dst.hex] ?? 1;
    if (hops >= 2 && sender.meta.fileSize > MeshNode.bleBudgetBytes(hops)) {
      bleLogSink?.call('FT deferred (${sender.meta.fileSize}B > '
          '$hops-hop BLE budget): ${sender.meta.name}');
      final s = _senders.remove(tid);
      _senderTimers.remove(tid)?.cancel();
      s?.close();
      _purgeMeta(tid);
      _events.add(FileDeferred(tid, dst, sender.meta.name, hops));
      return;
    }
    // BLE 낙하도 직렬화: 한 링크에 대용량 청킹이 병렬로 흐르면 서로의
    // 대역을 잡아먹고 전부 타임아웃난다(2026-07-20 11:17: 9파일 병렬 → 전멸).
    // 대기 중에는 조바심 ACK 재전송을 금지하고(_fastQueued) 워치독을 계속
    // 먹여준다. 수신자의 첫-바이트 대기 상한(5분)이 대기 시간의 상한이다.
    _fastQueued.add(tid);
    final bleFeeder = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_senders.containsKey(tid)) _armSenderWatchdog(tid, sender.meta.name);
    });
    final gate = Completer<void>();
    final prevBle = _bleStreamChain;
    _bleStreamChain = gate.future;
    try {
      await prevBle.catchError((_) {});
      if (_batchDelivered.remove(tid)) return; // 대기 중 배치로 전송됨
      if (!_senders.containsKey(tid)) return; // 취소/폐기됨
      _fastQueued.remove(tid);
      _streaming.add(tid);
      await _streamChunks(sender, dst, kex);
    } finally {
      if (!gate.isCompleted) gate.complete();
      bleFeeder.cancel();
      _fastQueued.remove(tid);
    }
  }

  /// sender가 폐기되면(완료 ACK가 도착했거나 취소/타임아웃됨) 완료된다 —
  /// 전송 후 flush 대기를 조기에 끝내는 데 사용된다.
  Future<void> _senderRetired(String tid) async {
    while (_senders.containsKey(tid)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// sender 감시 타이머를 계속 먹여준다. 전송 시작 시점과 수신 측의 모든 ACK
  /// 마다 (재)무장되므로 — 전송은 실제로 조용해진 뒤에야 죽는다.
  void _armSenderWatchdog(String tid, String name) {
    _senderTimers[tid]?.cancel();
    _senderTimers[tid] = Timer(MeshNode._transferIdleTimeout, () {
      final sender = _senders.remove(tid);
      if (sender != null) {
        sender.close();
        _senderTimers.remove(tid);
        _streaming.remove(tid);
        _purgeMeta(tid);
        bleLogSink?.call('FT send timeout: $name');
        _events.add(FileFailed(tid, name, incoming: false));
        _events.add(NodeError('File transfer timed out: $name'));
      }
    });
  }

  void _cancelSendImpl(String transferIdHex) {
    final sender = _senders.remove(transferIdHex);
    if (sender != null) {
      sender.close();
      _senderTimers.remove(transferIdHex)?.cancel();
      _streaming.remove(transferIdHex);
      _purgeMeta(transferIdHex);
      bleLogSink?.call('FT send cancelled: $transferIdHex');
    }
  }

  Future<void> _streamChunks(
    FileSender sender,
    PeerId dst,
    Uint8List kex,
  ) async {
    final tid = sender.meta.transferIdHex;
    _events.add(TransferLane(tid, 'ble'));
    var sent = 0;
    var lastPct = -1;
    try {
      for (final chunk in sender.allChunks()) {
        // 버스트 도중에 폐기됨(조기 완료, 타임아웃, 취소, 정지) — 또는
        // 재시도가 같은 tid를 "새 sender"로 교체함. containsKey만 보면 옛
        // 버스트가 교체된(닫힌) sender의 파일 핸들을 계속 읽다 터진다
        // (관찰: FileSystemException: File closed).
        if (!identical(_senders[tid], sender)) return;
        final cipher = await crypto.encrypt(chunk.encode(), kex);
        await _dispatch(
          router.originate(
            type: FrameType.fileChunk,
            dst: dst,
            payload: cipher,
            flags: FrameFlags.encrypted,
          ),
          persist: false,
        );
        sent++;
        // 진행률 이벤트를 조절한다: 청크마다가 아니라 퍼센트마다 하나씩.
        final pct = sent * 100 ~/ sender.meta.totalChunks;
        if (pct != lastPct || sent == sender.meta.totalChunks) {
          lastPct = pct;
          _events.add(FileProgress(tid, sent / sender.meta.totalChunks, true));
        }
      }
      bleLogSink?.call(
        'FT send burst done: ${sender.meta.name} ($sent chunks)',
      );
    } catch (e) {
      bleLogSink?.call('FT send burst error: $e');
    } finally {
      _streaming.remove(tid);
    }
  }

  /// 전송이 어떤 이유로든 끝났다: 스토어의 영속 META를 지워 재전달을 막는다.
  void _purgeMeta(String transferIdHex) {
    final msgId = _metaMsgIdByTid.remove(transferIdHex);
    if (msgId != null) store.remove(msgId);
  }

  void _retireSender(String transferIdHex) {
    _senders.remove(transferIdHex)?.close();
    _senderTimers.remove(transferIdHex)?.cancel();
    _streaming.remove(transferIdHex);
    _purgeMeta(transferIdHex);
  }

  Future<void> _handleFileMeta(PeerId src, Uint8List payload) async {
    final meta = FileMeta.decode(payload);
    // 이미 진행 중인 전송의 재offer는 무시한다.
    if (_receivers.containsKey(meta.transferIdHex)) return;
    // 이미 완료한 전송의 META가 되돌아왔다(스토어 재전달, 우리 재시작
    // 후 흔함): 새 수신을 만들면 바이트가 영영 오지 않아 유령 "수신
    // 실패"가 된다. 완료 ACK만 다시 보내 송신 측이 영속 사본을 지우게
    // 한다.
    if (_completedTransfers.contains(meta.transferIdHex)) {
      bleLogSink?.call(
          'FT recv meta ignored (already complete): ${meta.name}');
      await _sendFileAck(src, FileAck(meta.transferId, true, const []));
      return;
    }
    // 피어가 제공한 manifest는 아무것도 신뢰하지 않는다: 전송 측은
    // [maxFileBytes]에서 상한을 두므로, 그보다 큰 fileSize는 잘못됐거나
    // 적대적이다. FileReceiver가 그 크기로 부분 파일을 미리 할당하기 전에
    // 거부한다.
    if (meta.fileSize < 0 || meta.fileSize > MeshNode.maxFileBytes) {
      bleLogSink?.call('FT recv rejected oversize meta: ${meta.fileSize}');
      return;
    }
    bleLogSink?.call(
      'FT recv meta: ${meta.name} chunks=${meta.totalChunks}',
    );
    // 같은 파일의 재전송(재시도 = 새 tid): 옛 미완료 수신자는 유령이다 —
    // 그대로 두면 나중에 타임아웃하며 "수신 실패" 말풍선을 남겨, 성공한
    // 재시도 옆에서 사용자를 헷갈리게 한다. 조용히 대체한다.
    for (final e in _receivers.entries.toList()) {
      final old = e.value;
      if (!old.isComplete &&
          _receiverPeers[e.key] == src &&
          old.meta.name == meta.name &&
          old.meta.fileSize == meta.fileSize) {
        bleLogSink?.call('FT recv superseded by retry: ${meta.name} '
            '(old ${e.key.substring(0, 8)})');
        old.discard();
        _rxTimers.remove(e.key)?.cancel();
        _completeReceiver(e.key);
        _events.add(FileSuperseded(e.key));
      }
    }
    _receivers[meta.transferIdHex] =
        FileReceiver(meta, incomingPartPath(meta.transferIdHex));
    _receiverPeers[meta.transferIdHex] = src;
    _startReceiverRecovery(meta.transferIdHex, src);
    _events.add(FileOffered(src, meta));
  }

  Future<void> _handleFileAckPayload(PeerId from, Uint8List payload) async {
    if (payload.length < 1 + 19) return; // 최소 FileAck (id16+flag+count2)
    final FileAck ack;
    try {
      ack = FileAck.decode(Uint8List.fromList(payload.sublist(1)));
    } catch (_) {
      return; // 잘못된 형식의 file ack
    }
    final sender = _senders[ack.transferIdHex];
    if (sender == null) return;
    final kex = _knownKex[from.hex];
    if (kex == null) return;
    // 어떤 ACK든 수신자가 살아 있다는 증거다 — 전송을 계속 진행한다.
    _armSenderWatchdog(ack.transferIdHex, sender.meta.name);
    if (ack.complete) {
      bleLogSink?.call('FT delivered: ${sender.meta.name}');
      _retireSender(ack.transferIdHex);
      _events.add(FileProgress(ack.transferIdHex, 1, true));
      _events.add(DeliveryConfirmed(ack.transferIdHex));
      return;
    }
    // 초기 버스트가 아직 스트리밍 중(BLE)이거나 fast lane이 회선을 소유하고
    // 있다: "누락"된 것은 모두 이미 가는 중이다. 지금 재전송하면 전송 전체가
    // BLE로 중복될 것이다.
    if (_streaming.contains(ack.transferIdHex) ||
        _fastActive.contains(ack.transferIdHex) ||
        // 아직 시작도 안 한 전송(fast-lane 대기열): 수신 측은 META만 보고
        // "전부 누락"을 조르지만, 여기 응답하면 대기 중인 파일 수만큼의
        // 재전송 루프가 겹치며 BLE 대역을 태운다. 곧 정식 버스트가 간다.
        _fastQueued.contains(ack.transferIdHex)) {
      return;
    }
    // 루프 직렬화: ACK는 ~3초마다 오는데 64청크 재전송은 그보다 느리다 —
    // 겹치면 같은 청크의 중복 사본만 쌓여 유효 처리량이 0에 수렴한다.
    if (!_resending.add(ack.transferIdHex)) return;
    try {
      bleLogSink?.call('FT resend requested: ${ack.missing.length} chunks '
          '(${ack.transferIdHex.substring(0, 8)})');
      for (final chunk in sender.chunksToResend(ack)) {
        // 폐기됐거나 재시도가 sender를 교체함(닫힌 파일 핸들 접근 방지).
        if (!identical(_senders[ack.transferIdHex], sender)) return;
        final cipher = await crypto.encrypt(chunk.encode(), kex);
        await _dispatch(
          router.originate(
            type: FrameType.fileChunk,
            dst: from,
            payload: cipher,
            flags: FrameFlags.encrypted,
          ),
          persist: false,
        );
      }
    } finally {
      _resending.remove(ack.transferIdHex);
    }
  }

  Future<void> _handleFileChunk(PeerId from, Uint8List payload) async {
    // fast lane이 이 전송의 바이트를 소유한다 — 떠도는 BLE 청크는 모두 무시한다.
    // (폴백 도중 두 경로가 순간적으로 경쟁할 수 있다.)
    final FileChunk chunk;
    try {
      chunk = FileChunk.decode(payload);
    } catch (_) {
      return; // 잘못된 형식의 청크
    }
    final tidHex = MsgId.hex(chunk.transferId);
    final receiver = _receivers[tidHex];
    if (receiver == null) {
      // 이미 완료한 전송에 대한 떠도는 청크: 전송 측이 우리의 완료 ACK를 받지
      // 못한 것이다. 전송 측이 멈출 수 있도록 다시 보낸다.
      if (_completedTransfers.contains(tidHex)) {
        await _sendFileAck(from, FileAck(chunk.transferId, true, const []));
      }
      return; // 아직 META를 보지 못함(또는 이미 완료됨)
    }
    // 첫 청크 = BLE 경로 확정(수신 측). fast lane이 끼어들면 그쪽 이벤트가
    // 나중에 'wifi'로 덮어쓴다.
    if (receiver.receivedCount == 0) {
      _events.add(TransferLane(tidHex, 'ble'));
    }
    final isNew = receiver.offer(chunk);
    _rxLastChunk[tidHex] = DateTime.now();
    // 진행률 이벤트를 조절한다: 청크마다가 아니라 퍼센트마다 하나씩.
    final pct = (receiver.progress * 100).floor();
    if (isNew && (pct != _rxLastPct[tidHex] || receiver.isComplete)) {
      _rxLastPct[tidHex] = pct;
      _events.add(FileProgress(tidHex, receiver.progress, false));
    }

    // `_finalizing.add`는 이 전송에 대해 이미 finalize가 돌고 있으면 false를
    // 반환한다(중복 청크가 finalize의 await 창으로 끼어들었거나, fast lane이
    // 이를 마무리하는 중) — 이중 finalize를 하지 않도록 건너뛴다.
    if (receiver.isComplete && _finalizing.add(tidHex)) {
      try {
        final path = await receiver.finalize();
        bleLogSink?.call('FT recv complete: ${receiver.meta.name}');
        _events.add(FileReceived(from, receiver.meta, path));
        final completeAck = receiver.buildAck();
        _completeReceiver(tidHex);
        _rememberCompleted(tidHex);
        await _sendFileAck(from, completeAck);
        _repeatCompletionAck(from, completeAck);
      } catch (_) {
        // 모든 청크가 다 있는데 파일 해시가 불일치. 청크별 GCM은 이를 거의
        // 불가능하게 만든다; "complete"로 잘못 ACK하기보다는(그러면 전송 측이
        // 멈춘다) 복구 불가능한 실패로 처리한다.
        receiver.discard();
        _completeReceiver(tidHex);
        _events.add(NodeError('File integrity check failed; discarded'));
      } finally {
        _finalizing.remove(tidHex);
      }
    }
    // 여기서는 인밴드 부분 ACK를 하지 않는다: 큰 파일에서 N 청크마다 ACK하면
    // 거대한 누락 목록으로 역방향 경로를 넘치게 하고, 아직 전송 중인 청크의
    // 중복 재전송을 유발한다. 대신 [_startReceiverRecovery]의 복구 타이머가
    // idle/하트비트에 맞춰 ACK한다.
  }

  /// 완료된 전송을 기억해 유실된 최종 ACK를 다시 보낼 수 있게 하며, 오래 도는
  /// 세션 동안 집합이 무한정 커지지 않도록 크기를 제한한다.
  void _rememberCompleted(String tidHex) {
    _completedTransfers.add(tidHex);
    const cap = 256;
    while (_completedTransfers.length > cap) {
      _completedTransfers.remove(_completedTransfers.first);
    }
    completedTransfersSave?.call(_completedTransfers.toList());
  }

  /// 완료 ACK는 단발 BLE 프레임이라 유실되면 전송 측이 60초 뒤 "실패"로
  /// 오판한다(관찰 2026-07-17 22:58: 수신은 완료됐는데 전송 측 send timeout —
  /// 파일은 갔는데 상태만 거짓 실패). 몇 번 반복해 유실 확률을 없앤다 —
  /// 전송 측 ACK 처리는 멱등이라 중복은 무해하다.
  void _repeatCompletionAck(PeerId to, FileAck ack) {
    for (final delay in const [
      Duration(seconds: 4),
      Duration(seconds: 15),
      Duration(seconds: 40),
    ]) {
      _ackRepeatTimers.add(Timer(delay, () {
        unawaited(_sendFileAck(to, ack));
      }));
    }
    // 오래된 완료 타이머가 무한히 쌓이지 않게 간단히 손질한다.
    if (_ackRepeatTimers.length > 60) {
      _ackRepeatTimers.removeRange(0, _ackRepeatTimers.length - 60);
    }
  }

  void _completeReceiver(String tidHex) {
    _receivers.remove(tidHex);
    _receiverPeers.remove(tidHex);
    _rxTimers.remove(tidHex)?.cancel();
    _rxLastChunk.remove(tidHex);
    _rxLastAck.remove(tidHex);
    _rxLastPct.remove(tidHex);
  }

  /// 전송이 미완료인 동안, 전송 측이 조용해지면(버스트가 끝났거나 멈춤) 누락된
  /// seq를 ACK하고, 활성 버스트 중에는 느린 하트비트를 더한다. 들어오는 청크가
  /// 전혀 없는 채로 [_transferIdleTimeout]이 지난 뒤에야 포기한다 — 여전히
  /// 진전이 있는 큰 파일은 결코 타임아웃되지 않는다.
  void _startReceiverRecovery(String tidHex, PeerId from) {
    _rxTimers[tidHex]?.cancel();
    _rxLastChunk[tidHex] = DateTime.now();
    _rxLastAck[tidHex] = DateTime.now();
    _rxTimers[tidHex] = Timer.periodic(MeshNode._fileAckInterval, (t) async {
      final receiver = _receivers[tidHex];
      if (receiver == null || receiver.isComplete) {
        t.cancel();
        return;
      }
      final now = DateTime.now();
      final idle = now.difference(_rxLastChunk[tidHex] ?? now);
      // 아직 바이트가 하나도 안 온 전송은 전송 측 fast-lane 대기열에서 차례를
      // 기다리는 중일 수 있다(다중 파일 선택 시 한 건씩 직렬화됨 — 앞 파일이
      // 큰 경우 수 분). 시작 전 대기는 넉넉히, 진행 중 침묵은 기존대로 짧게.
      final patience = receiver.receivedCount == 0
          ? MeshNode._transferQueuedTimeout
          : MeshNode._transferIdleTimeout;
      if (idle > patience) {
        t.cancel();
        bleLogSink?.call('FT recv timeout: ${receiver.meta.name}');
        receiver.discard();
        _completeReceiver(tidHex);
        _events.add(FileFailed(tidHex, receiver.meta.name, incoming: true));
        _events.add(
          NodeError('Incoming file timed out: ${receiver.meta.name}'),
        );
        return;
      }
      // fast lane이 전달하는 동안에는 BLE 청크가 예상되지 않는다 — 지금 누락
      // 목록 ACK를 보내면 중복 BLE 재전송만 유발한다. 위의 idle 타임아웃은
      // 여전히 적용된다(fast 조각들이 [_rxLastChunk]에 먹여준다).
      if (_fastActive.contains(tidHex)) return;
      final sinceAck = now.difference(_rxLastAck[tidHex] ?? now);
      if (idle >= MeshNode._ackIdleGap || sinceAck >= MeshNode._ackHeartbeat) {
        _rxLastAck[tidHex] = now;
        await _sendFileAck(
            from, receiver.buildAck(maxMissing: MeshNode._ackMaxMissing));
      }
    });
  }

  Future<void> _sendFileAck(PeerId dst, FileAck ack) async {
    final raw = ack.encode();
    final payload = Uint8List(1 + raw.length)
      ..[0] = _AckKind.file
      ..setRange(1, 1 + raw.length, raw);
    final kex = _knownKex[dst.hex];
    final flags = kex != null ? FrameFlags.encrypted : 0;
    final body = kex != null ? await crypto.encrypt(payload, kex) : payload;
    // File ACK는 잦은 복구 트래픽이다 — store-and-forward할 가치가 없다.
    await _dispatch(
      router.originate(
        type: FrameType.ack,
        dst: dst,
        payload: body,
        flags: flags,
      ),
      persist: false,
    );
  }
}
