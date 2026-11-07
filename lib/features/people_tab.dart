import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../data/models.dart';
import '../l10n/l10n.dart';
import 'add_friend_fab.dart';
import 'chat_screen.dart';
import 'encounter_screen.dart';
import 'radar_screen.dart';
import 'scan_screen.dart';
import 'ui_utils.dart';

part 'people_tab_widgets.dart';

class PeopleTab extends StatefulWidget {
  /// 이 탭이 화면에 보이는 동안 true. false→true로 바뀌면 FAB 팝인 애니메이션이
  /// 다시 재생된다(탭은 IndexedStack 안에 있어서 전환할 때마다 다시 빌드되지는
  /// 않는다).
  final bool active;
  const PeopleTab({super.key, this.active = true});

  @override
  State<PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends State<PeopleTab> {
  /// 목록이 실제로 스크롤(드래그 또는 플링)되는 동안 true. QR 가장자리 탭의
  /// 숨김 동작을 제어한다: 움직이는 동안엔 콘텐츠가 공간을 차지하고, 목록이
  /// 멈추는 순간 탭이 다시 미끄러져 나온다.
  bool _scrolling = false;

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollStartNotification && !_scrolling) {
      setState(() => _scrolling = true);
    } else if (n is ScrollEndNotification && _scrolling) {
      setState(() => _scrolling = false);
    }
    return false;
  }

  /// 검색 필터(연락처 20명 초과 시에만 노출) — 붐비는 공간에서 이름으로
  /// 바로 좁힌다. 검색 중에는 정렬·섹션 규칙이 그대로 적용된 부분집합만
  /// 보인다.
  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// 당겨서 새로고침 = "지금 바로 주변을 다시 찾아라". 발견은 연속
  /// 프로세스라(새 피어는 상태 변경으로 알아서 나타난다) 요청/응답처럼 굴면
  /// 안 된다: 인디케이터는 명령 접수만 짧게 확인하고, 그 뒤 [_boostWindow]
  /// 동안 화면 자체가 "집중 탐색" 상태를 입는다 — 레이더 스윕 가속, 헤더
  /// 라벨, 빈 상태의 소나 리플. 스낵바·카운트 없음: 목록에 사람이 나타나는
  /// 것이 진짜 피드백이다.
  bool _boosting = false;
  Timer? _boostTimer;
  static const _boostWindow = Duration(seconds: 30);

  Future<void> _rediscover(MeshFrontend c) async {
    await c.boostDiscovery();
    // 인디케이터가 깜빡하고 사라지지 않을 만큼만 잡아 둔다.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _boosting = true);
    _boostTimer?.cancel();
    _boostTimer = Timer(_boostWindow, () {
      if (mounted) setState(() => _boosting = false);
    });
  }

  @override
  void dispose() {
    _boostTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    int byName(Contact a, Contact b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    // 주변(지금 연결 가능)과 나머지 연락처를 분리: "지금 대화 가능한 사람"이
    // 항상 맨 위 섹션에 모여 있어야 동선이 짧다.
    // 주변 정렬 = 신뢰순: 레이더가 거리를 공간으로 보여주므로 목록은 신뢰를
    // 맡는다(인증 → 대화했던 → 그냥 발견, 동급 안에서는 가까운 순). 섹션으로
    // 쪼개지 않는 이유: "지금 가능한 사람"이라는 최상위 집합을 파편화하지
    // 않기 위해서 — 신뢰는 배지가 항목 단위로 말한다.
    int trustTier(Contact x) => x.verified
        ? 0
        : c.hasChat(x.peerHex)
            ? 1
            : 2;
    final nearby = c.contacts.where((x) => c.isNearby(x.peerHex)).toList()
      ..sort((a, b) {
        final ta = trustTier(a);
        final tb = trustTier(b);
        if (ta != tb) return ta - tb;
        final ha = c.hopsTo(a.peerHex);
        final hb = c.hopsTo(b.peerHex);
        if (ha != hb) return ha - hb; // 직접 연결 우선
        return byName(a, b);
      });
    // 주변에 없는 친구는 신뢰 수준으로 나눈다: QR로 서로 확인한 "인증된
    // 친구"와, 근처에서 만나 대화만 나눈 "대화했던 친구" — 재난 앱에서 이
    // 구분은 장식이 아니라 신뢰 정보다. 스쳐 지나가기만 한 기기(미인증·대화
    // 없음)는 오프라인이 되면 조용히 숨긴다: "대화했던 친구"라는 라벨을
    // 거짓으로 만들고 목록에 영구히 쌓이기만 한다. 데이터는 남아 있으므로
    // 다시 나타나면 주변 섹션에 그대로 복귀한다.
    final offline =
        c.contacts.where((x) => !c.isNearby(x.peerHex)).toList()..sort(byName);
    var offlineVerified = offline.where((x) => x.verified).toList();
    var offlineOthers = offline
        .where((x) => !x.verified && c.hasChat(x.peerHex))
        .toList();

    // 붐비는 공간(20명 초과)에서는 검색으로 좁힌다.
    final searchable = c.contacts.length > 20;
    var nearbyShown = nearby;
    if (searchable && _query.isNotEmpty) {
      bool match(Contact x) =>
          x.displayName.toLowerCase().contains(_query.toLowerCase());
      nearbyShown = nearby.where(match).toList();
      offlineVerified = offlineVerified.where(match).toList();
      offlineOthers = offlineOthers.where(match).toList();
    }

    // QR 추가 어포던스는 인스타그램 스타일 탭으로, 오른쪽 가장자리에 딱 붙어
    // 있다(떠 있는 알약형이 아니다) — 그래서 Scaffold FAB가 아니라 Stack을 쓴다.
    return Stack(
      children: [
        Positioned.fill(
          // 두 상태 모두 당겨서 새로고침으로 즉시 재탐색을 걸 수 있다 — 특히
          // 빈 상태가 "지금 바로 찾고 싶은" 바로 그 순간이다.
          child: c.contacts.isEmpty
              ? RefreshIndicator(
                  onRefresh: () => _rediscover(c),
                  child: LayoutBuilder(
                    // 빈 상태는 스크롤할 내용이 없으므로, 화면을 꽉 채우는
                    // 항상-스크롤 가능한 래퍼가 있어야 당김 제스처가 동작한다.
                    builder: (context, box) => SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: box.maxHeight),
                        child: _EmptyPeople(boosting: _boosting),
                      ),
                    ),
                  ),
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: RefreshIndicator(
                    onRefresh: () => _rediscover(c),
                    child: ListView(
                      // 항목이 화면보다 적어도 당겨서 새로고침이 되도록.
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(top: 4, bottom: 96),
                      children: [
                        // 레이더 캔버스는 보여줄 점이 있을 때만 펼쳐진다 —
                        // 빈 레이더는 활동이 아니라 부재를 시각화한다.
                        // (검색과 무관하게 전체 주변을 그린다 — 공간 지도다.)
                        if (nearby.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                            child: _ProximityRadar(
                                peers: nearby, boosting: _boosting),
                          ),
                        if (searchable)
                          Padding(
                            padding:
                                const EdgeInsets.fromLTRB(16, 10, 16, 0),
                            child: TextField(
                              controller: _search,
                              onChanged: (v) =>
                                  setState(() => _query = v.trim()),
                              decoration: InputDecoration(
                                hintText: context.s.peopleSearchHint,
                                prefixIcon: const Icon(Icons.search, size: 20),
                                suffixIcon: _query.isEmpty
                                    ? null
                                    : IconButton(
                                        icon: const Icon(Icons.clear, size: 18),
                                        onPressed: () {
                                          _search.clear();
                                          setState(() => _query = '');
                                        },
                                      ),
                                isDense: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                              ),
                            ),
                          ),
                        // '주변' 헤더는 0명이어도 상시 노출: 슬림한 한 줄이
                        // "탐색은 계속 돌고 있다"를 말한다(0명 = 숨쉬기 펄스).
                        _SectionHeader(
                          label: context.s.peopleSectionNearby,
                          count: nearbyShown.length,
                          live: nearbyShown.isNotEmpty,
                          scanning: nearby.isEmpty,
                          boosting: _boosting,
                        ),
                        ...nearbyShown.map((x) => _PersonTile(contact: x)),
                        // 지금 주변(위) 다음은 지나간 주변: 못 보고 스친 친구를
                        // 여기서 알아챈다.
                        if (_query.isEmpty) const _EncounterEntry(),
                        if (offlineVerified.isNotEmpty) ...[
                          _SectionHeader(
                              label: context.s.peopleSectionVerified,
                              count: offlineVerified.length),
                          ...offlineVerified
                              .map((x) => _PersonTile(contact: x)),
                        ],
                        if (offlineOthers.isNotEmpty) ...[
                          // 전화 연락처가 아니라 근처에서 만나 대화한 SpotLink
                          // 친구 목록이다 — 라벨도 그렇게 읽혀야 한다.
                          _SectionHeader(
                              label: context.s.peopleSectionChatted,
                              count: offlineOthers.length),
                          ...offlineOthers.map((x) => _PersonTile(contact: x)),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
        // 가장자리 어포던스는 실제 목록이 있을 때만 — 빈 상태에는 자체 중앙
        // CTA가 있어서, 거기에 두 번째 떠 있는 QR 버튼을 두면 중복이다.
        if (c.contacts.isNotEmpty)
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
          PersonAvatar(
            avatar: contact.avatar,
            displayName: contact.displayName,
            colorKey: contact.peerHex,
            radius: 20,
          ),
          if (nearby)
            Positioned(
              right: -1,
              bottom: -1,
              // 초록 = 직접 무선 도달 범위, 앰버 = 중계를 거쳐 도달 가능.
              // 깜빡임: 접속 상태가 실시간이며, 그 움직임이 이를 말해 준다.
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
          // 레이더와 같은 신뢰 배지 문법: 인증 = 파란 체크, 대화만 = 말풍선.
          if (contact.verified)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.verified, size: 16, color: Colors.blue),
            )
          else if (c.hasChat(contact.peerHex))
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.chat_bubble,
                  size: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
        ],
      ),
      subtitle: Text(
        context.s.peopleTileSubtitle(
          contact.peerId.short,
          nearby
              ? proximityBucket(c.rssiOf(contact.peerHex), hops)
                  .level
                  .label(context, hops: hops)
              : context.s.peopleStatusOffline,
        ),
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
              leading: PersonAvatar(
                avatar: contact.avatar,
                displayName: contact.displayName,
                colorKey: contact.peerHex,
                radius: 20,
              ),
              title: Text(contact.displayName),
              subtitle: Text(context.s.peopleContactId(contact.peerId.short)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(context.s.peopleActionChat),
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
              title: Text(context.s.peopleActionRename),
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
                context.s.commonDelete,
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
        title: Text(context.s.peopleDeleteTitle(contact.displayName)),
        content: Text(context.s.peopleDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.s.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.s.commonDelete),
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
          title: Text(context.s.peopleActionRename),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 32,
            decoration:
                InputDecoration(labelText: context.s.peopleDisplayNameLabel),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.s.commonCancel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: Text(context.s.commonSave),
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
