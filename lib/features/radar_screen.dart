import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../data/models.dart';
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
    final nearby = c.contacts.where((x) => c.isNearby(x.peerHex)).toList()
      ..sort((a, b) => c.hopsTo(a.peerHex) - c.hopsTo(b.peerHex));

    return Scaffold(
      appBar: AppBar(
        title: Text('주변 친구 ${nearby.length}'),
        actions: [
          IconButton(
            tooltip: '원래 배율',
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
                  // 나 (중심) — 크기 고정.
                  Positioned(
                    left: origin.dx - 22,
                    top: origin.dy - 22,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 3),
                      ),
                      child:
                          Icon(Icons.person, size: 24, color: scheme.onPrimary),
                    ),
                  ),
                  for (var i = 0; i < nearby.length; i++)
                    _avatar(context, c, nearby[i], i, origin, maxR),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: IgnorePointer(
                      child: Text(
                        _scale > 1.01
                            ? '${_scale.toStringAsFixed(1)}× · 두 번 탭하면 원래대로'
                            : '가까울수록 중앙 · 핀치로 확대, 드래그로 이동',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: scheme.outline),
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

  Widget _avatar(BuildContext context, MeshFrontend c, Contact peer, int index,
      Offset origin, double maxR) {
    final bucket =
        proximityBucket(c.rssiOf(peer.peerHex), c.hopsTo(peer.peerHex));
    // 거리는 줌에 따라 스케일되지만, 아래의 글리프는 그렇지 않다.
    final radius = maxR * _ringFractions[bucket.ring] * _scale;
    // 카드와 동일한 안정적 해시 + 황금각 분산을 써서, 한 피어가 두 뷰에서
    // 같은 위치에 앉도록 한다.
    var hash = 0;
    for (final u in peer.peerHex.codeUnits) {
      hash = (hash * 31 + u) & 0x7fffffff;
    }
    final angle = (hash % 360) * math.pi / 180 + index * 2.399;
    final pos = origin +
        Offset(math.cos(angle) * radius, math.sin(angle) * radius * 0.82);

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
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2.5,
                ),
              ),
              child: CircleAvatar(
                radius: 22,
                backgroundColor: avatarColor(peer.peerHex),
                foregroundColor: Colors.white,
                child: Text(initialsOf(peer.displayName),
                    style: const TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              peer.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Text(
              bucket.label,
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
