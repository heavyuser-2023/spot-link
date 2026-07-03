import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../core/ble/mesh_transport.dart' show bleLogSink;
import '../core/model/peer_id.dart';
import '../data/models.dart';
import 'ui_utils.dart';

class ChatScreen extends StatefulWidget {
  final String peerHex;
  const ChatScreen({super.key, required this.peerHex});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastCount = 0;
  MeshController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MeshController>().openConversation(widget.peerHex);
      _jumpToBottom();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = context.read<MeshController>();
  }

  @override
  void dispose() {
    // Use the captured reference: context is defunct during dispose.
    _controller?.closeConversation();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    try {
      await context.read<MeshController>().sendText(widget.peerHex, text);
      bleLogSink?.call('chat send ok (${text.length} chars)');
    } catch (e, st) {
      bleLogSink?.call('chat send failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('전송 실패: $e')),
        );
      }
    }
    _animateToBottom();
  }

  Future<void> _attach() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    final bytes =
        f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) return;
    if (!mounted) return;
    final mime = lookupMimeType(f.name) ?? 'application/octet-stream';
    await context.read<MeshController>().sendFile(
          widget.peerHex,
          bytes: bytes,
          name: f.name,
          mime: mime,
        );
    _animateToBottom();
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.maxScrollExtent - _scroll.offset < 240;
  }

  void _jumpToBottom() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  void _animateToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshController>();
    final contact = c.contactByHex(widget.peerHex);
    // Fall back to the PEER's short id (not our own) when they aren't a contact.
    final name = contact?.displayName ?? PeerId.fromHex(widget.peerHex).short;
    final messages = c.conversation(widget.peerHex);
    final nearby = c.isNearby(widget.peerHex);
    final hops = c.hopsTo(widget.peerHex);

    // Auto-scroll when a new message arrives and we're already near the bottom.
    if (messages.length != _lastCount) {
      final grew = messages.length > _lastCount;
      _lastCount = messages.length;
      if (grew && _nearBottom) _animateToBottom();
    }

    final items = _buildItems(messages);

    final presence = nearby
        ? (hops <= 1 ? '주변에 있음' : '주변 · $hops홉 경유')
        : '오프라인 · 전달 대기';

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showPeerSheet(context, c, name, presence, nearby),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 17,
                  backgroundColor: avatarColor(widget.peerHex),
                  foregroundColor: Colors.white,
                  child: Text(initialsOf(name),
                      style: const TextStyle(fontSize: 14)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          if (contact?.verified ?? false)
                            const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(Icons.verified,
                                  size: 15, color: Colors.blue),
                            ),
                        ],
                      ),
                      Text(
                        presence,
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: nearby
                                      ? const Color(0xFF2E7D32)
                                      : Theme.of(context).hintColor,
                                ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const _EmptyChat()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final item = items[i];
                      if (item is _DateItem) {
                        return _DateChip(label: item.label);
                      }
                      return _Bubble(
                        message: (item as _MsgItem).message,
                        controller: c,
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: '파일 첨부',
                    onPressed: _attach,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: '메시지',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: '보내기',
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Peer detail sheet from the app bar: identity at a glance (인증 여부,
  /// 메시 거리, ID 복사) without leaving the conversation.
  void _showPeerSheet(BuildContext context, MeshController c, String name,
      String presence, bool nearby) {
    final contact = c.contactByHex(widget.peerHex);
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: avatarColor(widget.peerHex),
                foregroundColor: Colors.white,
                child: Text(initialsOf(name),
                    style: const TextStyle(fontSize: 26)),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(name,
                        style: Theme.of(context).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (contact?.verified ?? false)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child:
                          Icon(Icons.verified, size: 20, color: Colors.blue),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(presence,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: nearby
                            ? const Color(0xFF2E7D32)
                            : Theme.of(context).hintColor,
                      )),
              const SizedBox(height: 12),
              if (!(contact?.verified ?? false))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '아직 QR로 인증하지 않은 상대입니다.\n만나면 서로의 QR을 스캔해 신원을 확인하세요.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                      text: PeerId.fromHex(widget.peerHex).hex));
                  Navigator.pop(sheetContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('ID를 복사했습니다')),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: Text('ID ${PeerId.fromHex(widget.peerHex).short} 복사'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<_Item> _buildItems(List<ChatMessage> messages) {
    final items = <_Item>[];
    int? lastDay;
    for (final m in messages) {
      if (lastDay == null || !sameDay(lastDay, m.timestamp)) {
        items.add(_DateItem(dayLabel(m.timestamp)));
        lastDay = m.timestamp;
      }
      items.add(_MsgItem(m));
    }
    return items;
  }
}

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
  final MeshController controller;
  const _Bubble({required this.message, required this.controller});

  bool get _isMe => message.direction == MsgDirection.outgoing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = _isMe ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = _isMe ? scheme.onPrimary : scheme.onSurface;
    final failed = message.status == MsgStatus.failed;

    // Messenger-style asymmetric corners: the corner pointing at the sender
    // is tight, the rest round.
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(_isMe ? 18 : 5),
      bottomRight: Radius.circular(_isMe ? 5 : 18),
    );

    return Align(
      alignment: _isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => _onTap(context),
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
                  Text(clockTime(message.timestamp),
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
                      _isMe ? '탭하여 다시 시도' : '수신이 중단되었습니다',
                      style: TextStyle(
                          color: scheme.onErrorContainer, fontSize: 11)),
                ),
              if (message.status == MsgStatus.queued)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('상대를 만나면 자동 전달',
                      style: TextStyle(
                          color: fg.withValues(alpha: 0.7), fontSize: 11)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _onTap(BuildContext context) {
    if (message.status == MsgStatus.failed) {
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
      controller.openFile(message);
    }
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('전송 취소'),
        content: Text('${message.fileName ?? '파일'} 전송을 취소할까요?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('계속 보내기')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('전송 취소')),
        ],
      ),
    );
    if (ok == true) await controller.cancelFile(message);
  }

  Widget _statusIcon(BuildContext context, Color fg, ColorScheme scheme) {
    final (icon, label, color) = switch (message.status) {
      MsgStatus.sending => (Icons.schedule, '보내는 중', fg),
      MsgStatus.sent => (Icons.check, '전송됨', fg),
      MsgStatus.delivered => (Icons.done_all, '전달됨', fg),
      MsgStatus.failed => (Icons.error_outline, '실패', scheme.error),
      MsgStatus.queued => (Icons.schedule_send, '전달 대기', fg),
      _ => (Icons.check, '전송됨', fg),
    };
    return Semantics(
      label: label,
      child: Icon(icon, size: 13, color: color.withValues(alpha: 0.85)),
    );
  }

  Widget _fileContent(BuildContext context, Color fg) {
    final progress = controller.transferProgress[message.msgId];
    final canOpen = message.filePath != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(canOpen ? Icons.file_open : Icons.insert_drive_file, color: fg),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message.fileName ?? '파일',
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
              Text(
                canOpen
                    ? '${humanSize(message.fileSize ?? 0)} · 탭하여 열기'
                    : humanSize(message.fileSize ?? 0),
                style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 11),
              ),
              if (progress != null && progress < 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SizedBox(
                    width: 140,
                    child: LinearProgressIndicator(value: progress),
                  ),
                ),
            ],
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline,
                size: 40, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            const Text('종단 간 암호화된 대화입니다.',
                textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text('첫 인사를 건네보세요 👋',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
