part of 'mesh_node.dart';

/// [MeshNode]의 수신 라우팅, 신원(Announce), 파킹(Parking), 영수증(Receipt),
/// 그리고 종단 간 ACK 처리 책임.
extension _MeshNodeReceive on MeshNode {
  void _onLinkEvent(LinkEvent e) async {
    _events.add(LinksChanged(transport.linkCount));
    if (e.up) {
      // 우리 자신을 소개하고 store-and-forward 저장소 목록(inventory)을 동기화한다.
      await _sendAnnounce(e.link.id);
      await _sendHave(e.link.id);
      // peripheral 링크(상대가 우리에게 붙음): 상대가 우리 서비스 discovery
      // 와 write handle 확보를 끝낼 때까지 announce를 몇 번 더 밀어 넣는다.
      // 삼성 One UI 등 느린 GATT 클라이언트가 뒤늦게 준비를 마쳤을 때 우리를
      // 인식하고 자기 announce로 답하게 해, 좀비로 오판돼 끊기기 전에 링크가
      // 살아나게 한다(2026-07-24 삼성 무한 재연결 루프 대응). 링크가 이미
      // 죽었으면 sendToLink가 no-op이라 안전하다.
      if (e.link.role == LinkRole.peripheral) {
        final linkId = e.link.id;
        for (final secs in const [3, 8, 16, 24]) {
          Timer(Duration(seconds: secs), () {
            // 링크가 이미 사라졌거나 노드가 멈췄으면 sendToLink가 no-op이다.
            unawaited(transport
                .sendToLink(linkId, _announceFrame().encode())
                .catchError((_) {}));
          });
        }
      }
      // 새로 생긴 링크는 확인받지 못한 텍스트를 재시도하기에 가장 좋은 순간이다 —
      // 재전송 틱이나 HAVE/WANT 왕복을 기다리지 말고 지금 바로 새 파이프로 밀어
      // 넣는다. 수신자는 중복을 제거하며, 이것은 공짜 기회다: maxTextAttempts에
      // 카운트되지 않는다.
      for (final pending in _awaitingAck.values.toList()) {
        await transport.sendToLink(e.link.id, pending.frame.encode());
      }
    }
  }

  /// 라우터를 통해 존재(presence) 프레임을 만들어 우리 자신의 msgId가 seen으로
  /// 표시되게 한다 — 플러딩된 announce가 우리에게 되돌아오면 전달하거나 다시
  /// 릴레이하지 말고 버려야 한다.
  Frame _announceFrame() {
    final ann = Announce(
      publicBundle: identity.publicBundle,
      displayName: displayName,
      avatar: avatarRecipe,
    );
    return router.originate(
      type: FrameType.announce,
      dst: PeerId.broadcast,
      payload: ann.encode(),
      ttl: MeshNode.announceTtl,
    );
  }

  Future<void> _sendAnnounce(String linkId) async {
    await transport.sendToLink(linkId, _announceFrame().encode());
  }

  Future<void> _sendHave(String linkId) async {
    final inv = store.inventory();
    final frame = Frame.create(
      type: FrameType.have,
      ttl: 1,
      src: myId,
      dst: PeerId.broadcast,
      payload: MsgIdList.encode(inv),
    );
    await transport.sendToLink(linkId, frame.encode());
  }

  void _onPacket(InboundPacket pkt) async {
    // 여기의 모든 처리는 공격자의 영향을 받은 바이트 위에서 돌아간다. 잘못된
    // 프레임 하나가 절대 수신 파이프라인을 죽여서는 안 되므로, 본문 전체를
    // 가드로 감쌌다(아래 개별 디코더들이 적대적 입력에 예외를 던질 수 있다).
    try {
      final Frame frame;
      try {
        frame = Frame.decode(pkt.frameBytes);
      } catch (_) {
        return; // 잘못된 헤더/길이
      }

      // 이 링크의 피어로부터 full-TTL announce가 곧바로 도착했다: RSSI 폴링이
      // 측정값의 주인을 알 수 있도록 반대편 끝에 누가 있는지 기억해둔다
      // (iOS 광고에는 id가 없으므로, 매핑은 이렇게 이루어진다).
      if (frame.type == FrameType.announce &&
          frame.ttl == MeshNode.announceTtl &&
          pkt.link.remoteShortId == null) {
        pkt.link.remoteShortId = frame.src;
      }

      if (frame.type.isLinkLocal) {
        await _handleLinkLocal(frame, pkt.link.id);
        return;
      }

      // 전달이 입증됨(서명된 영수증): 전달하거나, 릴레이하거나, 다시 저장하지
      // 않는다 — 오래 오프라인이던 폰이 이를 되살리지 못하게 하는 장치다. 다만
      // 전송 측이 여전히 우리에게 재전송하고 있다면, 그쪽 ACK가 유실된 것이다:
      // 멈출 수 있도록 다시 ACK한다(아래 중복 분기와 동일).
      if (_receipted.contains(frame.msgIdHex)) {
        if (frame.type == FrameType.text &&
            frame.ackRequested &&
            frame.dst == myId &&
            _deliveredIncoming.contains(frame.msgIdHex)) {
          await _sendMessageAck(frame.src, frame.msgId);
        }
        return;
      }

      final decision = router.handleIncoming(frame);
      if (decision.duplicate) {
        // 라우터가 이전에 본 프레임(루프 방지) — 하지만 "seen" ≠ "delivered".
        // 이 프레임이 우리 앞으로 온 것인데 우리가 보긴 했으나 앱까지 전달하지
        // 못했다면(복호화 실패 / 당시 키 없음), 재전송/재요청(re-pull)은 이를
        // 전달할 기회다: 버리지 말고 전달을 다시 수행한다. 이것이 깨진 사본 하나가
        // 메시지를 영영 잃게 하는 것을 막아준다.
        if (frame.dst == myId &&
            !_deliveredIncoming.contains(frame.msgIdHex) &&
            _pendingLocalDelivery.contains(frame.msgIdHex)) {
          await _deliverLocal(frame);
          return;
        }
        // 우리가 이미 전달한 텍스트의 재전송: 전송 측의 첫 ACK가 유실됐을
        // 가능성이 크다. 멈출 수 있도록 다시 ACK한다. (seen-cache가 _deliverLocal
        // 이전에 프레임을 버리므로, 여기가 복구할 수 있는 유일한 지점이다.)
        if (frame.type == FrameType.text &&
            frame.ackRequested &&
            frame.dst == myId &&
            _deliveredIncoming.contains(frame.msgIdHex)) {
          await _sendMessageAck(frame.src, frame.msgId);
        }
        return;
      }

      if (decision.relay != null) {
        // 존재(presence)는 순간적이다: 실시간으로 릴레이하되 절대
        // store-and-forward하지 않는다(몇 시간 뒤에 전달되는 낡은 "주변" 정보는
        // 거짓말이 될 것이다).
        if (frame.type != FrameType.announce) {
          store.add(decision.relay!);
        }
        await transport.broadcast(
          decision.relay!.encode(),
          exceptLinkId: pkt.link.id,
        );
      }
      if (decision.deliverLocal) {
        await _deliverLocal(frame, via: pkt.link.remoteShortId);
      }
    } catch (e) {
      _events.add(NodeError('Dropped malformed frame: $e'));
    }
  }

  Future<void> _handleLinkLocal(Frame frame, String linkId) async {
    switch (frame.type) {
      case FrameType.have:
        final remoteHave = MsgIdList.decode(frame.payload);
        final wanted = store.selectWanted(
          remoteHave,
          // "Seen"은 릴레이/전달된 프레임의 재요청(re-pull)을 막는다 — 단,
          // 우리 앞으로 왔고 우리가 보긴 했으나 끝내 전달하지 못한 메시지는
          // 예외다(복호화 실패 / 키 없음). 그런 것들은 새 사본을 계속 요청해야
          // 한다. 그러지 않으면 깨진 전달 한 번에 메시지를 영영 잃는다.
          alreadySeen: (hex) =>
              !_pendingLocalDelivery.contains(hex) &&
              (seen.contains(hex) || _receipted.contains(hex)),
        );
        if (wanted.isNotEmpty) {
          final want = Frame.create(
            type: FrameType.want,
            ttl: 1,
            src: myId,
            dst: PeerId.broadcast,
            payload: MsgIdList.encode(wanted),
          );
          await transport.sendToLink(linkId, want.encode());
        }
        break;
      case FrameType.want:
        final wanted = MsgIdList.decode(frame.payload);
        for (final f in store.framesForWanted(wanted)) {
          await transport.sendToLink(linkId, f.encode());
        }
        break;
      default:
        break;
    }
  }

  Future<void> _deliverLocal(Frame frame, {PeerId? via}) async {
    Uint8List payload = frame.payload;
    if (frame.isEncrypted) {
      final kex = _knownKex[frame.src.hex];
      if (kex == null) {
        // 아직 전송 측의 키를 학습하지 못함(예: 메시지가 그들의 ANNOUNCE보다 더
        // 멀리 이동함, 또는 앱 재설치로 로컬 연락처 DB만 초기화된 상태에서 이웃의
        // 릴레이 보관함에서 예전 프레임이 들어옴). 프레임을 태워버리지 말고 — 잠시
        // 보관(park)해두었다가 그들의 ANNOUNCE가 도착하면 재시도한다([redeliverParked]).
        // 백그라운드 프로토콜 대기 상태이므로 사용자 스낵바(NodeError)는 띄우지 않고
        // 진단 로그만 남긴다.
        if (frame.dst == myId && !store.contains(frame.msgIdHex)) {
          store.add(frame);
          bleLogSink?.call(
              'MSG parked (no key yet) from ${frame.src.short} '
              '${frame.msgIdHex.substring(0, 8)}');
        }
        if (frame.dst == myId) _markPendingLocalDelivery(frame.msgIdHex);
        return;
      }
      try {
        payload = await crypto.decrypt(frame.payload, kex);
      } catch (_) {
        _events.add(NodeError('Decrypt failed from ${frame.src.short}'));
        // 손상된 페이로드(예: 불안정한 링크에서 유실된 프래그먼트): 영원히
        // 버리는 대신 새(FRESH) 사본을 계속 WANT한다. 여기서는 사본을 가지고
        // 있지 않으므로(이건 불량), [selectWanted]가 다시 요청할 수 있다.
        if (frame.dst == myId) _markPendingLocalDelivery(frame.msgIdHex);
        return;
      }
    }

    switch (frame.type) {
      case FrameType.announce:
        if (frame.src == myId) break; // 우리 자신의 플러딩이 되돌아온 것
        try {
          final ann = Announce.decode(payload);
          final contact = ContactIdentity.fromBundle(
            ann.publicBundle,
            displayName: ann.displayName,
          );
          _knownKex[contact.peerId.hex] = contact.kexPublic;
          _knownSigning[contact.peerId.hex] = contact.signingPublic;
          // TTL은 릴레이 한 번마다 하나씩 감소한다: 직접 = announceTtl, 릴레이
          // 하나 = announceTtl-1, … 다른 origin TTL을 쓰는 피어(구버전은 ttl 1로
          // announce함)의 프레임에 대비해 clamp한다.
          final hops =
              (MeshNode.announceTtl - frame.ttl + 1).clamp(1, MeshNode.announceTtl);
          _lastHops[contact.peerId.hex] = hops;
          _events.add(
              PeerAnnounced(contact, hops: hops, via: via, avatar: ann.avatar));
          // 그들의 키가, 그들을 알기 전에 보관해둔 메시지를 열어줄 수 있다.
          unawaited(redeliverParked(from: contact.peerId));
        } catch (_) {}
        break;
      case FrameType.text:
        // 재전송 중인 전송 측이 멈출 수 있도록 항상 다시 ACK하되, 특정 메시지는
        // 앱에 한 번만 노출한다(재요청(re-pull)된 store-and-forward 프레임이
        // 중복을 만들어서는 안 된다).
        if (frame.ackRequested) {
          await _sendMessageAck(frame.src, frame.msgId);
        }
        if (_deliveredIncoming.contains(frame.msgIdHex)) break;
        _rememberDelivered(frame.msgIdHex);
        _clearPendingLocalDelivery(frame.msgIdHex); // 드디어 도착함
        final envelope = TextEnvelope.decode(payload);
        // sentAt=none은 레거시(LEGACY) 전송 측을 나타낸다(v1.5.16 이전 페이로드) —
        // "왜 전송 시각이 안 떠?"를 현장에서 진단하는 시그니처다.
        bleLogSink?.call('MSG recv ${frame.msgIdHex.substring(0, 8)} '
            '(${envelope.text.length} chars, '
            'sentAt=${envelope.sentAt?.toIso8601String() ?? 'none'})');
        _events.add(TextReceived(frame.src, envelope.text, frame.msgIdHex,
            sentAt: envelope.sentAt));
        // 릴레이들이 자기 사본을 버릴 수 있도록 이 텍스트가 도착했음을 메시 전체에
        // 알리고, 우리 자신도 다시는 이를 받아들이지 않는다.
        _tombstone(frame.msgIdHex);
        unawaited(_broadcastReceipt(frame.msgId));
        break;
      case FrameType.ack:
        await _handleAck(frame.src, payload);
        break;
      case FrameType.fileMeta:
        await _handleFileMeta(frame.src, payload);
        break;
      case FrameType.reaction:
        if (payload.length < 17) break;
        final target = MsgId.hex(Uint8List.sublistView(payload, 0, 16));
        final removed = payload[16] == 1;
        final emoji =
            utf8.decode(payload.sublist(17), allowMalformed: true).trim();
        // 상한: 조합(ZWJ) 이모지도 UTF-8로 ~35바이트 — 그 이상은 악성/오류.
        if (emoji.isEmpty || emoji.length > 24) break;
        _events.add(ReactionReceived(frame.src, target, emoji, removed));
        // 전달됐으니 메일박스들이 사본을 지울 수 있게 영수증을 낸다.
        unawaited(_broadcastReceipt(frame.msgId));
        break;
      case FrameType.verify:
        if (payload.length != 16) break;
        _events.add(VerifyReceived(frame.src, Uint8List.fromList(payload)));
        unawaited(_broadcastReceipt(frame.msgId));
        break;
      case FrameType.fileChunk:
        await _handleFileChunk(frame.src, payload);
        break;
      case FrameType.fileFastOffer:
        await _handleFastOffer(frame.src, payload);
        break;
      case FrameType.fileFastAccept:
        _handleFastAccept(payload);
        break;
      case FrameType.fileFastHostInfo:
        await _handleFastHostInfo(payload);
        break;
      case FrameType.receipt:
        await _handleReceipt(frame, payload);
        break;
      default:
        break;
    }
  }

  /// 서명된 전달 영수증을 플러딩하여, 전달된 텍스트의 사본을 아직 들고 있는 모든
  /// 릴레이가 이를 버릴 수 있게 한다("전파 삭제"). 텍스트처럼 durable하게
  /// 저장되므로, 이 정리 작업 자체도 결국 오래 오프라인이던 폰에까지 도달한다.
  Future<void> _broadcastReceipt(Uint8List msgId) async {
    final sig = await identity.sign(MeshNode.receiptSignedBytes(msgId));
    final payload = Uint8List(16 + 64)
      ..setRange(0, 16, msgId)
      ..setRange(16, 80, sig);
    await _dispatch(
      router.originate(
        type: FrameType.receipt,
        dst: PeerId.broadcast,
        ttl: MeshNode.durableTtl,
        payload: payload,
      ),
    );
  }

  /// 전달 영수증을 검증하고 적용한다: 유효한 서명은 메시지의 수신자만 만들 수
  /// 있으므로, 제3자가 영수증으로 검열할 수 없다.
  Future<void> _handleReceipt(Frame frame, Uint8List payload) async {
    if (payload.length < 80) return; // 잘못된 형식
    final msgId = Uint8List.fromList(payload.sublist(0, 16));
    final sig = Uint8List.fromList(payload.sublist(16, 80));
    final hex = MsgId.hex(msgId);
    if (_receipted.contains(hex)) return;
    final signer = _knownSigning[frame.src.hex];
    if (signer == null) return; // 검증 불가 → 계속 릴레이하고, 삭제하지 않는다
    if (!await Identity.verify(MeshNode.receiptSignedBytes(msgId), sig, signer)) {
      return; // 위조됨/손상됨
    }
    // 우리가 아직 메시지를 들고 있다면, 영수증은 반드시 그 수신자로부터 와야 한다.
    final held = store.frameFor(hex);
    if (held != null && held.dst != frame.src) return;
    _tombstone(hex);
  }

  /// 전달된 msgId를 묻는다(툼스톤): 저장된 사본을 버리고, 다시는 저장하거나
  /// 릴레이하거나 재요청(re-pull)하기를 거부한다.
  void _tombstone(String hex) {
    store.remove(hex);
    _receipted.add(hex);
    while (_receipted.length > MeshNode._receiptedCap) {
      _receipted.remove(_receipted.first);
    }
  }

  Future<void> _rebuildReceiptsImpl() async {
    for (final f in store.allFrames()) {
      if (f.type == FrameType.receipt) await _handleReceipt(f, f.payload);
    }
  }

  Future<void> _redeliverParkedImpl({PeerId? from}) async {
    for (final f in store.allFrames()) {
      if (f.dst != myId) continue;
      if (from != null && f.src != from) continue;
      await _deliverLocal(f);
    }
  }

  Future<void> _sendMessageAck(PeerId dst, Uint8List ackedMsgId) async {
    final payload = Uint8List(1 + 16)
      ..[0] = _AckKind.message
      ..setRange(1, 17, ackedMsgId);
    final kex = _knownKex[dst.hex];
    final flags = kex != null ? FrameFlags.encrypted : 0;
    final body = kex != null ? await crypto.encrypt(payload, kex) : payload;
    await _dispatch(
      router.originate(
        type: FrameType.ack,
        // ACK는 텍스트가 온 거리만큼, store-and-forward 홉을 포함해 되돌아갈 수
        // 있어야 한다.
        ttl: MeshNode.durableTtl,
        dst: dst,
        payload: body,
        flags: flags,
      ),
    );
  }

  Future<void> _handleAck(PeerId from, Uint8List payload) async {
    if (payload.isEmpty) return;
    final kind = payload[0];
    if (kind == _AckKind.message) {
      if (payload.length < 17) return; // 잘못된 형식: 무시
      final ackedId = Uint8List.fromList(payload.sublist(1, 17));
      final hex = MsgId.hex(ackedId);
      store.remove(hex);
      _awaitingAck.remove(hex); // 재전송 중단
      if (_confirmedText.add(hex)) {
        if (_confirmedText.length > MeshNode._deliveredIncomingCap) {
          _confirmedText.remove(_confirmedText.first);
        }
        bleLogSink?.call('MSG delivered ${hex.substring(0, 8)}');
        _events.add(DeliveryConfirmed(hex));
      }
    } else if (kind == _AckKind.file) {
      await _handleFileAckPayload(from, payload);
    }
  }

  /// 앱에 전달된 메시지 id의 경계가 있는(bounded) 기록(라우팅 seen-cache의 더
  /// 짧은 TTL을 넘어서는 중복 제거).
  void _rememberDelivered(String msgIdHex) {
    _deliveredIncoming.add(msgIdHex);
    while (_deliveredIncoming.length > MeshNode._deliveredIncomingCap) {
      _deliveredIncoming.remove(_deliveredIncoming.first);
    }
  }

  /// [_pendingLocalDelivery] 참고. 경계가 있음(bounded).
  void _markPendingLocalDelivery(String msgIdHex) {
    if (_deliveredIncoming.contains(msgIdHex)) return;
    if (_pendingLocalDelivery.add(msgIdHex)) {
      onPendingLocalChanged?.call(msgIdHex, true);
    }
    while (_pendingLocalDelivery.length > MeshNode._pendingLocalDeliveryCap) {
      final evicted = _pendingLocalDelivery.first;
      _pendingLocalDelivery.remove(evicted);
      onPendingLocalChanged?.call(evicted, false);
    }
  }

  void _clearPendingLocalDelivery(String msgIdHex) {
    if (_pendingLocalDelivery.remove(msgIdHex)) {
      onPendingLocalChanged?.call(msgIdHex, false);
    }
  }
}
