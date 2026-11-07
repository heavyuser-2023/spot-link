part of 'mesh_controller.dart';

/// [MeshController]의 연락처, 스쳐간 친구(Encounter), 신원 및 QR 상호 인증 논스 관리.
mixin _MeshControllerContacts on _MeshControllerBase, _MeshControllerBackground {
  Future<void> _rememberAnnounced(ContactIdentity c, {String? avatar}) async {
    final existing = await db.contact(c.peerId.hex);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing == null) {
      final contact = Contact(
        peerHex: c.peerId.hex,
        signingPublicB64: b64(c.signingPublic),
        kexPublicB64: b64(c.kexPublic),
        displayName: c.displayName ?? c.peerId.short,
        // 논스 증명이 연락처보다 먼저 도착한 경우(스캔 직후 ANNOUNCE 전) —
        // 보류된 승격을 여기서 적용한다.
        verified: _pendingVerified.remove(c.peerId.hex),
        avatar: avatar,
        lastSeen: now,
      );
      await db.upsertContact(contact);
      replaceContact(contact);
    } else {
      // 검증되었거나 사용자가 이름을 바꾼 경우 그 이름을 유지하고; 그렇지 않으면
      // 알려진(announce된) 이름을 채택한다. nameLocked 가드가 없으면 피어의 다음
      // ANNOUNCE(~15초마다)가 미검증 연락처에 대한 사용자의 이름 변경을 조용히
      // 되돌렸다.
      var updated = existing;
      var changed = false;
      if (!existing.verified &&
          !existing.nameLocked &&
          c.displayName != null &&
          c.displayName!.isNotEmpty &&
          c.displayName != existing.displayName) {
        updated = updated.copyWith(displayName: c.displayName);
        changed = true;
      }
      // 아바타는 이름 잠금과 무관하게 상대가 알린 최신 레시피를 따른다 —
      // 본인의 자기표현이라 사용자가 덮어쓸 대상이 아니다.
      if (avatar != null && avatar != existing.avatar) {
        updated = updated.copyWith(avatar: avatar);
        changed = true;
      }
      if (changed) {
        updated = updated.copyWith(lastSeen: now);
        await db.upsertContact(updated);
        replaceContact(updated);
      } else if (now - existing.lastSeen > 60 * 1000) {
        // lastSeen 터치는 60초에 한 번이면 충분하다 — 100명 규모에서 매
        // announce마다 쓰면 SQLite에 초당 ~7회 쓰기가 영구히 돈다. 실시간
        // 프레즌스는 인메모리 lastSeenAt이 담당한다. 인메모리 사본도 갱신해야
        // 이 스로틀 조건이 다시 60초를 기다린다.
        await db.touchContact(c.peerId.hex, now);
        replaceContact(existing.copyWith(lastSeen: now));
      }
    }
  }

  @override
  Future<Contact> addContactFromBundle(Uint8List bundle,
      {String? name, bool verified = true, Uint8List? verifyNonce}) async {
    final c = ContactIdentity.fromBundle(bundle, displayName: name);
    node.addContact(c);
    final existing = await db.contact(c.peerId.hex);
    // 사용자가 이름을 바꾼 연락처는 QR 재스캔에도 이름을 유지한다.
    final nameLocked = existing?.nameLocked ?? false;
    final contact = Contact(
      peerHex: c.peerId.hex,
      signingPublicB64: b64(c.signingPublic),
      kexPublicB64: b64(c.kexPublic),
      displayName: nameLocked
          ? existing!.displayName
          : name ?? existing?.displayName ?? c.peerId.short,
      verified: verified,
      nameLocked: nameLocked,
      lastSeen: DateTime.now().millisecondsSinceEpoch,
      // upsertContact는 행 전체를 교체한다 — 실어 주지 않으면 QR 재스캔이
      // 사용자가 정해 둔 자동 메시지를 조용히 지운다.
      autoMessage: existing?.autoMessage,
    );
    await db.upsertContact(contact);
    replaceContact(contact);
    // 상호 인증: QR에 실려 온 논스를 되돌려 보내 "네 화면을 직접 봤다"를
    // 증명한다 — 상대 쪽에서도 내가 인증된 친구로 승격된다.
    if (verifyNonce != null) {
      unawaited(node.sendVerify(c.peerId, verifyNonce));
    }
    // 방금 QR로 검증했고 이미 링크가 살아 있다면 지금 바로 본딩을 유도한다 —
    // 다음 ANNOUNCE(15초)를 기다릴 이유가 없다.
    if (verified) unawaited(node.ensureBonded(contact.peerHex));
    notifyListeners();
    return contact;
  }

  /// 연락처를 삭제한다: 키, 대화 이력, 그리고 수신/발신한 파일 사본 전부. 차단이
  /// 아니다 — 근처의 피어는 다음 ANNOUNCE 때 다시 나타난다(새로운 미검증
  /// 연락처로서).
  @override
  Future<void> deleteContact(String peerHex) async {
    // 이 대화가 참조하는 파일을 최선의 노력으로 정리한다.
    for (final m in await db.messagesFor(peerHex)) {
      final path = m.filePath;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      transferProgress.remove(m.msgId);
    }
    await db.deleteMessagesFor(peerHex);
    await db.deleteReactionsFor(peerHex);
    await db.deleteEncountersFor(peerHex);
    encounterRev++;
    await db.deleteContact(peerHex);
    contactList.removeWhere((c) => c.peerHex == peerHex);
    conversationCache.remove(peerHex);
    lastMessages.remove(peerHex);
    unreadCounts.remove(peerHex);
    lastSeenAt.remove(peerHex);
    lastHopCount.remove(peerHex);
    rssiSmoothed.remove(peerHex);
    rssiSeenAt.remove(peerHex);
    if (_openPeer == peerHex) _openPeer = null;
    // 노드의 공개키(_knownKex)는 일부러 남겨둔다: 공개 자료라 지워서 얻는 것이
    // 없고, 상대가 근처에 있으면 어차피 다음 ANNOUNCE(≤15초)가 다시 알려준다.
    // 예전엔 여기서 키를 지웠는데, 링크가 살아 있는 채로 삭제하면 상대의
    // 암호화 프레임(재전송·릴레이 재인출)이 키 재학습보다 먼저 쏟아져
    // "No key to decrypt" 에러가 프레임 수만큼 도배됐다(2026-07-17 관찰).
    // 삭제는 차단이 아니다 — 삭제 다이얼로그 문구 그대로.
    _bumpRev();
    notifyListeners();
  }

  // ---- 스쳐간 친구 ----

  @override
  Future<List<Encounter>> encounters() => db.encounters();

  @override
  EncounterLocationPolicy get encounterLocationPolicy =>
      profile.encounterLocation;

  @override
  bool get encounterLocationEnabled => _encounterLocationEnabled;

  @override
  Future<void> setEncounterLocationEnabled(bool on) async {
    _encounterLocationEnabled = on;
    await EncounterSettings.setLocationEnabled(on);
    notifyListeners();
  }

  @override
  Future<void> clearEncounters() async {
    await db.clearEncounters();
    encounterRev++;
    notifyListeners();
  }

  @override
  Future<void> resolveEncounterPlaces() async {
    if (_resolvingPlaces) return;
    _resolvingPlaces = true;
    try {
      var changed = false;
      for (final e in await db.encountersMissingPlace()) {
        final place = await DeviceLocation.reverseGeocode(e.lat!, e.lng!);
        if (place == null) break; // 오프라인 — 다음에 다시 시도한다
        await db.setEncounterPlace(e.id, place);
        changed = true;
      }
      if (changed) {
        encounterRev++;
        notifyListeners();
      }
    } finally {
      _resolvingPlaces = false;
    }
  }

  @override
  Future<void> setAutoMessage(String peerHex, String? message) async {
    final existing = contactByHex(peerHex);
    if (existing == null) return;
    final updated = existing.withAutoMessage(message);
    await db.upsertContact(updated);
    replaceContact(updated);
    notifyListeners();
  }

  /// 만남에 붙일 위치. 플랫폼 정책([EncounterLocationPolicy])을 따른다 —
  /// Android는 "사용 중에만" 권한이라 앱 화면이 떠 있을 때만 받는다.
  Future<LocationFix?> _locateForEncounter() async {
    final policy = profile.encounterLocation;
    if (policy == EncounterLocationPolicy.never) return null;
    if (policy == EncounterLocationPolicy.foregroundOnly && !_foreground) {
      return null;
    }
    return DeviceLocation.current();
  }

  @override
  Future<void> renameContact(String peerHex, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final existing = contactByHex(peerHex);
    if (existing == null) return;
    // nameLocked는 announce 업데이트에 맞서 사용자의 선택을 고정한다.
    final updated = existing.copyWith(displayName: trimmed, nameLocked: true);
    await db.upsertContact(updated);
    replaceContact(updated);
    notifyListeners();
  }

  // ---- 신원(identity) ----

  @override
  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    displayName = trimmed;
    await identityStore.setDisplayName(trimmed);
    await node.updateDisplayName(trimmed);
    notifyListeners();
  }

  @override
  String? get myAvatar => _myAvatar;

  @override
  bool get avatarCustomized => _avatarCustomized;

  @override
  Future<void> setAvatarRecipe(String recipe) async {
    _myAvatar = recipe;
    _avatarCustomized = true; // 빌더 저장 = 커스텀 완료 → 넛지 영구 소멸
    await identityStore.setAvatar(recipe);
    await identityStore.setAvatarCustomized(true);
    await node.updateAvatar(recipe);
    _bumpRev();
    notifyListeners();
  }

  // ---- QR 페이로드(포맷은 QrPayload에 있음) + 상호 인증 논스 ----

  Uint8List _currentQrNonce() {
    final now = DateTime.now();
    _qrNonces.removeWhere(
        (e) => now.difference(e.$2) > _MeshControllerBase._qrNonceTtl);
    if (_qrNonces.isNotEmpty &&
        now.difference(_qrNonces.last.$2) < _MeshControllerBase._qrNonceRotate) {
      return _qrNonces.last.$1;
    }
    final rng = Random.secure();
    final n = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
    armQrNonce(n);
    return n;
  }

  /// 논스를 유효 목록에 등록한다. Android에서는 QR을 그리는 UI isolate가
  /// 논스를 만들고 브리지로 서비스(여기)에 등록한다 — verify 프레임은
  /// 서비스에 도착하기 때문이다.
  void armQrNonce(Uint8List nonce) {
    _qrNonces.add((nonce, DateTime.now()));
    while (_qrNonces.length > 4) {
      _qrNonces.removeAt(0);
    }
  }

  bool _validQrNonce(Uint8List n) {
    final now = DateTime.now();
    _qrNonces.removeWhere(
        (e) => now.difference(e.$2) > _MeshControllerBase._qrNonceTtl);
    return _qrNonces.any((e) => listEquals(e.$1, n));
  }

  @override
  String get myQrPayload => QrPayload.encode(identity.publicBundle, displayName,
      nonce: _currentQrNonce());
}
