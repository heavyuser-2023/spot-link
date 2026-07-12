import 'package:flutter/material.dart';

/// Instagram-style edge-docked add button: a flat light tab flush with the
/// RIGHT screen edge (left corners generously rounded, right side bleeding
/// off-screen), muted icon on a tonal surface — no loud primary pill, no
/// label. Slides in from the edge with a small overshoot when its tab
/// becomes active.
class QrEdgeButton extends StatefulWidget {
  /// True while the owning tab is the visible one. Flipping false→true
  /// replays the entrance (tabs live in an IndexedStack, so they aren't
  /// rebuilt on every switch).
  final bool active;
  final VoidCallback onPressed;
  const QrEdgeButton({super.key, required this.active, required this.onPressed});

  @override
  State<QrEdgeButton> createState() => _QrEdgeButtonState();
}

class _QrEdgeButtonState extends State<QrEdgeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  /// Slide from fully off-screen, overshoot a touch past the resting spot,
  /// then settle — the same "나왔다가 자리잡는" feel as the reference.
  late final Animation<Offset> _slide = TweenSequence<Offset>([
    TweenSequenceItem(
      tween: Tween(begin: const Offset(1.0, 0), end: const Offset(-0.12, 0))
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 55,
    ),
    TweenSequenceItem(
      tween: Tween(begin: const Offset(-0.12, 0), end: Offset.zero)
          .chain(CurveTween(curve: Curves.easeInOut)),
      weight: 45,
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
  void didUpdateWidget(QrEdgeButton old) {
    super.didUpdateWidget(old);
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
    return SlideTransition(
      position: _slide,
      child: Material(
        // Flat tonal surface like the reference — reads by tone, not shadow.
        color: scheme.surfaceContainerHighest,
        elevation: 0,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(26),
          bottomLeft: Radius.circular(26),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onPressed,
          child: SizedBox(
            width: 58,
            height: 64,
            child: Center(
              // Nudge toward the visible (left) side: the tab reads as if its
              // right half continues off-screen.
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.qr_code_scanner,
                  size: 26,
                  color: scheme.onSurfaceVariant,
                  semanticLabel: 'QR로 친구 추가',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
