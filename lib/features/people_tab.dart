import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../data/models.dart';
import 'add_friend_fab.dart';
import 'chat_screen.dart';
import 'radar_screen.dart';
import 'scan_screen.dart';
import 'ui_utils.dart';

class PeopleTab extends StatefulWidget {
  /// True while this tab is the visible one. Flipping false→true replays the
  /// FAB pop-in animation (the tab lives in an IndexedStack, so it isn't
  /// rebuilt on every switch).
  final bool active;
  const PeopleTab({super.key, this.active = true});

  @override
  State<PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends State<PeopleTab> {
  /// True while the list is actively scrolling (drag or fling). Drives the
  /// QR edge tab's tuck-away: content gets the space while moving, the tab
  /// glides back the moment the list settles.
  bool _scrolling = false;

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollStartNotification && !_scrolling) {
      setState(() => _scrolling = true);
    } else if (n is ScrollEndNotification && _scrolling) {
      setState(() => _scrolling = false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
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

    // The QR-add affordance is an Instagram-style tab docked flush to the
    // RIGHT EDGE (not a floating pill) — hence a Stack, not a Scaffold FAB.
    return Stack(
      children: [
        Positioned.fill(
          child: c.contacts.isEmpty
              ? const _EmptyPeople()
              : NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 96),
                    children: [
                      if (nearby.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: _ProximityRadar(peers: nearby),
                        ),
                        _SectionHeader(
                          label: '주변',
                          count: nearby.length,
                          live: true,
                        ),
                        ...nearby.map((x) => _PersonTile(contact: x)),
                      ],
                      if (offline.isNotEmpty) ...[
                        _SectionHeader(label: '연락처', count: offline.length),
                        ...offline.map((x) => _PersonTile(contact: x)),
                      ],
                    ],
                  ),
                ),
        ),
        Positioned(
          right: 0,
          bottom: 88,
          child: QrEdgeButton(
            active: widget.active,
            retracted: _scrolling,
            onPressed: () => pushWithController(context, const ScanScreen()),
          ),
        ),
      ],
    );
  }
}

/// 소나(레이더) 뷰: 나를 중심으로 한 동심원 위에 주변 사람을 배치한다.
/// 신호가 강할수록(가까울수록) 안쪽 링, 멀티홉 상대는 최외곽 점선 링.
/// 아바타를 탭하면 바로 대화가 열린다 — "누가 얼마나 가까이 있나"를
/// 목록을 읽지 않고 한눈에 보는 화면.
class _ProximityRadar extends StatefulWidget {
  final List<Contact> peers;
  const _ProximityRadar({required this.peers});

  static const double _height = 264;
  static const _ringFractions = [0.30, 0.53, 0.76, 0.98];

  @override
  State<_ProximityRadar> createState() => _ProximityRadarState();
}

class _ProximityRadarState extends State<_ProximityRadar>
    with SingleTickerProviderStateMixin {
  /// Slow sonar sweep — one revolution every 6s. Painting is cheap (a single
  /// sweep-gradient arc), and the motion sells "지금 실제로 훑고 있다".
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  static const double _height = _ProximityRadar._height;
  static const _ringFractions = _ProximityRadar._ringFractions;
  List<Contact> get peers => widget.peers;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    final scheme = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      // 사람이 많아지면 카드가 좁다: 탭하면 핀치 줌·이동이 되는 전체화면
      // 레이더로 확장된다.
      child: InkWell(
        onTap: () => pushWithController(context, const RadarScreen()),
        child: SizedBox(
          height: _height,
          child: LayoutBuilder(
            builder: (context, box) {
              final center = Offset(box.maxWidth / 2, _height / 2);
              final maxR = math.min(box.maxWidth, _height) / 2 - 30;

              return Stack(
                children: [
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _sweep,
                      builder: (context, _) => CustomPaint(
                        painter: RadarPainter(
                          center: center,
                          radii: [for (final f in _ringFractions) maxR * f],
                          ringColor: scheme.outlineVariant,
                          fillColor: scheme.primary,
                          sweep: _sweep.value * 2 * math.pi,
                        ),
                      ),
                    ),
                  ),
                  // 나 (중심)
                  Positioned(
                    left: center.dx - 18,
                    top: center.dy - 18,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2.5),
                      ),
                      child: Icon(
                        Icons.person,
                        size: 20,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                  for (var i = 0; i < peers.length; i++)
                    _radarAvatar(context, c, peers[i], i, center, maxR),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Icon(
                      Icons.open_in_full,
                      size: 16,
                      color: scheme.outline,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 6,
                    child: Text(
                      '가까울수록 중앙에 표시됩니다',
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: scheme.outline),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _radarAvatar(
    BuildContext context,
    MeshFrontend c,
    Contact peer,
    int index,
    Offset center,
    double maxR,
  ) {
    final bucket = proximityBucket(
      c.rssiOf(peer.peerHex),
      c.hopsTo(peer.peerHex),
    );
    final radius = maxR * _ringFractions[bucket.ring];
    // 고정 해시 + 골든앵글 분산: 위치가 안정적이면서 서로 겹치지 않게.
    var hash = 0;
    for (final u in peer.peerHex.codeUnits) {
      hash = (hash * 31 + u) & 0x7fffffff;
    }
    final angle = (hash % 360) * math.pi / 180 + index * 2.399;
    final pos =
        center +
        Offset(math.cos(angle) * radius, math.sin(angle) * radius * 0.82);

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      left: pos.dx - 30,
      top: pos.dy - 22,
      width: 60,
      child: GestureDetector(
        onTap: () =>
            pushWithController(context, ChatScreen(peerHex: peer.peerHex)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
              child: CircleAvatar(
                radius: 17,
                backgroundColor: avatarColor(peer.peerHex),
                foregroundColor: Colors.white,
                child: Text(
                  initialsOf(peer.displayName),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
            Text(
              peer.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool live;
  const _SectionHeader({
    required this.label,
    required this.count,
    this.live = false,
  });

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
                color: Color(0xFF2E7D32),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            '$label · $count',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
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
    final c = context.watch<MeshFrontend>();
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
              // Green = direct radio range, amber = reachable via relays.
              // Pulsing: presence is live, and the motion says so.
              child: PulsingDot(
                color: hops <= 1 ? Colors.green : Colors.amber,
                size: 14,
                borderColor: Theme.of(context).colorScheme.surface,
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              contact.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
        '${nearby ? proximityBucket(c.rssiOf(contact.peerHex), hops).label : "오프라인"}',
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

  void _showActions(BuildContext context, MeshFrontend c) {
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
                  context,
                  ChatScreen(peerHex: contact.peerHex),
                );
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
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '삭제',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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

  Future<void> _confirmDelete(BuildContext context, MeshFrontend c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${contact.displayName} 삭제'),
        content: const Text(
          '대화 내용과 주고받은 파일이 함께 삭제됩니다.\n\n'
          '차단 기능이 아니므로, 상대가 주변에 있으면 새 연락처로 다시 '
          '나타날 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
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

  Future<void> _rename(BuildContext context, MeshFrontend c) async {
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
              child: const Text('취소'),
            ),
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
    final c = context.watch<MeshFrontend>();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.groups_2_outlined, size: 64),
            const SizedBox(height: 16),
            Text('아직 아무도 없어요', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '주변의 SpotLink 사용자가 자동으로 나타납니다.\n'
              '친구의 QR 코드를 스캔해 안전하게 추가하고 인증하세요.',
              textAlign: TextAlign.center,
            ),
            if (!c.started) ...[
              const SizedBox(height: 16),
              Text(
                '블루투스가 꺼져 있거나 권한이 없습니다.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
