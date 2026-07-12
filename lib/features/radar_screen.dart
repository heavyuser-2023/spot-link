import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../data/models.dart';
import 'chat_screen.dart';
import 'ui_utils.dart';

/// Full-screen proximity radar for crowded rooms: the People-tab card grown
/// to the whole viewport, wrapped in an [InteractiveViewer] so a pinch zooms
/// into a cluster of avatars and a drag pans across it. Tapping an avatar
/// still opens the chat.
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen>
    with SingleTickerProviderStateMixin {
  static const _ringFractions = [0.30, 0.53, 0.76, 0.98];

  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  final _viewer = TransformationController();

  @override
  void dispose() {
    _sweep.dispose();
    _viewer.dispose();
    super.dispose();
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
          // One tap back to 1:1 after wandering around a crowd.
          IconButton(
            tooltip: '원래 배율',
            icon: const Icon(Icons.center_focus_strong_outlined),
            onPressed: () => _viewer.value = Matrix4.identity(),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          final center = Offset(size.width / 2, size.height / 2);
          final maxR = math.min(size.width, size.height) / 2 - 56;

          return InteractiveViewer(
            transformationController: _viewer,
            minScale: 1.0,
            maxScale: 4.0,
            // Lets a zoomed view pan a little past the edges so avatars near
            // the border are reachable.
            boundaryMargin: const EdgeInsets.all(96),
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: Stack(
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
                    left: center.dx - 22,
                    top: center.dy - 22,
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
                    _avatar(context, c, nearby[i], i, center, maxR),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: Text(
                      '가까울수록 중앙 · 핀치로 확대, 드래그로 이동',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: scheme.outline),
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
      Offset center, double maxR) {
    final bucket =
        proximityBucket(c.rssiOf(peer.peerHex), c.hopsTo(peer.peerHex));
    final radius = maxR * _ringFractions[bucket.ring];
    // Same stable hash + golden-angle spread as the card, so a peer sits in
    // the SAME spot in both views — the fullscreen feels like zooming into
    // the card, not a different map.
    var hash = 0;
    for (final u in peer.peerHex.codeUnits) {
      hash = (hash * 31 + u) & 0x7fffffff;
    }
    final angle = (hash % 360) * math.pi / 180 + index * 2.399;
    final pos = center +
        Offset(math.cos(angle) * radius, math.sin(angle) * radius * 0.82);

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
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

/// Sonar rings + rotating sweep beam, shared by the People-tab card and the
/// full-screen radar.
class RadarPainter extends CustomPainter {
  final Offset center;
  final List<double> radii;
  final Color ringColor;
  final Color fillColor;

  /// Current sweep-beam angle (radians). Advances continuously for the
  /// sonar-scan effect.
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
    // Sonar sweep beam: a ~50° trailing wedge that fades out behind the
    // leading edge, squashed to the same 0.82 ellipse as the rings.
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
        // Fixed 0→0.9rad fade rotated to the current angle (SweepGradient
        // angles must stay inside [0, 2π]; the rotation transform doesn't).
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
      old.sweep != sweep;
}
