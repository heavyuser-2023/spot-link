import 'package:flutter/material.dart';

/// Instagram-style compose FAB shared by the 채팅/친구 tabs: pops in slightly
/// oversized then settles when its tab becomes active, and shrinks from a
/// labelled pill to a compact icon as the list scrolls.
class AddFriendFab extends StatefulWidget {
  /// True while the owning tab is the visible one. Flipping false→true
  /// replays the entrance animation (tabs live in an IndexedStack, so they
  /// aren't rebuilt on every switch).
  final bool active;

  /// 0 = at top (full labelled pill) … 1 = scrolled (collapsed to icon).
  final double collapse;
  final VoidCallback onPressed;
  const AddFriendFab({
    super.key,
    required this.active,
    required this.collapse,
    required this.onPressed,
  });

  @override
  State<AddFriendFab> createState() => _AddFriendFabState();
}

class _AddFriendFabState extends State<AddFriendFab>
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
  void didUpdateWidget(AddFriendFab old) {
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
