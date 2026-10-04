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

/// 소나(레이더) 뷰: 나를 중심으로 한 동심원 위에 주변 사람을 배치한다.
/// 신호가 강할수록(가까울수록) 안쪽 링, 멀티홉 상대는 최외곽 점선 링.
/// 아바타를 탭하면 바로 대화가 열린다 — "누가 얼마나 가까이 있나"를
/// 목록을 읽지 않고 한눈에 보는 화면.
class _ProximityRadar extends StatefulWidget {
  final List<Contact> peers;

  /// 사용자가 당겨서 새로고침으로 집중 탐색을 건 동안 true — 스윕이
  /// 빨라져서 "지금 더 세게 훑고 있다"를 텍스트 없이 말한다.
  final bool boosting;
  const _ProximityRadar({required this.peers, this.boosting = false});

  static const double _height = 264;
  static const _ringFractions = [0.30, 0.53, 0.76, 0.98];

  @override
  State<_ProximityRadar> createState() => _ProximityRadarState();
}

class _ProximityRadarState extends State<_ProximityRadar>
    with SingleTickerProviderStateMixin {
  /// 느린 소나 스윕 — 평상시 6초에 한 바퀴, 집중 탐색 중엔 2.4초. 그리기
  /// 비용은 저렴하고(스윕 그라디언트 호 하나), 이 움직임이 "지금 실제로
  /// 훑고 있다"는 느낌을 준다.
  late final AnimationController _sweep = AnimationController(vsync: this);

  static const _idleSweep = Duration(seconds: 6);
  static const _boostSweep = Duration(milliseconds: 2400);

  @override
  void initState() {
    super.initState();
    _sweep
      ..duration = widget.boosting ? _boostSweep : _idleSweep
      ..repeat();
  }

  @override
  void didUpdateWidget(covariant _ProximityRadar old) {
    super.didUpdateWidget(old);
    if (old.boosting != widget.boosting) {
      _sweep
        ..duration = widget.boosting ? _boostSweep : _idleSweep
        ..repeat();
    }
  }

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
              // 붐비는 공간 대비: 카드 크기(264px)에서 아바타가 겹치지 않는
              // 상한은 ~12개다. peers는 이미 신뢰→근접순으로 정렬돼 있으므로
              // 앞에서 자르면 "가장 믿을 수 있고 가까운" 사람들이 남는다 —
              // 나머지는 오버플로 필("+N")이 말하고, 탭하면 전체화면 레이더.
              const cap = 12;
              final shown = peers.length <= cap ? peers : peers.sublist(0, cap);
              final overflow = peers.length - shown.length;
              final layout = RadarLayout.compute(
                peers: shown,
                frontend: c,
                center: center,
                maxR: maxR,
                ringFractions: _ringFractions,
              );

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
                  // 중계 경로(나 → 릴레이 → 상대): 아바타 밑에 깔리는 점선 곡선.
                  if (layout.relayPaths.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: RelayPathPainter(
                            center: center,
                            paths: layout.relayPaths,
                            color: Colors.amber,
                          ),
                        ),
                      ),
                    ),
                  // 나 (중심) — 내 아바타. 프라이머리 링으로 "나"임을 구분.
                  Positioned(
                    left: center.dx - 19,
                    top: center.dy - 19,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.surface,
                        border: Border.all(color: scheme.primary, width: 2),
                      ),
                      child: PersonAvatar(
                        avatar: c.myAvatar,
                        displayName: c.displayName,
                        colorKey: c.myId.hex,
                        radius: 15,
                      ),
                    ),
                  ),
                  for (final peer in shown)
                    _radarAvatar(context, c, peer, layout.pos[peer.peerHex]!),
                  if (overflow > 0)
                    Positioned(
                      right: 10,
                      bottom: 24,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          context.s.radarOverflow(overflow),
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
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
                      context.s.radarCardHint,
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
      BuildContext context, MeshFrontend c, Contact peer, Offset pos) {
    final scheme = Theme.of(context).colorScheme;
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
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // 인증된 친구는 시드색 링 — 배지와 함께 이중으로 말한다.
                    border: Border.all(
                      color:
                          peer.verified ? scheme.primary : scheme.surface,
                      width: peer.verified ? 2.2 : 2,
                    ),
                  ),
                  child: PersonAvatar(
                    avatar: peer.avatar,
                    displayName: peer.displayName,
                    colorKey: peer.peerHex,
                    radius: 17,
                  ),
                ),
                Positioned(
                  right: -4,
                  top: -4,
                  child: RadarTrustBadge(
                    verified: peer.verified,
                    chatted: c.hasChat(peer.peerHex),
                  ),
                ),
              ],
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

/// "스쳐간 친구" 진입 행. 가장 최근 만남 한 줄을 보여 줘서, 앱을 보지 않던
/// 사이에 누가 지나갔는지 친구 탭에서 바로 알 수 있게 한다. 친구 탭은 프레즌스
/// 틱마다 다시 그려지므로, 기록 리비전이 바뀔 때만 DB를 다시 읽는다.
class _EncounterEntry extends StatefulWidget {
  const _EncounterEntry();

  @override
  State<_EncounterEntry> createState() => _EncounterEntryState();
}

class _EncounterEntryState extends State<_EncounterEntry> {
  Encounter? _latest;
  int _rev = -1;

  Future<void> _refresh(MeshFrontend c) async {
    final rev = c.encounterRev;
    final list = await c.encounters();
    if (!mounted) return;
    setState(() {
      _latest = list.isEmpty ? null : list.first;
      _rev = rev;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    if (c.encounterRev != _rev) {
      _rev = c.encounterRev;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(c));
    }
    final latest = _latest;
    final s = context.s;
    final String subtitle;
    if (latest == null) {
      subtitle = s.encEntryEmpty;
    } else {
      final hex = latest.peerHex;
      final name = hex == null
          ? s.encUnknownPeer
          : (c.contactByHex(hex)?.displayName ?? s.encUnknownPeer);
      subtitle = s.encEntryRecent(name, relativeTime(context, latest.startedAt));
    }
    return ListTile(
      leading: const Icon(Icons.history),
      title: Text(s.encEntryTitle),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => pushWithController(context, const EncounterScreen()),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool live;

  /// 집중 탐색 창 동안 헤더 오른쪽에 조용한 상태 라벨을 띄운다 — 스낵바처럼
  /// 콘텐츠를 가리지 않고, 창이 닫히면 소리 없이 사라진다.
  final bool boosting;

  /// 주변 0명인 동안의 상시 신호: "탐색은 계속 돌고 있다"를 숨쉬기 펄스로
  /// 말한다. 연속 회전(=로딩 문법, 완료를 약속하는 모션)이 아니라 주기적
  /// 호흡이라 영원히 떠 있어도 "끝나지 않는 로딩"으로 읽히지 않는다.
  /// [boosting]이 이보다 우선한다.
  final bool scanning;
  const _SectionHeader({
    required this.label,
    required this.count,
    this.live = false,
    this.boosting = false,
    this.scanning = false,
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
            context.s.peopleSectionHeader(label, count),
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          // AnimatedOpacity가 아니라 Switcher: 안 보일 때는 스피너 자체가
          // 트리에서 빠져 애니메이션 비용이 0이다.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: boosting
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.4,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        context.s.peopleBoosting,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: scheme.primary),
                      ),
                    ],
                  )
                : scanning
                    ? const _ScanPulseLabel()
                    : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 주변 0명일 때 헤더 오른쪽의 상시 신호 "탐색 중". 10초 주기의 숨쉬기
/// 펄스 — 사이클 앞 2.5초 동안만 밝아졌다 가라앉고 나머지는 은은하게
/// 머문다. 항상 떠 있는 요소라 시선을 끄는 연속 모션은 금물이고, 비용도
/// 불투명도 하나뿐이라 상시 노출에 안전하다.
class _ScanPulseLabel extends StatefulWidget {
  const _ScanPulseLabel();

  @override
  State<_ScanPulseLabel> createState() => _ScanPulseLabelState();
}

class _ScanPulseLabelState extends State<_ScanPulseLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.35, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 12.5,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.35)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 12.5,
      ),
      TweenSequenceItem(tween: ConstantTween(0.35), weight: 75),
    ]).animate(_breath);
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FadeTransition(
      opacity: _opacity,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            context.s.peopleScanning,
            style: Theme.of(context)
                .textTheme
                .labelSmall
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

class _EmptyPeople extends StatefulWidget {
  /// 집중 탐색 창 동안 톤 원형 주위로 소나 리플을 퍼뜨린다 — 레이더 카드가
  /// 없는 빈 상태에서 "지금 훑고 있다"를 같은 시각 언어로 말하는 방법.
  final bool boosting;
  const _EmptyPeople({this.boosting = false});

  @override
  State<_EmptyPeople> createState() => _EmptyPeopleState();
}

class _EmptyPeopleState extends State<_EmptyPeople>
    with SingleTickerProviderStateMixin {
  // late-lazy로 두면 boosting이 한 번도 안 켜진 채 위젯이 사라질 때
  // dispose()가 첫 생성자가 되어 죽은 트리에서 Ticker를 만들다 터진다 —
  // 반드시 initState에서 즉시 생성한다.
  late final AnimationController _ripple;

  @override
  void initState() {
    super.initState();
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    if (widget.boosting) _ripple.repeat();
  }

  @override
  void didUpdateWidget(covariant _EmptyPeople old) {
    super.didUpdateWidget(old);
    if (old.boosting != widget.boosting) {
      widget.boosting ? _ripple.repeat() : _ripple.stop();
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Chats 탭과 동일한 빈 상태 언어: 은은하게 틴트된 원에 틴트된
            // 아이콘, 무거운 검정 글리프는 절대 쓰지 않는다.
            SizedBox(
              width: 128,
              height: 128,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 창이 닫히면 마지막 프레임이 얼어붙지 않도록 Switcher가
                  // 링을 통째로 페이드아웃하며 트리에서 뺀다.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    child: !widget.boosting
                        ? const SizedBox.shrink()
                        : AnimatedBuilder(
                            animation: _ripple,
                            builder: (context, _) => CustomPaint(
                              size: const Size.square(128),
                              painter: _SonarRipplePainter(
                                progress: _ripple.value,
                                baseRadius: 40,
                                maxRadius: 64,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                  ),
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(Icons.groups_2_outlined,
                        size: 40, color: scheme.onPrimaryContainer),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(context.s.peopleEmptyTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              context.s.peopleEmptyBody,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () =>
                  pushWithController(context, const ScanScreen()),
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(context.s.peopleAddFriendQr),
            ),
            if (!c.started) ...[
              const SizedBox(height: 16),
              Text(
                context.s.peopleBluetoothOff,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 톤 원형 가장자리에서 퍼져 나가는 소나 링 두 개. 반 주기 간격으로
/// 엇갈리며, 퍼질수록 옅어져 [maxRadius]에서 완전히 사라진다 — 레이더
/// 카드의 스윕과 같은 "훑는 중" 시각 언어의 빈 상태 버전.
class _SonarRipplePainter extends CustomPainter {
  final double progress; // 0..1 반복
  final double baseRadius;
  final double maxRadius;
  final Color color;

  _SonarRipplePainter({
    required this.progress,
    required this.baseRadius,
    required this.maxRadius,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final phase in const [0.0, 0.5]) {
      final t = (progress + phase) % 1.0;
      final radius = baseRadius + (maxRadius - baseRadius) * t;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withValues(alpha: (1 - t) * 0.35);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_SonarRipplePainter old) =>
      old.progress != progress || old.color != color;
}
