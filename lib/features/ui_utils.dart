import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';

/// [MeshFrontend]를 다시 제공하면서 [screen]을 push한다. push된 라우트는 루트
/// 내비게이터 — Bootstrap의 provider 위 — 에 마운트되므로, 이것이 없으면 새
/// 화면이 컨트롤러를 찾지 못하고 빈 페이지로 죽는다.
Future<T?> pushWithController<T>(BuildContext context, Widget screen) {
  final c = context.read<MeshFrontend>();
  return Navigator.of(context).push<T>(MaterialPageRoute(
    builder: (_) => ChangeNotifierProvider.value(value: c, child: screen),
  ));
}

/// 피어의 id에서 결정론적으로 만들어 내는 아바타 색상. 각 연락처를 한눈에
/// 시각적으로 구분할 수 있게 한다.
Color avatarColor(String key) {
  var hash = 0;
  for (final c in key.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  // 인디고 브랜드와 어우러지도록 엄선해 부드럽게 톤을 낮춘 팔레트 — UI와
  // 부딪히는 네온 Material-500 프라이머리는 쓰지 않는다. 그래도 뚜렷이 구분되는
  // 열 가지 색조라서, 연락처를 한눈에 구별할 수 있다.
  const palette = [
    Color(0xFF5B67CA), // 인디고
    Color(0xFF2A9D8F), // 청록
    Color(0xFFDE7356), // 테라코타
    Color(0xFF7A6FE0), // 바이올렛
    Color(0xFF3E82C4), // 오션블루
    Color(0xFF4C9A6B), // 초록
    Color(0xFFB65C93), // 마젠타
    Color(0xFFCB8A3E), // 앰버
    Color(0xFF6E7486), // 슬레이트
    Color(0xFFC1666B), // 로즈
  ];
  return palette[hash % palette.length];
}

String initialsOf(String name) {
  final t = name.trim();
  if (t.isEmpty) return '?';
  return t.characters.first.toUpperCase();
}

/// 대화 목록용 짧은 상대 시간: "지금", "5분", "3시간", "어제", 요일, 또는
/// 날짜.
String relativeTime(int epochMs) {
  final now = DateTime.now();
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final diff = now.difference(d);
  if (diff.inMinutes < 1) return '지금';
  if (diff.inMinutes < 60) return '${diff.inMinutes}분';
  if (diff.inHours < 24 && now.day == d.day) return DateFormat.Hm().format(d);
  final yesterday = now.subtract(const Duration(days: 1));
  if (d.year == yesterday.year &&
      d.month == yesterday.month &&
      d.day == yesterday.day) {
    return '어제';
  }
  if (diff.inDays < 7) return DateFormat.E('ko').format(d);
  return DateFormat('M/d').format(d);
}

/// 메시지 말풍선용 시계 시각.
String clockTime(int epochMs) =>
    DateFormat.Hm().format(DateTime.fromMillisecondsSinceEpoch(epochMs));

/// 채팅 날짜 구분선용 전체 날짜 라벨: "오늘", "어제", 또는 날짜.
String dayLabel(int epochMs) {
  final now = DateTime.now();
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  if (now.year == d.year && now.month == d.month && now.day == d.day) {
    return '오늘';
  }
  final y = now.subtract(const Duration(days: 1));
  if (y.year == d.year && y.month == d.month && y.day == d.day) return '어제';
  return DateFormat('yyyy년 M월 d일').format(d);
}

bool sameDay(int aMs, int bMs) {
  final a = DateTime.fromMillisecondsSinceEpoch(aMs);
  final b = DateTime.fromMillisecondsSinceEpoch(bMs);
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

/// RSSI(+홉 수) → 대략적인 근접도: 사용자에게 보이는 라벨과 레이더 링
/// 인덱스(0 = 가장 안쪽/가장 가까움 … 3 = 가장 바깥). BLE의 절대 거리는
/// 신뢰할 수 없어서, 정직한 구간만 주장한다; 멀티홉 피어는 신호와 무관하게
/// 항상 바깥 링에 앉는다.
({String label, int ring}) proximityBucket(int? rssi, int hops) {
  if (hops > 1) return (label: '$hops홉 건너', ring: 3);
  if (rssi == null) return (label: '주변', ring: 2);
  if (rssi >= -55) return (label: '바로 옆', ring: 0);
  if (rssi >= -70) return (label: '가까이', ring: 1);
  if (rssi >= -82) return (label: '근처', ring: 2);
  return (label: '멀리', ring: 3);
}

String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 부드럽게 숨 쉬는 후광을 두른 상태 점 — "살아 있는" 표시(주변 친구, 검색
/// 중 상태)들이 하나의 모션 언어를 공유한다. 중심 점은 제자리에 머물고, 반투명
/// 링만 커졌다 사라지므로, 깜빡임이 아니라 심장 박동처럼
/// 읽힌다.
class PulsingDot extends StatefulWidget {
  final Color color;
  final double size;

  /// 중심 점 둘레에 그리는 링(예: 아바타 배지의 흰색 테두리).
  final Color? borderColor;
  const PulsingDot({
    super.key,
    required this.color,
    this.size = 10,
    this.borderColor,
  });

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeOut.transform(_c.value);
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // 커지면서 사라지는 후광.
              Container(
                width: s * (1 + 1.1 * t),
                height: s * (1 + 1.1 * t),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.35 * (1 - t)),
                ),
              ),
              Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                  border: widget.borderColor == null
                      ? null
                      : Border.all(color: widget.borderColor!, width: 2),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
