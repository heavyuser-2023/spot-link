part of 'mesh_controller.dart';

/// [MeshController]의 대화/메시지 상태 및 파일 송수신/재시도/보류 처리.
mixin _MeshControllerTransfer
    on _MeshControllerBase, _MeshControllerBackground, _MeshControllerContacts {
  Future<ChatMessage?> _messageIn(String peerHex, String msgId) async {
    for (final m in await db.messagesFor(peerHex)) {
      if (m.msgId == msgId) return m;
    }
    return null;
  }

  /// 브리지를 위한 Id 기반 명령 변형: 원격 UI는 평범한 ChatMessage 사본을 들고
  /// 있으므로, 명령은 (peerHex, msgId)로 포트를 건너오고 여기서 권위 있는 DB
  /// 행에 다시 연결된다.
  Future<void> retryTextById(String peerHex, String msgId) async {
    final m = await _messageIn(peerHex, msgId);
    if (m != null) await retryText(m);
  }

  Future<void> retryFileById(String peerHex, String msgId) async {
    final m = await _messageIn(peerHex, msgId);
    if (m != null) await retryFile(m);
  }

  Future<void> deleteMessageById(String peerHex, String msgId) async {
    final m = await _messageIn(peerHex, msgId);
    if (m != null) await deleteMessage(m);
  }

  Future<void> cancelFileById(String msgId) async {
    node.cancelSend(msgId);
    transferProgress.remove(msgId);
    await _applyStatus(msgId, MsgStatus.failed);
  }

  /// 메시지에 전달 상태 변화를 적용한다. 아주 작은 전송은 발신 말풍선이
  /// 영속화되기도 전에 확인(ACK)될 수 있다 — 상태를 기억해 두고 삽입 시
  /// [_persistAndCache]가 이를 적용하게 한다.
  Future<void> _applyStatus(String msgId, MsgStatus status) async {
    final updated = await db.updateStatusByMsgId(msgId, status);
    if (updated == 0) _pendingStatus[msgId] = status;
    _patchStatus(msgId, status);
    _bumpRev();
    notifyListeners();
  }

  @override
  Future<void> openConversation(String peerHex) async {
    _openPeer = peerHex;
    unreadCounts.remove(peerHex);
    NotificationService.cancelFor(peerHex);
    if (!conversationCache.containsKey(peerHex)) {
      // await *이전에* 플레이스홀더 리스트를 설치하여 DB 로드 중에(_persistAndCache
      // 를 통해) 도착하는 메시지를 포착한 뒤, 중복 없이 DB 스냅샷과 병합한다.
      final live = <ChatMessage>[];
      conversationCache[peerHex] = live;
      final loaded = await db.messagesFor(peerHex, limit: 200);
      final loadedIds = loaded.map((m) => m.id).whereType<int>().toSet();
      final extras =
          live.where((m) => m.id == null || !loadedIds.contains(m.id));
      final merged = [...loaded, ...extras]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      conversationCache[peerHex] = merged;
    }
    final reactions = await db.reactionsFor(peerHex);
    // await 사이에 위젯 테스트/화면 전환이 컨트롤러를 dispose했을 수 있다.
    if (_disposed) return;
    reactionCache
      ..clear()
      ..addAll(reactions);
    notifyListeners();
  }

  @override
  Future<void> toggleReaction(
      String peerHex, String msgId, String emoji) async {
    final existing = reactionsOf(msgId)
        .any((r) => r.fromMe && r.emoji == emoji);
    if (existing) {
      await db.removeReaction(msgId, emoji, true);
      reactionCache[msgId]
          ?.removeWhere((r) => r.fromMe && r.emoji == emoji);
    } else {
      await db.addReaction(peerHex, msgId, emoji, true);
      (reactionCache[msgId] ??= [])
          .add(Reaction(msgId: msgId, emoji: emoji, fromMe: true));
    }
    _bumpRev();
    notifyListeners();
    await node.sendReaction(PeerId.fromHex(peerHex), msgId, emoji,
        remove: existing);
  }

  @override
  void closeConversation() {
    _openPeer = null;
  }

  @override
  Future<void> sendText(String peerHex, String text) async {
    final peer = PeerId.fromHex(peerHex);
    final msgId = await node.sendText(peer, text);
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      peerHex: peerHex,
      msgId: msgId ?? 'local-$now',
      direction: MsgDirection.outgoing,
      kind: MsgKind.text,
      text: text,
      status: msgId == null ? MsgStatus.failed : MsgStatus.sent,
      timestamp: now,
    );
    await _persistAndCache(msg);
  }

  @override
  Future<void> retryText(ChatMessage failed) async {
    if (failed.text == null) return;
    final peer = PeerId.fromHex(failed.peerHex);
    // 이전 시도를 취소하여, 그것의 늦은 store-and-forward 사본이 이 새 전송(새
    // msgId)과 함께 이중 전달되지 못하게 한다. 봉투(envelope)에는 원래(ORIGINAL)
    // 작성 시각을 유지한다 — 재전송은 새 메시지가 아니며, 수신자의 "HH:mm 전송"은
    // 그것이 작성된 시점을 반영해야 한다.
    node.forgetText(failed.msgId);
    final msgId = await node.sendText(peer, failed.text!,
        sentAt: DateTime.fromMillisecondsSinceEpoch(failed.timestamp));
    if (msgId == null) {
      reportError('Still unable to send — no route yet');
      return;
    }
    if (failed.id != null) {
      await db.updateMessageDelivery(failed.id!, msgId, MsgStatus.sent);
    }
    _patchMessage(failed.peerHex, failed.msgId,
        newMsgId: msgId, status: MsgStatus.sent);
    _bumpRev();
    notifyListeners();
  }

  @override
  Future<void> sendFile(String peerHex,
      {required Uint8List bytes,
      required String name,
      required String mime}) async {
    // 바이트를 디스크에 한 번 내려놓은 뒤 디스크 기반으로 전송하여, 전송이 결코
    // 페이로드를 RAM에 고정하지 않게 한다. (실제 경로를 가진 호출자는
    // [sendFilePath]를 사용해 바이트 왕복을 아예 건너뛰어야 한다.)
    final path = await _saveLocalCopy(
        'out-${DateTime.now().millisecondsSinceEpoch}', name, bytes);
    if (path == null) {
      reportError(systemS.errFileCopyFailed);
      return;
    }
    await sendFilePath(peerHex, path: path, name: name, mime: mime);
  }

  @override
  Future<void> sendFilePath(String peerHex,
      {required String path,
      required String name,
      required String mime}) async {
    final peer = PeerId.fromHex(peerHex);
    final now = DateTime.now().millisecondsSinceEpoch;
    // Picker/outbox 경로는 OS가 비울 수 있는 캐시에 있다 — 내구성 있는 사본을
    // 유지하고(네이티브 File.copy: 스트리밍, RAM 비용 없음) 그로부터 전송하여,
    // 말풍선을 계속 열 수 있고 실패한 전송을 계속 재시도할 수 있게 한다. 소스가
    // 이미 우리 자신의 sent/ 사본인 경우(sendFile 바이트 경로)에는 건너뛴다.
    if (!path.contains('${Platform.pathSeparator}sent${Platform.pathSeparator}')) {
      final copy = await _copyToSent(now.toString(), name, path);
      if (copy != null) path = copy;
    }
    final size = await File(path).length();
    // META 프레임이 나가는 즉시 반환한다; 청크는 백그라운드에서 스트리밍되며
    // FileProgress / DeliveryConfirmed / FileFailed 이벤트로 결과를 보고한다.
    // 말풍선은 즉시 나타나야 한다.
    final tid =
        await node.sendFilePath(peer, path: path, name: name, mime: mime);
    final msgId = tid ?? 'local-$now';
    final msg = ChatMessage(
      peerHex: peerHex,
      msgId: msgId,
      direction: MsgDirection.outgoing,
      kind: MsgKind.file,
      fileName: name,
      filePath: path,
      fileSize: size,
      status: tid == null ? MsgStatus.failed : MsgStatus.sending,
      timestamp: now,
    );
    await _persistAndCache(msg);
  }

  /// sent/ 아래의 내구성 있는 사본을 위한 목적지 경로, 또는 폴더를 준비할 수
  /// 없을 때 null. 사본은 어디서나 최선의 노력이다: null은 단지 "로컬 사본 없이
  /// 전송"을 뜻한다.
  Future<String?> _sentPathFor(String tid, String name) async {
    try {
      final dir = await AppPaths.dataDir();
      final folder = Directory(p.join(dir.path, 'sent'));
      if (!await folder.exists()) await folder.create(recursive: true);
      final safeName = name.replaceAll(RegExp(r'[/\\]'), '_');
      return p.join(folder.path, '${tid}_$safeName');
    } catch (_) {
      return null;
    }
  }

  Future<String?> _saveLocalCopy(
      String tid, String name, Uint8List bytes) async {
    final path = await _sentPathFor(tid, name);
    if (path == null) return null;
    try {
      await File(path).writeAsBytes(bytes);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// [_saveLocalCopy]와 같지만 기존 파일로부터 — 네이티브 복사, RAM 없음.
  Future<String?> _copyToSent(String tid, String name, String srcPath) async {
    final path = await _sentPathFor(tid, name);
    if (path == null) return null;
    try {
      await File(srcPath).copy(path);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 진행 중인 발신 전송을 취소한다(청크 스트림을 멈춘다).
  @override
  Future<void> cancelFile(ChatMessage msg) async {
    node.cancelSend(msg.msgId);
    transferProgress.remove(msg.msgId);
    await _applyStatus(msg.msgId, MsgStatus.failed);
  }

  /// 실패한 파일 전송을, 전송 시점에 저장해 둔 로컬 사본으로부터 다시 보낸다.
  @override
  Future<bool> retryFile(ChatMessage failed, {bool quiet = false}) async {
    final path = failed.filePath;
    if (path == null || !await File(path).exists()) {
      if (!quiet) reportError(systemS.errFileGoneRetry);
      return false;
    }
    final name = failed.fileName ?? p.basename(path);
    final tid = await node.sendFilePath(
      PeerId.fromHex(failed.peerHex),
      path: path,
      name: name,
      mime: lookupMimeType(name) ?? 'application/octet-stream',
    );
    if (tid == null) {
      if (!quiet) reportError('Still unable to send — no route yet');
      return false;
    }
    if (failed.id != null) {
      await db.updateMessageDelivery(failed.id!, tid, MsgStatus.sending);
    }
    _patchMessage(failed.peerHex, failed.msgId,
        newMsgId: tid, status: MsgStatus.sending);
    _bumpRev();
    notifyListeners();
    return true;
  }

  /// 보류된 파일들을 자동 재전송한다. 실패(경로 소실 직후 등)하면 조용히
  /// 큐에 되돌려 다음 1홉 announce 때 다시 시도한다.
  Future<void> _flushDeferredFiles(String peerHex) async {
    final ids = _deferredFiles.remove(peerHex);
    if (ids == null || ids.isEmpty) return;
    for (final msgId in ids) {
      final m = await _messageIn(peerHex, msgId);
      if (m == null) continue; // 사용자가 지웠음 — 그대로 잊는다
      final ok = await retryFile(m, quiet: true);
      if (!ok) (_deferredFiles[peerHex] ??= {}).add(msgId);
    }
  }

  Future<void> _onText(PeerId from, String text, String msgId,
      {DateTime? sentAt}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = ChatMessage(
      peerHex: from.hex,
      msgId: msgId,
      direction: MsgDirection.incoming,
      kind: MsgKind.text,
      text: text,
      status: MsgStatus.received,
      timestamp: now, // 도착 시각(이 기기의 시계)
      sentTs: sentAt?.millisecondsSinceEpoch,
    );
    await _persistAndCache(msg, incoming: true);
    _notifyIncoming(from, text);
  }

  /// 수신 전송이 방금 시작됐다(META 수신): 파일이 완료될 때까지 조용히 기다리는
  /// 대신 곧바로 진행률 말풍선을 보여준다.
  Future<void> _onFileOffered(PeerId from, FileMeta meta) async {
    final msg = ChatMessage(
      peerHex: from.hex,
      msgId: meta.transferIdHex,
      direction: MsgDirection.incoming,
      kind: MsgKind.file,
      fileName: meta.name,
      fileSize: meta.fileSize,
      status: MsgStatus.receiving,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistAndCache(msg, incoming: true);
  }

  Future<void> _onFileReceived(
      PeerId from, FileMeta meta, String partPath) async {
    final dir = await AppPaths.dataDir();
    final folder = Directory(p.join(dir.path, 'received'));
    if (!await folder.exists()) await folder.create(recursive: true);
    final safeName = meta.name.replaceAll(RegExp(r'[/\\]'), '_');
    final path = p.join(folder.path, '${meta.transferIdHex}_$safeName');
    // 검증된 페이로드는 이미 디스크에 있다(수신자의 part 파일) — 바이트를 다시
    // 쓰는 대신 제자리로 옮긴다(같은 볼륨에서는 rename; 볼륨을 넘나들 때는 네이티브
    // 복사로 폴백한다).
    try {
      await File(partPath).rename(path);
    } on FileSystemException {
      await File(partPath).copy(path);
      try {
        await File(partPath).delete();
      } catch (_) {}
    }

    transferProgress.remove(meta.transferIdHex);
    _notifyIncoming(from, '📎 ${meta.name}');

    // 보통은 _onFileOffered가 만든 "receiving" 플레이스홀더가 존재한다 — 그것을
    // 제자리에서 완료 처리한다.
    final updated = await db.updateFileByMsgId(
        meta.transferIdHex, path, MsgStatus.received);
    if (updated > 0) {
      _patchFile(meta.transferIdHex, path, MsgStatus.received);
      _bumpRev();
      notifyListeners();
      return;
    }

    // 플레이스홀더가 없다(엣지 케이스) — 완성된 메시지를 직접 삽입한다.
    final msg = ChatMessage(
      peerHex: from.hex,
      msgId: meta.transferIdHex,
      direction: MsgDirection.incoming,
      kind: MsgKind.file,
      fileName: meta.name,
      filePath: path,
      fileSize: meta.fileSize,
      status: MsgStatus.received,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistAndCache(msg, incoming: true);
  }

  Future<void> _persistAndCache(ChatMessage msg, {bool incoming = false}) async {
    // 상태 이벤트(예: 아주 작은 파일의 완료 ACK)가 이 삽입보다 먼저 도착했을 수
    // 있다 — 잃어버리는 대신 지금 적용한다.
    final pending = _pendingStatus.remove(msg.msgId);
    if (pending != null) msg = msg.copyWith(status: pending);
    final id = await db.insertMessage(msg);
    final stored = msg.withId(id);
    conversationCache[msg.peerHex]?.add(stored);
    lastMessages[msg.peerHex] = stored;
    if (incoming && msg.peerHex != _openPeer) {
      unreadCounts[msg.peerHex] = (unreadCounts[msg.peerHex] ?? 0) + 1;
    }
    _bumpRev();
    notifyListeners();
  }

  /// 이 기기에서 메시지 말풍선 하나를 삭제한다(DB + 메모리). 파일 메시지의 경우
  /// 저장된 파일도 디스크에서 지운다. 순수하게 로컬 동작이다 — 피어의 사본은
  /// 건드리지 않는다.
  @override
  Future<void> deleteMessage(ChatMessage msg) async {
    await db.deleteMessage(msg.msgId);
    final path = msg.filePath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {} // 이미 없어졌다 — 괜찮다
    }
    conversationCache[msg.peerHex]?.removeWhere((m) => m.msgId == msg.msgId);
    if (lastMessages[msg.peerHex]?.msgId == msg.msgId) {
      final rest = conversationCache[msg.peerHex];
      if (rest != null && rest.isNotEmpty) {
        lastMessages[msg.peerHex] = rest.last;
      } else {
        lastMessages.remove(msg.peerHex);
      }
    }
    _bumpRev();
    notifyListeners();
  }

  /// [_patchStatus]와 같지만 저장된 파일 경로도 함께 붙인다(수신 전송이 제자리에서
  /// 완료되는 경우).
  void _patchFile(String msgId, String filePath, MsgStatus status) {
    for (final list in conversationCache.values) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].msgId == msgId) {
          list[i] = list[i].copyWith(filePath: filePath, status: status);
        }
      }
    }
    for (final entry in lastMessages.entries.toList()) {
      if (entry.value.msgId == msgId) {
        lastMessages[entry.key] =
            entry.value.copyWith(filePath: filePath, status: status);
      }
    }
  }

  void _patchStatus(String msgId, MsgStatus status) {
    for (final list in conversationCache.values) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].msgId == msgId) {
          list[i] = list[i].copyWith(status: status);
        }
      }
    }
    for (final entry in lastMessages.entries.toList()) {
      if (entry.value.msgId == msgId) {
        lastMessages[entry.key] = entry.value.copyWith(status: status);
      }
    }
  }

  void _patchMessage(String peerHex, String oldMsgId,
      {required String newMsgId, required MsgStatus status}) {
    final list = conversationCache[peerHex];
    if (list != null) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].msgId == oldMsgId) {
          list[i] = list[i].copyWith(msgId: newMsgId, status: status);
        }
      }
    }
    // 받은편지함 요약을 동기화 상태로 유지한다(이는 lastMessages를 읽는다);
    // 그러지 않으면 그 행이 예전의 실패한 msgId에 영원히 갇힌다.
    final last = lastMessages[peerHex];
    if (last != null && last.msgId == oldMsgId) {
      lastMessages[peerHex] = last.copyWith(msgId: newMsgId, status: status);
    }
  }
}
