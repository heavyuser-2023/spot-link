part of 'chat_screen.dart';

sealed class _Item {}

class _DateItem extends _Item {
  final String label;
  _DateItem(this.label);
}

class _MsgItem extends _Item {
  final ChatMessage message;
  _MsgItem(this.message);
}

class _DateChip extends StatelessWidget {
  final String label;
  const _DateChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final MeshFrontend controller;
  const _Bubble({required this.message, required this.controller});

  bool get _isMe => message.direction == MsgDirection.outgoing;

  /// 한동안 전달 확인(✓✓)이 안 된 발신 메시지: 여전히 "sent"(링크에 넘겼지만
  /// 수신 확인이 없음) 또는 "queued"(경로 없음) 상태다. 경고와 원탭 재전송을
  /// 함께 노출해, 메시지가 사용자도 모르게 조용히 도착 실패하는 일이 없게 한다.
  static const _undeliveredAfterMs = 90 * 1000;
  bool get _undeliveredWarn {
    if (!_isMe) return false;
    if (message.status != MsgStatus.sent &&
        message.status != MsgStatus.queued) {
      return false;
    }
    return DateTime.now().millisecondsSinceEpoch - message.timestamp >
        _undeliveredAfterMs;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = _isMe ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = _isMe ? scheme.onPrimary : scheme.onSurface;
    final failed = message.status == MsgStatus.failed;

    // 메신저 스타일의 비대칭 모서리: 보낸 사람 쪽을 가리키는 모서리는 뾰족하게,
    // 나머지는 둥글게.
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(_isMe ? 18 : 5),
      bottomRight: Radius.circular(_isMe ? 5 : 18),
    );

    final reactions = controller.reactionsOf(message.msgId);

    final bubble = Align(
      alignment: _isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => _onTap(context),
        onLongPress: () => _showMenu(context),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: failed ? scheme.errorContainer : bg,
            borderRadius: radius,
          ),
          child: Column(
            crossAxisAlignment:
                _isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (message.kind == MsgKind.text)
                Text(message.text ?? '',
                    style: TextStyle(color: failed ? scheme.onErrorContainer : fg))
              else
                _fileContent(context, failed ? scheme.onErrorContainer : fg),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_timeLabel(context),
                      style: TextStyle(
                          color: (failed ? scheme.onErrorContainer : fg)
                              .withValues(alpha: 0.7),
                          fontSize: 11)),
                  if (_isMe) ...[
                    const SizedBox(width: 4),
                    _statusIcon(context, fg, scheme),
                  ],
                ],
              ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                      _isMe ? context.s.chatTapRetry : context.s.chatReceiveInterrupted,
                      style: TextStyle(
                          color: scheme.onErrorContainer, fontSize: 11)),
                ),
              // 오래 전달 안 됨(✓✓ 없음): 놓칠 수 없게 표시하고 원탭 재전송을
              // 제공한다. 더 차분한 "queued" 안내보다 우선한다.
              if (!failed && _undeliveredWarn)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 13, color: scheme.error),
                      const SizedBox(width: 3),
                      Text(context.s.chatUndelivered,
                          style: TextStyle(
                              color: scheme.error,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              if (!failed &&
                  !_undeliveredWarn &&
                  message.status == MsgStatus.queued)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(context.s.chatQueuedHint,
                      style: TextStyle(
                          color: fg.withValues(alpha: 0.7), fontSize: 11)),
                ),
            ],
          ),
        ),
      ),
    );

    if (reactions.isEmpty) return bubble;
    // 슬랙처럼 말풍선 밖 아래에 리액션 칩을 단다 — 말풍선 색과 분리된
    // 중립 배경이라 어느 방향이든 동일한 문법으로 읽힌다.
    return Column(
      crossAxisAlignment:
          _isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        bubble,
        Padding(
          padding: const EdgeInsets.only(top: 1, bottom: 3),
          child: _reactionChips(context, reactions),
        ),
      ],
    );
  }

  /// 이모지별로 묶은 리액션 칩(슬랙 스타일): 이모지 + 개수, 내가 누른 칩은
  /// 시드색 테두리로 강조. 탭하면 내 리액션 토글.
  Widget _reactionChips(BuildContext context, List<Reaction> reactions) {
    final scheme = Theme.of(context).colorScheme;
    final byEmoji = <String, List<Reaction>>{};
    for (final r in reactions) {
      (byEmoji[r.emoji] ??= []).add(r);
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final e in byEmoji.entries)
          _reactionChip(
              context, scheme, e.key, e.value.length,
              mine: e.value.any((r) => r.fromMe)),
      ],
    );
  }

  Widget _reactionChip(BuildContext context, ColorScheme scheme, String emoji,
      int count,
      {required bool mine}) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () =>
          controller.toggleReaction(message.peerHex, message.msgId, emoji),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: mine
              ? scheme.primaryContainer.withValues(alpha: 0.55)
              : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: mine ? scheme.primary : scheme.outlineVariant,
            width: mine ? 1.2 : 1,
          ),
        ),
        child: Text(
          '$emoji $count',
          style: TextStyle(
            fontSize: 13,
            color: mine ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
            fontWeight: mine ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 말풍선 시간 라벨. 수신 텍스트는 봉투에 보낸 사람의 전송 시각을 담고 있다.
  /// 이 시각이 도착 시각과 유의미하게 다르면(>1분 — 즉 메시지가 한동안
  /// store-and-forward를 거친 경우) 둘 다 표시해, 수신자가 작성 시점과 도착
  /// 시점을 구분할 수 있게 한다.
  String _timeLabel(BuildContext context) {
    final sent = message.sentTs;
    if (_isMe || sent == null) return clockTime(message.timestamp);
    // 보낸 사람 시계가 우리보다 앞선 경우(시계 오차): "도착보다 늦게 전송"
    // 이라는 라벨은 말이 안 되므로 — 도착 시각만 표시하도록 대체한다.
    if (sent > message.timestamp) return clockTime(message.timestamp);
    if (message.timestamp - sent < 60 * 1000) {
      return clockTime(message.timestamp);
    }
    return context.s.chatTimeSentArrived(
        clockTime(sent), clockTime(message.timestamp));
  }

  void _onTap(BuildContext context) {
    if (message.status == MsgStatus.failed || _undeliveredWarn) {
      if (message.kind == MsgKind.text) {
        controller.retryText(message);
      } else if (message.direction == MsgDirection.outgoing) {
        controller.retryFile(message);
      }
    } else if (message.kind == MsgKind.file &&
        message.direction == MsgDirection.outgoing &&
        message.status == MsgStatus.sending) {
      _confirmCancel(context);
    } else if (message.kind == MsgKind.file && message.filePath != null) {
      _view(context);
    }
  }

  bool get _isImage => (lookupMimeType(
          message.fileName ?? message.filePath ?? '') ??
          '')
      .startsWith('image/');

  bool get _isMedia {
    final mime =
        lookupMimeType(message.fileName ?? message.filePath ?? '') ?? '';
    return mime.startsWith('image/') || mime.startsWith('video/');
  }

  /// 이미지는 앱 내 뷰어로 열고, 그 외에는 모두 시스템 앱으로 연다.
  void _view(BuildContext context) {
    if (_isImage) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              _ImageViewerPage(message: message, controller: controller),
        ),
      );
    } else {
      controller.openFile(message);
    }
  }

  /// 길게 눌러 여는 관리 메뉴: 파일은 보기/저장/공유/삭제, 텍스트는
  /// 복사/삭제.
  void _showMenu(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    final isText = message.kind == MsgKind.text;
    final hasFile = message.kind == MsgKind.file && message.filePath != null;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 슬랙식 퀵 리액션 행: 자주 쓰는 6개 + 전체 피커. 재난 맥락의
            // 🆗(무사함)를 팔레트에 포함한다.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Row(
                children: [
                  for (final e in const ['👍', '❤️', '😂', '😮', '😢', '🆗'])
                    Expanded(
                      child: _quickEmoji(context, sheet, e),
                    ),
                  Expanded(
                    child: IconButton(
                      tooltip: context.s.chatAllEmojis,
                      icon: Icon(Icons.add_reaction_outlined,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      onPressed: () {
                        Navigator.pop(sheet);
                        _openEmojiPicker(context);
                      },
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (isText)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: Text(context.s.chatCopy),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: message.text ?? ''));
                  Navigator.pop(sheet);
                  messenger.showSnackBar(
                      SnackBar(content: Text(context.s.chatCopied)));
                },
              ),
            if (hasFile) ...[
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: Text(context.s.chatView),
                onTap: () {
                  Navigator.pop(sheet);
                  _view(context);
                },
              ),
              if (_isMedia)
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: Text(context.s.chatSaveToGallery),
                  onTap: () async {
                    Navigator.pop(sheet);
                    final savedMsg = context.s.chatSavedToGallery;
                    final failedMsg = context.s.chatSaveToGalleryFailed;
                    final ok = await controller.saveToGallery(message);
                    messenger.showSnackBar(SnackBar(
                        content: Text(ok ? savedMsg : failedMsg)));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: Text(context.s.chatShareSaveToFiles),
                onTap: () {
                  Navigator.pop(sheet);
                  controller.shareFile(message);
                },
              ),
            ],
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text(context.s.commonDelete,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(sheet);
                _confirmDelete(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 퀵 팔레트의 이모지 하나 — 이미 내가 누른 이모지는 틴트 원으로 표시.
  Widget _quickEmoji(BuildContext context, BuildContext sheet, String emoji) {
    final mine = controller
        .reactionsOf(message.msgId)
        .any((r) => r.fromMe && r.emoji == emoji);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: () {
        Navigator.pop(sheet);
        controller.toggleReaction(message.peerHex, message.msgId, emoji);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: mine
            ? BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              )
            : null,
        child: Text(emoji,
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 24)),
      ),
    );
  }

  /// 전체 이모지 피커(유니코드 전체) — 선택 즉시 리액션 토글.
  void _openEmojiPicker(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SizedBox(
        height: MediaQuery.of(sheet).size.height * 0.45,
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            Navigator.pop(sheet);
            controller.toggleReaction(
                message.peerHex, message.msgId, emoji.emoji);
          },
          config: Config(
            checkPlatformCompatibility: true,
            emojiViewConfig: EmojiViewConfig(
              backgroundColor: scheme.surface,
              emojiSizeMax: 28,
            ),
            categoryViewConfig: CategoryViewConfig(
              backgroundColor: scheme.surface,
              indicatorColor: scheme.primary,
              iconColorSelected: scheme.primary,
            ),
            bottomActionBarConfig:
                const BottomActionBarConfig(enabled: false),
            searchViewConfig: SearchViewConfig(
              backgroundColor: scheme.surface,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final isFile = message.kind == MsgKind.file;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.s.chatDeleteTitle),
        content: Text(isFile
            ? context.s.chatDeleteFileContent(message.fileName ?? context.s.chatFileFallback)
            : context.s.chatDeleteTextContent),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.s.commonCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.s.commonDelete)),
        ],
      ),
    );
    if (ok == true) await controller.deleteMessage(message);
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.s.chatCancelSendTitle),
        content: Text(context.s.chatCancelSendContent(
            message.fileName ?? context.s.chatFileFallback)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.s.chatKeepSending)),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.s.chatCancelSend)),
        ],
      ),
    );
    if (ok == true) await controller.cancelFile(message);
  }

  Widget _statusIcon(BuildContext context, Color fg, ColorScheme scheme) {
    final (icon, label, color) = switch (message.status) {
      MsgStatus.sending => (Icons.schedule, context.s.chatStatusSending, fg),
      MsgStatus.sent => (Icons.check, context.s.chatStatusSent, fg),
      MsgStatus.delivered => (Icons.done_all, context.s.chatStatusDelivered, fg),
      MsgStatus.failed => (Icons.error_outline, context.s.chatStatusFailed, scheme.error),
      MsgStatus.queued => (Icons.schedule_send, context.s.chatStatusQueued, fg),
      _ => (Icons.check, context.s.chatStatusSent, fg),
    };
    return Semantics(
      label: label,
      child: Icon(icon, size: 13, color: color.withValues(alpha: 0.85)),
    );
  }

  Widget _fileContent(BuildContext context, Color fg) {
    final progress = controller.transferProgress[message.msgId];
    final transferring = progress != null && progress < 1;
    final canOpen = message.filePath != null;
    final Widget body;
    // 받은/보낸 이미지는 인라인 썸네일로 렌더링된다 — 탭하면 뷰어로 연다.
    if (canOpen && _isImage) {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: Image.file(
            File(message.filePath!),
            cacheWidth: 720,
            fit: BoxFit.cover,
            errorBuilder: (_, e, s) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image_outlined, color: fg),
                const SizedBox(width: 8),
                Text(message.fileName ?? context.s.chatImageFallback,
                    style: TextStyle(color: fg)),
              ],
            ),
          ),
        ),
      );
    } else {
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(canOpen ? Icons.file_open : Icons.insert_drive_file, color: fg),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.fileName ?? context.s.chatFileFallback,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                Text(
                  canOpen
                      ? context.s.chatFileSizeTapOpen(humanSize(message.fileSize ?? 0))
                      : humanSize(message.fileSize ?? 0),
                  style:
                      TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      );
    }
    // 방향·경로·진행을 한 줄로: "↑ 보내는 중 42% · ⌾ Wi-Fi 직결".
    // 정렬·색만으로는 파일 카드의 방향이 소실된다(양쪽 카드가 동일하게
    // 생겨서 "내가 보내는 중인지 받는 중인지"를 카드만 보고 알 수 없었다).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        body,
        const SizedBox(height: 5),
        _transferMeta(context, fg, progress, transferring),
      ],
    );
  }

  /// 파일 말풍선의 전송 메타 행: 방향(보냄/받음) + 진행률 + 실제 경로 칩.
  Widget _transferMeta(
      BuildContext context, Color fg, double? progress, bool transferring) {
    final lane = message.lane ?? controller.laneOf(message.msgId);
    final dim = fg.withValues(alpha: 0.8);
    final percent = ((progress ?? 0) * 100).round();
    final verb = transferring
        ? (_isMe
            ? context.s.chatTransferSending(percent)
            : context.s.chatTransferReceiving(percent))
        : (_isMe ? context.s.chatSentFile : context.s.chatReceivedFile);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isMe ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: 13,
              color: dim,
            ),
            const SizedBox(width: 3),
            Text(verb,
                style: TextStyle(
                    color: dim, fontSize: 11, fontWeight: FontWeight.w600)),
            if (lane != null) ...[
              Text('  ·  ',
                  style: TextStyle(
                      color: fg.withValues(alpha: 0.5), fontSize: 11)),
              Icon(lane == 'wifi' ? Icons.wifi : Icons.bluetooth,
                  size: 12, color: dim),
              const SizedBox(width: 3),
              // 'Wi-Fi 다이렉트': 실제 기술명이자 국내 기기 UI(삼성 설정 등)에서
              // 통용되는 용어 — "공유기 없이 기기 간 직접"의 뉘앙스를 유지한다.
              Text(lane == 'wifi' ? context.s.chatLaneWifi : context.s.chatLaneBle,
                  style: TextStyle(color: dim, fontSize: 11)),
            ],
          ],
        ),
        if (transferring)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SizedBox(
              width: 180,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: progress, minHeight: 4),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 일관된 빈 상태 언어: 밋밋한 힌트-그레이 글리프가 아니라 은은하게
            // 틴트된 원. 자물쇠는 종단 간 암호화를 나타낸다.
            CircleAvatar(
              radius: 36,
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.lock_outline,
                  size: 34, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Text(context.s.chatEncryptedTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(context.s.chatEncryptedSubtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// 핀치 줌과 빠른 저장/공유 액션을 갖춘 전체 화면 이미지 뷰어.
class _ImageViewerPage extends StatelessWidget {
  final ChatMessage message;
  final MeshFrontend controller;
  const _ImageViewerPage({required this.message, required this.controller});

  @override
  Widget build(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(message.fileName ?? context.s.chatImageFallback,
            style: const TextStyle(fontSize: 16),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: context.s.chatSaveToGallery,
            onPressed: () async {
              final savedMsg = context.s.chatSavedToGallery;
              final failedMsg = context.s.chatSaveToGalleryFailed;
              final ok = await controller.saveToGallery(message);
              messenger.showSnackBar(
                  SnackBar(content: Text(ok ? savedMsg : failedMsg)));
            },
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: context.s.chatShare,
            onPressed: () => controller.shareFile(message),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 6,
          // 디코딩 크기를 제한: 12MP 사진은 전체 해상도로 디코딩하면 ~48MB
          // 비트맵이 된다 — 폰 화면이 보여줄 수 있는 것보다 한참 크다. 2048px면
          // RAM은 10분의 1로 쓰면서 확대해도 선명하다.
          child: Image.file(File(message.filePath!), cacheWidth: 2048),
        ),
      ),
    );
  }
}
