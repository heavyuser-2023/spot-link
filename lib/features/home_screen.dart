import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../core/ble/mesh_transport.dart' show RadioStatus;
import 'chats_tab.dart';
import 'me_tab.dart';
import 'people_tab.dart';
import 'ui_utils.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  StreamSubscription<String>? _errorSub;
  bool _wired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;
    final c = context.read<MeshFrontend>();
    _errorSub = c.errorEvents.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
        ));
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    final titles = ['채팅', '친구', '내 정보'];
    final tabs = [
      ChatsTab(onFindPeople: () => setState(() => _index = 1)),
      PeopleTab(active: _index == 1),
      const MeTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_index]),
        actions: [
          _MeshStatusChip(controller: c),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          if (!c.started) _BluetoothBanner(status: c.radioStatus),
          Expanded(child: IndexedStack(index: _index, children: tabs)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          // Drop any lingering text focus so the keyboard never covers the
          // destination tab's content.
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() => _index = i);
        },
        destinations: [
          NavigationDestination(
            icon: _UnreadBadge(
              count: c.totalUnread,
              child: const Icon(Icons.forum_outlined),
            ),
            selectedIcon: _UnreadBadge(
              count: c.totalUnread,
              child: const Icon(Icons.forum),
            ),
            label: '채팅',
          ),
          const NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: '친구',
          ),
          const NavigationDestination(
            icon: Icon(Icons.account_circle_outlined),
            selectedIcon: Icon(Icons.account_circle),
            label: '내 정보',
          ),
        ],
      ),
    );
  }
}

/// The mesh at a glance: colored pill in the app bar ("메시 2" / "검색 중" /
/// "꺼짐"). Tapping opens a status sheet with details and quick settings —
/// one obvious place to answer "지금 연결돼 있나?".
class _MeshStatusChip extends StatelessWidget {
  final MeshFrontend controller;
  const _MeshStatusChip({required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = controller.started;
    // Show DEVICES, not raw links: a peer linked both ways is 2 links but 1
    // device, and "메시 2" for a single friend reads as two friends.
    final count = controller.peerCount;
    final connected = active && count > 0;

    final (bg, fg, dot, label) = !active
        ? (
            scheme.errorContainer,
            scheme.onErrorContainer,
            scheme.error,
            '꺼짐'
          )
        : connected
            ? (
                const Color(0xFFDCF5DF),
                const Color(0xFF1B5E20),
                const Color(0xFF2E7D32),
                '메시 $count'
              )
            : (
                scheme.surfaceContainerHighest,
                scheme.onSurfaceVariant,
                scheme.outline,
                '검색 중'
              );

    return Semantics(
      label: connected ? '$count개 기기 연결됨' : (active ? '주변 검색 중' : '연결 없음'),
      button: true,
      // State changes GLIDE (color cross-fade) instead of snapping, and the
      // dot breathes while actively searching — the chip feels alive.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        // Fixed height: in loosely-constrained hosts (macOS app bar) the pill
        // ballooned to fill whatever it was given — a chip must stay a chip.
        height: 30,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(15),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: () => _showStatusSheet(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  active && !connected
                      ? PulsingDot(color: dot, size: 8)
                      : Container(
                          width: 8,
                          height: 8,
                          decoration:
                              BoxDecoration(color: dot, shape: BoxShape.circle),
                        ),
                  const SizedBox(width: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: Text(label,
                        key: ValueKey(label),
                        style: TextStyle(
                            color: fg,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showStatusSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: controller,
        child: const _StatusSheet(),
      ),
    );
  }
}

/// Detail sheet behind the status chip: link count, nearby people, relay
/// mailbox and the battery-saver toggle — the "how is my mesh doing" hub.
class _StatusSheet extends StatelessWidget {
  const _StatusSheet();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('메시 상태', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _StatusStat(
                    icon: Icons.bluetooth_connected,
                    value: '${c.peerCount}',
                    label: '연결된 기기',
                    color: c.peerCount > 0 ? scheme.primary : scheme.outline,
                  ),
                ),
                Expanded(
                  child: _StatusStat(
                    icon: Icons.people_alt_outlined,
                    value: '${c.nearbyCount}',
                    label: '주변 친구',
                    color: c.nearbyCount > 0 ? scheme.primary : scheme.outline,
                  ),
                ),
                Expanded(
                  child: _StatusStat(
                    icon: Icons.move_to_inbox_outlined,
                    value: '${c.relayStoreCount}',
                    label: '중계 대기',
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.battery_saver),
              title: const Text('배터리 절약'),
              value: c.powerSaver,
              onChanged: (v) => c.setPowerSaver(v),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusStat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  const _StatusStat(
      {required this.icon,
      required this.value,
      required this.label,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color),
        const SizedBox(height: 4),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _BluetoothBanner extends StatelessWidget {
  final RadioStatus status;
  const _BluetoothBanner({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = switch (status) {
      RadioStatus.poweredOff =>
        '블루투스가 꺼져 있습니다. 블루투스를 켜면 자동으로 주변 검색을 시작합니다.',
      RadioStatus.unauthorized =>
        '블루투스 권한이 없습니다. 설정 > SpotLink에서 블루투스를 허용해 주세요.',
      _ => '블루투스가 꺼져 있거나 권한이 없어 주변 친구를 찾을 수 없습니다.',
    };
    return MaterialBanner(
      backgroundColor: scheme.errorContainer,
      leading: Icon(Icons.bluetooth_disabled, color: scheme.onErrorContainer),
      content: Text(
        message,
        style: TextStyle(color: scheme.onErrorContainer),
      ),
      actions: [
        TextButton(
          onPressed: () => openAppSettings(),
          child: const Text('설정 열기'),
        ),
      ],
    );
  }
}

/// A small unread-count badge overlaid on a nav icon.
class _UnreadBadge extends StatelessWidget {
  final int count;
  final Widget child;
  const _UnreadBadge({required this.count, required this.child});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;
    return Badge(
      label: Text(count > 99 ? '99+' : '$count'),
      child: child,
    );
  }
}
