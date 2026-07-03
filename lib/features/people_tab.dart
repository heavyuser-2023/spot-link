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
    final contacts = [...c.contacts]..sort((a, b) {
        final an = c.isNearby(a.peerHex) ? 0 : 1;
        final bn = c.isNearby(b.peerHex) ? 0 : 1;
        if (an != bn) return an - bn;
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });
    final nearby = c.nearbyCount;

    return Scaffold(
      body: contacts.isEmpty
          ? const _EmptyPeople()
          : Column(
              children: [
                if (nearby > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('주변에 $nearby명',
                          style: Theme.of(context).textTheme.labelLarge),
                    ),
                  ),
                Expanded(
                  child: ListView.separated(
                    itemCount: contacts.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 72),
                    itemBuilder: (context, i) =>
                        _PersonTile(contact: contacts[i]),
                  ),
                ),
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

class _PersonTile extends StatelessWidget {
  final Contact contact;
  const _PersonTile({required this.contact});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshController>();
    final nearby = c.isNearby(contact.peerHex);
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
                  color: Colors.green,
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
        '${contact.peerId.short} · ${nearby ? "주변에 있음" : "오프라인"}',
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
          ],
        ),
      ),
    );
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
