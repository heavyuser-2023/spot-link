import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';

/// Push [screen] with the [MeshFrontend] re-provided. Pushed routes mount
/// on the root navigator — above the provider in Bootstrap — so without this
/// the new screen cannot find the controller and dies with a blank page.
Future<T?> pushWithController<T>(BuildContext context, Widget screen) {
  final c = context.read<MeshFrontend>();
  return Navigator.of(context).push<T>(MaterialPageRoute(
    builder: (_) => ChangeNotifierProvider.value(value: c, child: screen),
  ));
}

/// Deterministic avatar color derived from a peer's id, so each contact is
/// visually distinguishable at a glance.
Color avatarColor(String key) {
  var hash = 0;
  for (final c in key.codeUnits) {
    hash = (hash * 31 + c) & 0x7fffffff;
  }
  const palette = [
    Color(0xFF3D5AFE),
    Color(0xFF00897B),
    Color(0xFFD81B60),
    Color(0xFF6D4C41),
    Color(0xFF5E35B1),
    Color(0xFF039BE5),
    Color(0xFFF4511E),
    Color(0xFF43A047),
    Color(0xFF8E24AA),
    Color(0xFFFB8C00),
  ];
  return palette[hash % palette.length];
}

String initialsOf(String name) {
  final t = name.trim();
  if (t.isEmpty) return '?';
  return t.characters.first.toUpperCase();
}

/// Short relative time for conversation lists: "지금", "5분", "3시간", "어제",
/// weekday, or a date.
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

/// Clock time for message bubbles.
String clockTime(int epochMs) =>
    DateFormat.Hm().format(DateTime.fromMillisecondsSinceEpoch(epochMs));

/// A full day label for chat date separators: "오늘", "어제", or a date.
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

/// RSSI(+hop count) → coarse proximity: a user-facing label and a radar ring
/// index (0 = innermost/closest … 3 = outermost). Absolute BLE distance is
/// unreliable, so we only claim honest buckets; multihop peers always sit on
/// the outer ring regardless of signal.
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
