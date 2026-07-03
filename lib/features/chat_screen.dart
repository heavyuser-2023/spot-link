import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
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
                  Text(name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    nearby
                        ? (hops <= 1 ? '주변에 있음' : '주변 · $hops홉 경유')
                        : '오프라인 · 전달 대기',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
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
          const Divider(height: 1),
          SafeArea(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file),
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
                      decoration: const InputDecoration(
                        hintText: '메시지',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    icon: const Icon(Icons.send),
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

    return Align(
      alignment: _isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => _onTap(context),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: failed ? scheme.errorContainer : bg,
            borderRadius: BorderRadius.circular(16),
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
