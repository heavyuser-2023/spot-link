import 'package:flutter/material.dart';

/// 인스타그램 스타일의 가장자리 고정 추가 버튼: 화면 오른쪽 끝에 밀착된 납작하고
/// 밝은 탭(왼쪽 모서리는 넉넉히 둥글고, 오른쪽은 화면 밖으로 흘러 나감)에, 톤을
/// 맞춘 표면 위 절제된 아이콘 — 요란한 프라이머리 알약도, 라벨도 없다. 해당 탭이
/// 활성화되면 살짝 오버슈트하며 가장자리에서 미끄러져
/// 들어온다.
class QrEdgeButton extends StatefulWidget {
  /// 소속 탭이 현재 보이는 탭일 때 true. false→true로 바뀌면 등장 애니메이션을
  /// 다시 재생한다(탭들은 IndexedStack 안에 살아 있어서, 전환할 때마다
  /// 다시 빌드되지 않기 때문이다).
  final bool active;

  /// 리스트가 스크롤 중일 때 true: 리스트가 움직이는 동안 탭은 가장자리로
  /// 스스로 파고들어 ~⅓만 보이게 하고(콘텐츠에 공간을 내어 줌), 스크롤이
  /// 멈추는 순간 다시 미끄러져 나온다.
  final bool retracted;
  final VoidCallback onPressed;
  const QrEdgeButton({
    super.key,
    required this.active,
    this.retracted = false,
    required this.onPressed,
  });

  @override
  State<QrEdgeButton> createState() => _QrEdgeButtonState();
}

class _QrEdgeButtonState extends State<QrEdgeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  /// 화면 완전히 밖에서 미끄러져 들어와, 멈추는 지점을 살짝 지나치도록
  /// 오버슈트한 뒤 자리를 잡는다 — 레퍼런스와 똑같은 "나왔다가 자리잡는" 느낌.
  late final Animation<Offset> _slide = TweenSequence<Offset>([
    TweenSequenceItem(
      tween: Tween(
        begin: const Offset(1.0, 0),
        end: const Offset(-0.12, 0),
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 55,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: const Offset(-0.12, 0),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 45,
    ),
  ]).animate(_entry);

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _entry.forward();
    } else {
      _entry.value = 1.0; // 화면 밖에서 빌드될 때는 이미 자리를 잡은 상태
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
      // 스크롤 시 접기: 리스트가 움직이는 동안 탭의 2/3를 화면 밖으로 파묻고,
      // 멈추면 다시 미끄러져 나온다. 이 분수 오프셋은 위의 등장 슬라이드와
      // 합쳐져 적용된다.
      child: AnimatedSlide(
        offset: Offset(widget.retracted ? 2 / 3 : 0, 0),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        child: Material(
          // 브랜드 색으로 물들인 컨테이너라서 가장자리 탭이 흐릿한/비활성화된
          // 조각이 아니라 탭 가능한 동작으로 분명하게 읽힌다. 부드러운 그림자가
          // 요란하지 않게 리스트에서 살짝 띄워 준다.
          color: scheme.primaryContainer,
          elevation: 3,
          shadowColor: scheme.shadow.withValues(alpha: 0.5),
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
                // 보이는(왼쪽) 방향으로 살짝 밀어 준다: 탭의 오른쪽 절반이
                // 화면 밖으로 이어지는 것처럼 읽힌다.
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.qr_code_scanner,
                    size: 26,
                    color: scheme.onPrimaryContainer,
                    semanticLabel: 'QR로 친구 추가',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
