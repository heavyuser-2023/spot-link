import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../data/models.dart';
import 'chat_screen.dart';
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
  final _scroll = ScrollController();
  // 0 = at top (full extended FAB) … 1 = scrolled (collapsed to icon).
  double _collapse = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(PeopleTab old) {
    super.didUpdateWidget(old);
    // Became the active tab: the FAB's own AnimatedScale replays via its key.
    if (!old.active && widget.active) setState(() {});
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Collapse over the first 60px of scroll — like Instagram's compose FAB.
    final next = (_scroll.offset / 60).clamp(0.0, 1.0);
    if ((next - _collapse).abs() > 0.01) setState(() => _collapse = next);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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

    return Scaffold(
      body: c.contacts.isEmpty
          ? const _EmptyPeople()
          : ListView(
              controller: _scroll,
              padding: const EdgeInsets.only(top: 4, bottom: 96),
              children: [
                if (nearby.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: _ProximityRadar(peers: nearby),
                  ),
                  _SectionHeader(label: '주변', count: nearby.length, live: true),
                  ...nearby.map((x) => _PersonTile(contact: x)),
                ],
                if (offline.isNotEmpty) ...[
                  _SectionHeader(label: '연락처', count: offline.length),
                  ...offline.map((x) => _PersonTile(contact: x)),
                ],
              ],
            ),
      floatingActionButton: _AddFriendFab(
        active: widget.active,
        collapse: _collapse,
        onPressed: () => pushWithController(context, const ScanScreen()),
      ),
    );
  }
}

/// Instagram-style compose FAB: pops in slightly oversized then settles when
/// the tab opens, and shrinks from a labelled pill to a compact icon as the
/// list scrolls.
class _AddFriendFab extends StatefulWidget {
  final bool active;
  final double collapse; // 0 = full pill, 1 = icon only
  final VoidCallback onPressed;
  const _AddFriendFab({
    required this.active,
    required this.collapse,
    required this.onPressed,
  });

  @override
  State<_AddFriendFab> createState() => _AddFriendFabState();
}

class _AddFriendFabState extends State<_AddFriendFab>
    with SingleTickerProviderStateMixin {
  // Entrance choreography matching the request / Instagram compose FAB:
  //   grow a bit larger → hold briefly → settle to normal.
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  late final Animation<double> _entryScale = TweenSequence<double>([
    // 0–22%: pop up to 1.18× (조금 크게)
    TweenSequenceItem(
      tween: Tween(
        begin: 0.6,
        end: 1.18,
      ).chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 22,
    ),
    // 22–58%: hold at 1.18× (잠깐 있다)
    TweenSequenceItem(tween: ConstantTween(1.18), weight: 36),
    // 58–100%: settle to 1.0× (작아지고)
    TweenSequenceItem(
      tween: Tween(
        begin: 1.18,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 42,
    ),
  ]).animate(_entry);

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _entry.forward();
    } else {
      _entry.value = 1.0; // already settled when built off-screen
    }
  }

  @override
  void didUpdateWidget(_AddFriendFab old) {
    super.didUpdateWidget(old);
    // Became the active tab: replay the entrance. No key change (that would
    // trigger Scaffold's FAB cross-fade and briefly show two buttons).
    if (!old.active && widget.active) _entry.forward(from: 0);
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Scroll shrink: labelled pill → compact icon, plus an overall scale-down
    // (스크롤하면 좀더 작아지는).
    final t = widget.collapse;
    final showLabel = t < 0.5;

    return AnimatedBuilder(
      animation: _entryScale,
      builder: (context, child) {
        return Transform.scale(
          scale: _entryScale.value * (1 - 0.16 * t),
          child: child,
        );
      },
      child: Material(
        color: scheme.primary,
        elevation: 3,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
            height: 56,
            padding: EdgeInsets.symmetric(horizontal: showLabel ? 20 : 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.qr_code_scanner, color: scheme.onPrimary),
                // Collapse the label to zero width as we scroll.
                ClipRect(
                  child: AnimatedAlign(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOut,
                    alignment: Alignment.centerLeft,
                    widthFactor: showLabel ? 1.0 : 0.0,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Text(
                        'QR로 추가',
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 소나(레이더) 뷰: 나를 중심으로 한 동심원 위에 주변 사람을 배치한다.
/// 신호가 강할수록(가까울수록) 안쪽 링, 멀티홉 상대는 최외곽 점선 링.
/// 아바타를 탭하면 바로 대화가 열린다 — "누가 얼마나 가까이 있나"를
/// 목록을 읽지 않고 한눈에 보는 화면.
class _ProximityRadar extends StatelessWidget {
  final List<Contact> peers;
  const _ProximityRadar({required this.peers});

  static const double _height = 264;
  static const _ringFractions = [0.30, 0.53, 0.76, 0.98];

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    final scheme = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: _height,
        child: LayoutBuilder(
          builder: (context, box) {
            final center = Offset(box.maxWidth / 2, _height / 2);
            final maxR = math.min(box.maxWidth, _height) / 2 - 30;

            return Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RadarPainter(
                      center: center,
                      radii: [for (final f in _ringFractions) maxR * f],
                      ringColor: scheme.outlineVariant,
                      fillColor: scheme.primary,
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

class _RadarPainter extends CustomPainter {
  final Offset center;
  final List<double> radii;
  final Color ringColor;
  final Color fillColor;
  _RadarPainter({
    required this.center,
    required this.radii,
    required this.ringColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 은은한 중심 발광: "내 주변" 공간감.
    canvas.drawCircle(
      center,
      radii.last,
      Paint()
        ..shader = RadialGradient(
          colors: [
            fillColor.withValues(alpha: 0.10),
            fillColor.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radii.last)),
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < radii.length; i++) {
      stroke.color = ringColor.withValues(
        alpha: i == radii.length - 1 ? 0.9 : 0.6,
      );
      final rect = Rect.fromCenter(
        center: center,
        width: radii[i] * 2,
        height: radii[i] * 2 * 0.82,
      );
      if (i == radii.length - 1) {
        // 최외곽(멀리/멀티홉)은 점선: 전파 너머의 영역임을 암시.
        const dashes = 36;
        for (var d = 0; d < dashes; d++) {
          final a0 = d * 2 * math.pi / dashes;
          canvas.drawArc(rect, a0, math.pi / dashes, false, stroke);
        }
      } else {
        canvas.drawOval(rect, stroke);
      }
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.center != center || old.radii.length != radii.length;
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
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  // Green = direct radio range, amber = reachable via relays.
                  color: hops <= 1 ? Colors.green : Colors.amber,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 2,
                  ),
                ),
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
