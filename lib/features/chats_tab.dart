import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../data/models.dart';
import 'chat_screen.dart';
import 'scan_screen.dart';
import 'ui_utils.dart';

class ChatsTab extends StatelessWidget {
  /// Jumps to the People tab — the natural next step when there is nothing
  /// to chat about yet.
  final VoidCallback? onFindPeople;
  const ChatsTab({super.key, this.onFindPeople});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshController>();
    final convos = c.conversations();

    if (convos.isEmpty) {
      return _EmptyChats(onFindPeople: onFindPeople);
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: convos.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
      itemBuilder: (context, i) => _ConversationTile(summary: convos[i]),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final ConversationSummary summary;
  const _ConversationTile({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread = summary.unread > 0;
    final last = summary.lastMessage;

    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            backgroundColor: avatarColor(summary.peerHex),
            foregroundColor: Colors.white,
            child: Text(initialsOf(summary.displayName)),
          ),
          if (summary.nearby)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              summary.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight: unread ? FontWeight.bold : FontWeight.w500),
            ),
          ),
          if (summary.verified)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.verified, size: 15, color: Colors.blue),
            ),
          if (last != null) ...[
            const SizedBox(width: 6),
            Text(
              relativeTime(last.timestamp),
              style: theme.textTheme.labelSmall?.copyWith(
                color: unread ? theme.colorScheme.primary : theme.hintColor,
                fontWeight: unread ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              _preview(last),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: unread
                    ? theme.colorScheme.onSurface
                    : theme.hintColor,
              ),
            ),
          ),
          if (unread)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                summary.unread > 99 ? '99+' : '${summary.unread}',
                style: TextStyle(
                    color: theme.colorScheme.onPrimary, fontSize: 11),
              ),
            ),
        ],
      ),
      onTap: () =>
          pushWithController(context, ChatScreen(peerHex: summary.peerHex)),
    );
  }

  String _preview(ChatMessage? m) {
    if (m == null) return '대화를 시작해보세요';
    final prefix = m.direction == MsgDirection.outgoing ? '나: ' : '';
    if (m.kind == MsgKind.file) {
      return '$prefix📎 ${m.fileName ?? '파일'}';
    }
    return '$prefix${m.text ?? ''}';
  }
}

class _EmptyChats extends StatelessWidget {
  final VoidCallback? onFindPeople;
  const _EmptyChats({this.onFindPeople});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.forum_outlined,
                  size: 40, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 20),
            Text('아직 대화가 없어요',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '인터넷 없이, 주변 사람과 바로 대화할 수 있어요.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onFindPeople,
              icon: const Icon(Icons.people_alt_outlined),
              label: const Text('주변 사람 보기'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  pushWithController(context, const ScanScreen()),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('QR로 친구 추가'),
            ),
          ],
        ),
      ),
    );
  }
}
