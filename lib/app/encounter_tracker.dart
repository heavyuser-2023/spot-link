import 'dart:async';
import 'dart:math' as math;

import '../data/app_database.dart';
import '../data/models.dart';
import 'device_location.dart';

/// "스쳐간 친구" 기록과 친구별 자동 메시지의 규칙 — 메시를 소유한
/// [MeshController]가 프레즌스 이벤트를 흘려 넣는다.
///
/// 플랫폼·플러그인을 직접 부르지 않고 시계·DB·위치·전송을 주입받아, 규칙
/// 전체를 단위 테스트로 고정한다(test/encounter_tracker_test.dart).
///
/// **누구인지는 연결돼야만 안다.** 웨이크 비콘은 모든 SpotLink 기기가 같은
/// 신호를 내 신원이 없다. 그래서 두 경로로 기록한다:
///  - [onPeerSeen]: 연결돼 ANNOUNCE를 받았다 → 이름까지 남긴다.
///  - [onUnidentifiedNearby]: 비콘으로 "누군가 근처"만 알았다 → 미확인으로
///    남기고, 곧이어 연결되면 그 사람으로 승격한다.
class EncounterTracker {
  EncounterTracker({
    required this.db,
    required this.locate,
    required this.sendAuto,
    required this.isForeground,
    required this.locationEnabled,
    this.onChanged,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppDatabase db;

  /// 지금 위치. 정책상 붙일 수 없거나 실패하면 null.
  final Future<LocationFix?> Function() locate;

  /// 자동 메시지를 실제로 보낸다(평소 메시지 전송 경로).
  final Future<void> Function(String peerHex, String text) sendAuto;

  /// 사용자가 지금 앱 화면을 보고 있는가 — "놓친 만남" 판정의 근거.
  final bool Function() isForeground;
  final Future<bool> Function() locationEnabled;

  /// 기록이 바뀌었다(화면 새로고침 신호).
  final void Function()? onChanged;
  final DateTime Function() _now;

  /// 이만큼 안 보이다 다시 보이면 **새 만남**으로 친다. ANNOUNCE 주기(15초)와
  /// 프레즌스 TTL(40초)보다 넉넉히 길어, 잠깐의 끊김은 같은 만남으로 잇는다.
  static const Duration gap = Duration(minutes: 5);

  /// 같은 친구에게 자동 메시지를 다시 보내기까지의 최소 간격. 같은 사무실·
  /// 동네에서 하루에도 수십 번 스치는 사이에 인사가 쏟아지지 않게 한다.
  static const Duration autoCooldown = Duration(hours: 6);

  /// 진행 중인 만남의 끝 시각을 DB에 쓰는 최소 간격. ANNOUNCE는 피어마다
  /// 15초마다 오므로 매번 쓰면 100명 규모에서 쓰기가 끊이지 않는다.
  static const Duration touchEvery = Duration(seconds: 60);

  /// 비콘 감지를 무시할 "이미 누군가와 함께 있음" 창 — 그 비콘은 지금 연결된
  /// 그 사람의 것일 가능성이 크다.
  static const Duration _withSomeone = Duration(seconds: 60);

  final Map<String, _Open> _open = {};

  /// 같은 피어의 새 만남을 두 번 만들지 않기 위한 표식 — ANNOUNCE는 여러
  /// 링크(C:/P:)로 거의 동시에 겹쳐 도착한다.
  final Set<String> _creating = {};

  int get _t => _now().millisecondsSinceEpoch;

  /// 연결된 친구의 ANNOUNCE를 받았다.
  Future<void> onPeerSeen(Contact contact, {required int hops}) async {
    final peer = contact.peerHex;
    final t = _t;
    final fg = isForeground();
    final open = _open[peer];
    if (open != null && t - open.lastSeen < gap.inMilliseconds) {
      await _extend(open, t, hops, fg);
      return;
    }
    if (!_creating.add(peer)) return;
    try {
      // 재시작 직후: DB에는 아직 이어지는 만남이 있다 — 새로 만들지 않고 잇는다.
      final last = await db.latestEncounterFor(peer);
      if (last != null && t - last.endedAt < gap.inMilliseconds) {
        final o = _open[peer] = _Open(
          last.id,
          t,
          t,
          math.min(last.hops, hops),
          last.missed,
        );
        await _extend(o, t, hops, fg, force: true);
        await _maybeAutoMessage(
          contact,
          last.id,
          t,
          alreadySent: last.autoSent,
        );
        return;
      }
      // 직전에 비콘으로만 잡혔던 "누군가"가 바로 이 친구였다 — 승격한다.
      final pending = await db.latestUnidentifiedSince(t - gap.inMilliseconds);
      final int id;
      if (pending != null) {
        id = pending.id;
        await db.identifyEncounter(id, peer, endedAt: t, hops: hops);
        if (fg && pending.missed) {
          await db.extendEncounter(id, endedAt: t, hops: hops, missed: false);
        }
      } else {
        id = await db.insertEncounter(
          peerHex: peer,
          at: t,
          hops: hops,
          source: EncounterSource.link,
          missed: !fg,
        );
      }
      // 승격된 비콘 만남은 그 기록의 놓침 여부를 잇되, 지금 보고 있다면 해제.
      final missed = pending != null ? (pending.missed && !fg) : !fg;
      _open[peer] = _Open(id, t, t, hops, missed);
      onChanged?.call();
      if (pending == null || !pending.hasLocation) {
        unawaited(_attachLocation(id));
      }
      await _maybeAutoMessage(contact, id, t, alreadySent: false);
    } finally {
      _creating.remove(peer);
    }
  }

  /// 웨이크 비콘 등으로 "SpotLink 친구가 근처에 있다"는 것만 알았다.
  Future<void> onUnidentifiedNearby() async {
    final t = _t;
    if (_open.values.any((o) => t - o.lastSeen < _withSomeone.inMilliseconds)) {
      return;
    }
    final recent = await db.latestUnidentifiedSince(t - gap.inMilliseconds);
    if (recent != null) {
      await db.extendEncounter(recent.id, endedAt: t, hops: recent.hops);
      onChanged?.call();
      return;
    }
    final id = await db.insertEncounter(
      peerHex: null,
      at: t,
      hops: 1,
      source: EncounterSource.beacon,
      missed: !isForeground(),
    );
    onChanged?.call();
    unawaited(_attachLocation(id));
  }

  Future<void> _extend(
    _Open o,
    int t,
    int hops,
    bool fg, {
    bool force = false,
  }) async {
    o.lastSeen = t;
    final newHops = math.min(o.hops, hops);
    final hopsChanged = newHops != o.hops;
    o.hops = newHops;
    // 만남 도중 한 번이라도 앱을 보고 있었다면 "놓친" 만남이 아니다.
    final seen = o.missed && fg;
    if (seen) o.missed = false;
    if (!force &&
        !seen &&
        !hopsChanged &&
        t - o.lastWrite < touchEvery.inMilliseconds) {
      return;
    }
    o.lastWrite = t;
    await db.extendEncounter(
      o.id,
      endedAt: t,
      hops: o.hops,
      missed: seen ? false : null,
    );
    onChanged?.call();
  }

  Future<void> _attachLocation(int id) async {
    try {
      if (!await locationEnabled()) return;
      final fix = await locate();
      if (fix == null) return;
      await db.setEncounterLocation(
        id,
        lat: fix.lat,
        lng: fix.lng,
        accuracy: fix.accuracy,
      );
      onChanged?.call();
    } catch (_) {} // 위치는 덤이다 — 만남 기록을 막지 않는다
  }

  Future<void> _maybeAutoMessage(
    Contact contact,
    int encounterId,
    int t, {
    required bool alreadySent,
  }) async {
    final text = contact.autoMessage;
    if (text == null || text.isEmpty || alreadySent) return;
    final last = await db.lastAutoSentAt(contact.peerHex);
    if (last != null && t - last < autoCooldown.inMilliseconds) return;
    try {
      // 표식을 먼저 남긴다: 전송 도중 같은 친구의 다음 ANNOUNCE가 겹쳐도
      // 두 번 보내지 않는다.
      await db.markEncounterAutoSent(encounterId);
      await sendAuto(contact.peerHex, text);
      onChanged?.call();
    } catch (_) {}
  }
}

class _Open {
  final int id;
  int lastSeen;
  int lastWrite;
  int hops;
  bool missed;
  _Open(this.id, this.lastSeen, this.lastWrite, this.hops, this.missed);
}
