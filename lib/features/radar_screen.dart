import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../data/models.dart';
import '../l10n/l10n.dart';
import 'chat_screen.dart';
import 'ui_utils.dart';

/// 붐비는 공간을 위한 전체 화면 근접 레이더. 지도 스타일의 시맨틱 줌을 쓴다:
/// 핀치하면 레이더 공간이 넓어지고(링 반지름이 커져 겹쳐 있던 친구들이 서로
/// 벌어진다), 아바타와 이름 라벨은 크기를 유지한다 — 그냥 스크린샷을 확대하면
/// 겹침만 더 커질 뿐이다. 드래그하면 이동하고, 두 번 탭(또는 앱 바 버튼)하면
/// 초기화된다. 아바타를 탭하면 채팅이 열린다.
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen>
    with SingleTickerProviderStateMixin {
  static const _ringFractions = [0.30, 0.53, 0.76, 0.98];
  static const double _minScale = 1.0;
  static const double _maxScale = 5.0;

  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  /// 거리에만 적용되는 줌 배율(글리프에는 적용되지 않음).
  double _scale = 1.0;

  /// 레이더 원점의 이동량, 화면 px 단위.
  Offset _offset = Offset.zero;

  // 제스처 시작 시점의 스냅샷.
  double _startScale = 1.0;
  Offset _startOffset = Offset.zero;

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
        _scale = 1.0;
        _offset = Offset.zero;
      });

  void _onScaleStart(ScaleStartDetails d) {
    _startScale = _scale;
    _startOffset = _offset;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Offset center, double maxR) {
    setState(() {
      final next = (_startScale * d.scale).clamp(_minScale, _maxScale);
      if (d.scale != 1.0) {
        // 핀치: 손가락 아래의 월드 좌표를 고정한 채 그 주위로 거리를 늘린다
        // (앵커 계산이 이미 움직이는 초점을 따라가므로, 여기에 별도의 이동
        // 항은 필요 없다).
        final focal = d.localFocalPoint;
        final world = (focal - center - _startOffset) / _startScale;
        _offset = focal - center - world * next;
      } else {
        // 한 손가락 드래그: 단순 이동.
        _offset += d.focalPointDelta;
      }
      _scale = next;
      // 지도가 완전히 화면 밖으로 날아가 버리지 않도록 하는 느슨한 경계.
      final lim = maxR * _scale;
      _offset = Offset(
        _offset.dx.clamp(-lim, lim),
        _offset.dy.clamp(-lim, lim),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    final scheme = Theme.of(context).colorScheme;
    // 신뢰 → 근접순(주변 탭과 동일 기준). 붐비는 공간에서는 상한을 두고
    // 가장 믿을 수 있고 가까운 사람부터 그린다 — 100명을 다 그리면 SVG
    // 아바타 렌더 비용과 겹침으로 화면이 죽는다.
    int trustTier(Contact x) => x.verified
        ? 0
        : c.hasChat(x.peerHex)
            ? 1
            : 2;
    final all = c.contacts.where((x) => c.isNearby(x.peerHex)).toList()
      ..sort((a, b) {
        final t = trustTier(a) - trustTier(b);
        if (t != 0) return t;
        return c.hopsTo(a.peerHex) - c.hopsTo(b.peerHex);
      });
    const cap = 48;
    final nearby = all.length <= cap ? all : all.sublist(0, cap);
    final hidden = all.length - nearby.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(hidden > 0
            ? context.s.radarTitleCapped(all.length, cap)
            : context.s.radarTitle(all.length)),
        actions: [
          IconButton(
            tooltip: context.s.radarResetZoom,
            icon: const Icon(Icons.center_focus_strong_outlined),
            onPressed: _reset,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          final center = Offset(size.width / 2, size.height / 2);
          final maxR = math.min(size.width, size.height) / 2 - 56;
          final origin = center + _offset;
          final layout = RadarLayout.compute(
            peers: nearby,
            frontend: c,
            center: origin,
            maxR: maxR,
            ringFractions: _ringFractions,
            scale: _scale,
          );

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: (d) => _onScaleUpdate(d, center, maxR),
            onDoubleTap: _reset,
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _sweep,
                      builder: (context, _) => CustomPaint(
                        painter: RadarPainter(
                          center: origin,
                          // 시맨틱 줌: 반지름만 늘어난다.
                          radii: [
                            for (final f in _ringFractions) maxR * f * _scale
                          ],
                          ringColor: scheme.outlineVariant,
                          fillColor: scheme.primary,
                          sweep: _sweep.value * 2 * math.pi,
                        ),
                      ),
                    ),
                  ),
                  // 중계 경로(나 → 릴레이 → 상대): 아바타 밑에 깔린다.
                  if (layout.relayPaths.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: RelayPathPainter(
                            center: origin,
                            paths: layout.relayPaths,
                            color: Colors.amber,
                          ),
                        ),
                      ),
                    ),
                  // 나 (중심) — 내 아바타, 크기 고정. 프라이머리 링으로 "나"임을 구분.
                  Positioned(
                    left: origin.dx - 24,
                    top: origin.dy - 24,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.surface,
                        border: Border.all(color: scheme.primary, width: 2.5),
                      ),
                      child: PersonAvatar(
                        avatar: c.myAvatar,
                        displayName: c.displayName,
                        colorKey: c.myId.hex,
                        radius: 19,
                      ),
                    ),
                  ),
                  for (final peer in nearby)
                    _avatar(context, c, peer, layout.pos[peer.peerHex]!),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: IgnorePointer(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 신뢰 범례: 배지가 무슨 뜻인지 한 줄로.
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.verified,
                                  size: 13, color: Colors.blue),
                              const SizedBox(width: 3),
                              Text(context.s.radarLegendVerified,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(color: scheme.outline)),
                              const SizedBox(width: 12),
                              Icon(Icons.chat_bubble,
                                  size: 11, color: scheme.onSurfaceVariant),
                              const SizedBox(width: 3),
                              Text(context.s.radarLegendChatted,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(color: scheme.outline)),
                              const SizedBox(width: 12),
                              Text(context.s.radarLegendDiscovered,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(color: scheme.outline)),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _scale > 1.01
                                ? context.s
                                    .radarZoomHint(_scale.toStringAsFixed(1))
                                : context.s.radarPanZoomHint,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: scheme.outline),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _avatar(
      BuildContext context, MeshFrontend c, Contact peer, Offset pos) {
    // 라벨용 근접 버킷(배치는 RadarLayout이 계산한다).
    final hops = c.hopsTo(peer.peerHex);
    final bucket = proximityBucket(c.rssiOf(peer.peerHex), hops);

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 120),
      curve: Curves.linear,
      left: pos.dx - 40,
      top: pos.dy - 28,
      width: 80,
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
                    border: Border.all(
                      color: peer.verified
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surface,
                      width: 2.5,
                    ),
                  ),
                  child: PersonAvatar(
                    avatar: peer.avatar,
                    displayName: peer.displayName,
                    colorKey: peer.peerHex,
                    radius: 22,
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
            const SizedBox(height: 2),
            Text(
              peer.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Text(
              bucket.level.label(context, hops: hops),
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// 레이더 아바타의 신뢰 배지: QR로 서로 확인한 친구는 파란 체크(목록과
/// 동일한 시각 언어), 대화만 나눈 친구는 말풍선, 그냥 발견된 사람은 배지
/// 없음 — 재난 상황에서 "누구를 믿을 수 있나"를 레이더에서 즉시 읽게 한다.
class RadarTrustBadge extends StatelessWidget {
  final bool verified;
  final bool chatted;
  const RadarTrustBadge(
      {super.key, required this.verified, required this.chatted});

  @override
  Widget build(BuildContext context) {
    if (!verified && !chatted) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration:
          BoxDecoration(color: scheme.surface, shape: BoxShape.circle),
      padding: const EdgeInsets.all(1.5),
      child: verified
          ? const Icon(Icons.verified, size: 14, color: Colors.blue)
          : Icon(Icons.chat_bubble,
              size: 11, color: scheme.onSurfaceVariant),
    );
  }
}

/// 레이더 위 피어 배치 + 중계 경로 계산. 친구 탭 카드와 전체 화면 레이더가
/// 같은 결과를 공유해, 한 피어가 두 뷰에서 같은 자리에 앉는다.
///
/// 배치 규칙:
/// - 직접(1홉) 피어: 기존과 동일한 안정 해시 + 황금각 분산.
/// - 멀티홉 피어: 마지막 릴레이([MeshFrontend.viaOf])의 각도 근처에 앵커 —
///   "나 → 릴레이 → 상대"의 점선 경로가 꼬이지 않고 자연스럽게 읽힌다.
///   릴레이를 모르면(구버전 스냅샷 등) 기존 해시 배치로 폴백.
class RadarLayout {
  /// peerHex → 레이더 좌표.
  final Map<String, Offset> pos;

  /// (릴레이 위치, 멀티홉 상대 위치) 쌍 — [RelayPathPainter]가 그린다.
  final List<(Offset, Offset)> relayPaths;
  RadarLayout(this.pos, this.relayPaths);

  static int _hash(String key) {
    var h = 0;
    for (final u in key.codeUnits) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    return h;
  }

  static RadarLayout compute({
    required List<Contact> peers,
    required MeshFrontend frontend,
    required Offset center,
    required double maxR,
    required List<double> ringFractions,
    double scale = 1.0,
  }) {
    Offset place(double angle, double radius) =>
        center +
        Offset(math.cos(angle) * radius, math.sin(angle) * radius * 0.82);
    double ringRadius(Contact p) {
      final bucket = proximityBucket(
          frontend.rssiOf(p.peerHex), frontend.hopsTo(p.peerHex));
      return maxR * ringFractions[bucket.ring] * scale;
    }

    double hashAngle(String hex, int index) =>
        (_hash(hex) % 360) * math.pi / 180 + index * 2.399;

    final pos = <String, Offset>{};
    final angles = <String, double>{};
    // 1차: 직접 피어를 먼저 앉혀야 멀티홉이 앵커할 각도가 생긴다.
    for (var i = 0; i < peers.length; i++) {
      final p = peers[i];
      if (frontend.hopsTo(p.peerHex) > 1) continue;
      final angle = hashAngle(p.peerHex, i);
      angles[p.peerHex] = angle;
      pos[p.peerHex] = place(angle, ringRadius(p));
    }
    // 2차: 멀티홉 피어 — 릴레이 각도 ±0.45rad 안에서 해시로 흩뿌린다.
    final paths = <(Offset, Offset)>[];
    for (var i = 0; i < peers.length; i++) {
      final p = peers[i];
      if (frontend.hopsTo(p.peerHex) <= 1) continue;
      final viaHex = frontend.viaOf(p.peerHex);
      final anchor = viaHex == null ? null : angles[viaHex];
      final angle = anchor == null
          ? hashAngle(p.peerHex, i)
          : anchor + ((_hash(p.peerHex) % 100) / 100 - 0.5) * 0.9;
      angles[p.peerHex] = angle;
      final at = place(angle, ringRadius(p));
      pos[p.peerHex] = at;
      final viaPos = viaHex == null ? null : pos[viaHex];
      if (viaPos != null) paths.add((viaPos, at));
    }
    return RadarLayout(pos, paths);
  }
}

/// 중계 경로: 나 → 릴레이는 흔적만(옅은 점선 직선 — 직접 링크는 이미
/// 자명하다), 릴레이 → 상대는 바깥으로 살짝 휘는 점선 곡선. 앰버는 목록의
/// 중계(멀티홉) 도트와 같은 액센트 언어다. 양 끝은 아바타에 겹치지 않게
/// 잘라낸다.
class RelayPathPainter extends CustomPainter {
  final Offset center;
  final List<(Offset, Offset)> paths;
  final Color color;
  RelayPathPainter({
    required this.center,
    required this.paths,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final toRelay = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.20);
    final toPeer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.55);
    for (final (via, target) in paths) {
      canvas.drawPath(
        _dashed(
          Path()
            ..moveTo(center.dx, center.dy)
            ..lineTo(via.dx, via.dy),
          trimStart: 26,
          trimEnd: 24,
        ),
        toRelay,
      );
      // 곡률: 중점을 중심 반대 방향으로 살짝 밀어낸 2차 베지어.
      final mid = Offset((via.dx + target.dx) / 2, (via.dy + target.dy) / 2);
      final away = mid - center;
      final ctrl =
          away.distance < 1 ? mid : mid + away / away.distance * 14;
      canvas.drawPath(
        _dashed(
          Path()
            ..moveTo(via.dx, via.dy)
            ..quadraticBezierTo(ctrl.dx, ctrl.dy, target.dx, target.dy),
          trimStart: 24,
          trimEnd: 24,
        ),
        toPeer,
      );
    }
  }

  static Path _dashed(Path src,
      {double dash = 5, double gap = 4.5, double trimStart = 0, double trimEnd = 0}) {
    final out = Path();
    for (final metric in src.computeMetrics()) {
      var d = trimStart;
      final end = metric.length - trimEnd;
      while (d < end) {
        final next = math.min(d + dash, end);
        out.addPath(metric.extractPath(d, next), Offset.zero);
        d = next + gap;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(RelayPathPainter old) {
    if (old.center != center ||
        old.color != color ||
        old.paths.length != paths.length) {
      return true;
    }
    for (var i = 0; i < paths.length; i++) {
      if (old.paths[i] != paths[i]) return true;
    }
    return false;
  }
}

/// 소나 링 + 회전하는 스윕 빔. 친구 탭 카드와 전체 화면 레이더가 함께
/// 사용한다.
class RadarPainter extends CustomPainter {
  final Offset center;
  final List<double> radii;
  final Color ringColor;
  final Color fillColor;

  /// 현재 스윕 빔 각도(라디안). 소나 스캔 효과를 위해 계속 이어서
  /// 나아간다.
  final double sweep;
  RadarPainter({
    required this.center,
    required this.radii,
    required this.ringColor,
    required this.fillColor,
    this.sweep = 0,
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
    // 소나 스윕 빔: 선단 뒤로 서서히 사라지는 ~50°의 꼬리 쐐기로, 링과 동일한
    // 0.82 타원으로 눌러 찌그러뜨린다.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1, 0.82);
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..arcTo(Rect.fromCircle(center: Offset.zero, radius: radii.last),
            sweep - 0.9, 0.9, false)
        ..close(),
      Paint()
        // 0→0.9rad 고정 페이드를 현재 각도로 회전시킨 것(SweepGradient의
        // 각도는 [0, 2π] 안에 있어야 하지만, 회전 변환은 그렇지 않아도 된다).
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: 0.9,
          colors: [
            fillColor.withValues(alpha: 0.0),
            fillColor.withValues(alpha: 0.16),
          ],
          transform: GradientRotation(sweep - 0.9),
        ).createShader(
            Rect.fromCircle(center: Offset.zero, radius: radii.last)),
    );
    canvas.restore();

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
  bool shouldRepaint(RadarPainter old) =>
      old.center != center ||
      old.radii.length != radii.length ||
      old.radii.last != radii.last ||
      old.sweep != sweep;
}
