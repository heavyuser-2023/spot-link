import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../data/models.dart';
import 'chat_screen.dart';
import 'scan_screen.dart';
import 'ui_utils.dart';

class PeopleTab extends StatelessWidget {
  const PeopleTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshController>();
    int byName(Contact a, Contact b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    // 주변(지금 연결 가능)과 나머지 연락처를 분리: "지금 대화 가능한 사람"이
    // 항상 맨 위 섹션에 모여 있어야 동선이 짧다.
    final nearby = c.contacts.where((x) => c.isNearby(x.peerHex)).toList()
      ..sort((a, b) {
        final ha = c.hopsTo(a.peerHex);
        final hb = c.hopsTo(b.peerHex);
        if (ha != hb) return ha - hb; // direct first
        return byName(a, b);
      });
    final offline = c.contacts.where((x) => !c.isNearby(x.peerHex)).toList()
      ..sort(byName);

    return Scaffold(
      body: c.contacts.isEmpty
          ? const _EmptyPeople()
          : ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 88),
              children: [
                if (nearby.isNotEmpty) ...[
                  _SectionHeader(
                      label: '주변', count: nearby.length, live: true),
                  ...nearby.map((x) => _PersonTile(contact: x)),
                ],
                if (offline.isNotEmpty) ...[
                  _SectionHeader(label: '연락처', count: offline.length),
                  ...offline.map((x) => _PersonTile(contact: x)),
                ],
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => pushWithController(context, const ScanScreen()),
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('QR로 추가'),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool live;
  const _SectionHeader(
      {required this.label, required this.count, this.live = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Row(
        children: [
          if (live) ...[
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                  color: Color(0xFF2E7D32), shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            '$label · $count',
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  final Contact contact;
  const _PersonTile({required this.contact});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshController>();
    final nearby = c.isNearby(contact.peerHex);
    final hops = c.hopsTo(contact.peerHex);
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            backgroundColor: avatarColor(contact.peerHex),
            foregroundColor: Colors.white,
            child: Text(initialsOf(contact.displayName)),
          ),
          if (nearby)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  // Green = direct radio range, amber = reachable via relays.
                  color: hops <= 1 ? Colors.green : Colors.amber,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Theme.of(context).colorScheme.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(contact.displayName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (contact.verified)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.verified, size: 16, color: Colors.blue),
            ),
        ],
      ),
      subtitle: Text(
        '${contact.peerId.short} · '
        '${nearby ? (hops <= 1 ? "주변에 있음" : "주변 · $hops홉 경유") : "오프라인"}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.more_vert),
        onPressed: () => _showActions(context, c),
      ),
      onTap: () =>
          pushWithController(context, ChatScreen(peerHex: contact.peerHex)),
    );
  }

  void _showActions(BuildContext context, MeshController c) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: avatarColor(contact.peerHex),
                foregroundColor: Colors.white,
                child: Text(initialsOf(contact.displayName)),
              ),
              title: Text(contact.displayName),
              subtitle: Text('ID ${contact.peerId.short}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('대화하기'),
              onTap: () {
                Navigator.pop(sheetContext);
                pushWithController(
                    context, ChatScreen(peerHex: contact.peerHex));
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('이름 변경'),
              onTap: () {
                Navigator.pop(sheetContext);
                _rename(context, c);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text('삭제',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmDelete(context, c);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, MeshController c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${contact.displayName} 삭제'),
        content: const Text(
            '대화 내용과 주고받은 파일이 함께 삭제됩니다.\n\n'
            '차단 기능이 아니므로, 상대가 주변에 있으면 새 연락처로 다시 '
            '나타날 수 있습니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true) await c.deleteContact(contact.peerHex);
  }

  Future<void> _rename(BuildContext context, MeshController c) async {
    final controller = TextEditingController(text: contact.displayName);
    try {
      final newName = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('이름 변경'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 32,
            decoration: const InputDecoration(labelText: '표시 이름'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('취소')),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('저장'),
            ),
          ],
        ),
      );
      if (newName != null && newName.isNotEmpty) {
        await c.renameContact(contact.peerHex, newName);
      }
    } finally {
      controller.dispose();
    }
  }
}

class _EmptyPeople extends StatelessWidget {
  const _EmptyPeople();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshController>();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.groups_2_outlined, size: 64),
            const SizedBox(height: 16),
            Text('아직 아무도 없어요',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '주변의 SpotLink 사용자가 자동으로 나타납니다.\n'
              '친구의 QR 코드를 스캔해 안전하게 추가하고 인증하세요.',
              textAlign: TextAlign.center,
            ),
            if (!c.started) ...[
              const SizedBox(height: 16),
              Text('블루투스가 꺼져 있거나 권한이 없습니다.',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}
