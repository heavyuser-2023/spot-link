import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../app/mesh_controller.dart';
import 'ui_utils.dart';

class MeTab extends StatelessWidget {
  const MeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshController>();
    final hint = Theme.of(context).textTheme.bodySmall?.color;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 8),
        Center(
          child: CircleAvatar(
            radius: 36,
            backgroundColor: avatarColor(c.myId.hex),
            foregroundColor: Colors.white,
            child: Text(initialsOf(c.displayName),
                style: const TextStyle(fontSize: 28)),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: InkWell(
            onTap: () => _editName(context, c),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(c.displayName,
                        style: Theme.of(context).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.edit, size: 18, color: hint),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: c.myId.hex));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('ID를 복사했습니다')),
              );
            },
            icon: const Icon(Icons.copy, size: 14),
            label: Text('ID ${c.myId.short}',
                style: TextStyle(color: hint, fontSize: 12)),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Card(
            elevation: 0,
            color: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: QrImageView(
                data: c.myQrPayload,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            '친구가 이 코드를 스캔하면 안전하게 추가됩니다.\n키는 암호화되지 않은 채로 기기를 떠나지 않습니다.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: OutlinedButton.icon(
            onPressed: () => SharePlus.instance.share(ShareParams(
                text: c.myQrPayload, subject: 'SpotLink에서 저를 추가하세요')),
            icon: const Icon(Icons.share),
            label: const Text('초대 코드 공유'),
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.battery_saver),
            title: const Text('배터리 절약'),
            subtitle: const Text('스캔 주기를 늘려 배터리를 아낍니다 (검색이 느려짐).'),
            value: c.powerSaver,
            onChanged: (v) => context.read<MeshController>().setPowerSaver(v),
          ),
        ),
      ],
    );
  }

  Future<void> _editName(BuildContext context, MeshController c) async {
    final controller = TextEditingController(text: c.displayName);
    try {
      final name = await showDialog<String>(
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
      if (name != null && name.isNotEmpty) {
        await c.setDisplayName(name);
      }
    } finally {
      controller.dispose();
    }
  }
}
