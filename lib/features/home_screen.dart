import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../core/ble/mesh_transport.dart' show RadioStatus;
import 'chats_tab.dart';
import 'me_tab.dart';
import 'people_tab.dart';

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
    final c = context.read<MeshController>();
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
    final c = context.watch<MeshController>();
    final titles = ['채팅', '사람', '내 정보'];
    final tabs = const [ChatsTab(), PeopleTab(), MeTab()];

    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_index]),
        actions: [_ConnectionIndicator(count: c.linkCount, active: c.started)],
      ),
      body: Column(
        children: [
          if (!c.started) _BluetoothBanner(status: c.radioStatus),
          Expanded(child: IndexedStack(index: _index, children: tabs)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
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
            label: '사람',
          ),
          const NavigationDestination(
            icon: Icon(Icons.qr_code_outlined),
            selectedIcon: Icon(Icons.qr_code),
            label: '내 정보',
          ),
        ],
      ),
    );
  }
}

class _ConnectionIndicator extends StatelessWidget {
  final int count;
  final bool active;
  const _ConnectionIndicator({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    final connected = active && count > 0;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Tooltip(
        message: !active
            ? '블루투스 꺼짐 / 권한 없음'
            : connected
                ? '$count개 기기와 연결됨'
                : '주변 검색 중',
        child: Semantics(
          label: connected ? '$count개 기기 연결됨' : '연결 없음',
          child: Row(
            children: [
              Icon(
                active ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                size: 18,
                color: connected
                    ? Colors.greenAccent.shade400
                    : Theme.of(context).disabledColor,
              ),
              const SizedBox(width: 4),
              Text('$count', style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
      ),
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
      _ => '블루투스가 꺼져 있거나 권한이 없어 주변 사람을 찾을 수 없습니다.',
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
