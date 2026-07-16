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
          // 남아 있던 텍스트 포커스를 해제해, 키보드가 이동한 탭의 콘텐츠를
          // 가리지 않도록 한다.
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

/// 메시를 한눈에: 앱 바에 표시되는 색상 알약("메시 2" / "검색 중" /
/// "꺼짐"). 탭하면 세부 정보와 빠른 설정이 담긴 상태 시트가 열린다 —
/// "지금 연결돼 있나?"에 답해 주는 분명한 한 곳이다.
class _MeshStatusChip extends StatelessWidget {
  final MeshFrontend controller;
  const _MeshStatusChip({required this.controller});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = controller.started;
    // 원시 링크가 아니라 기기 수를 보여 준다: 양방향으로 연결된 피어는 링크가
    // 2개지만 기기는 1개이고, 친구 한 명에 "메시 2"라고 뜨면 친구 둘로 읽힌다.
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
      // 상태 변화는 툭 끊기지 않고 부드럽게 흐르며(색상 크로스페이드), 점은
      // 활발히 검색하는 동안 숨 쉬듯 움직인다 — 칩이 살아 있는 느낌을 준다.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        // 고정 높이: 제약이 느슨한 호스트(macOS 앱 바)에서는 알약이 주어진
        // 공간을 채우려 부풀어 올랐다 — 칩은 칩으로 남아 있어야 한다.
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

/// 상태 칩 뒤에 있는 세부 시트: 링크 수, 주변 사람, 중계 보관함, 배터리 절약
/// 토글 — "내 메시는 지금 어떤가"를 확인하는 허브다.
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

/// 내비게이션 아이콘 위에 겹쳐 표시되는 작은 안 읽음 개수 배지.
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
