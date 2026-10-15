import 'dart:async';

/// Android 웨이크 토치(iBeacon TX)가 **꺼진 채 굳지 않게** 지키는 관리자.
///
/// Android의 토치는 항상 켜져 있어야 한다: 스와이프 종료·재부팅으로 죽은
/// 친구의 iPhone 앱을 되살리는 길은 이 비콘의 리전 ENTER뿐이다. 그런데 토치를
/// 끄는 경로는 둘인데 다시 켜는 경로가 서비스 isolate에는 없었다.
///
/// 1. 광고 슬롯 양보([yieldSlot]): 메시 광고가 code 2(TOO_MANY_ADVERTISERS)로
///    실패하면 토치를 내려 슬롯을 비운다(94e6be9). 재점화는 iOS용 펄스와
///    UI 수명주기에만 있었고 둘 다 헤드리스에선 돌지 않는다 — 다른 광고가
///    잠깐 세트를 다 쓴 순간 한 번만 경합해도 토치는 서비스가 재시작될
///    때까지 영구히 꺼졌다.
/// 2. 네이티브 심박 게이트: Dart 심박이 2.5분 끊기면 네이티브가 토치를 끈다.
///    isolate가 멈췄다 되살아나도 다시 켜 주는 쪽이 없었다.
///
/// 그러면 iPhone 앱이 죽은 동안 깨워 줄 비콘이 없어, 둘이 같은 공간에 있어도
/// 며칠씩 서로 못 본다(2026-10-07~16 heavy: 집에 삼성 친구가 있는데 9일간
/// 웨이크 0건, 앱을 손으로 연 00:28에 즉시 링크 — 이 경로로 설명되는 사례).
/// [tick]을 주기적으로 불러 토치를 다시 확정한다. 네이티브
/// startTx는 멱등이라(이미 광고 중이면 그대로, 로테이션 중복 없음) 반복 호출이
/// 싸다. 단일 슬롯 기기에서는 메시 광고가 슬롯을 쥐고 있어 재점화가 조용히
/// 실패할 뿐이다(메시 광고가 우선이라는 원칙은 그대로).
class WakeTorchKeeper {
  WakeTorchKeeper({
    required this.start,
    required this.stop,
    this.log,
    DateTime Function()? now,
    this.rearmEvery = const Duration(seconds: 60),
    this.yieldHold = const Duration(minutes: 2),
  }) : _now = now ?? DateTime.now;

  /// 네이티브 토치 시작(멱등).
  final Future<void> Function() start;

  /// 네이티브 토치 정지.
  final Future<void> Function() stop;

  /// 진단 로그(ble-service.log).
  final void Function(String line)? log;

  final DateTime Function() _now;

  /// 토치를 다시 확정하는 간격.
  final Duration rearmEvery;

  /// 슬롯을 양보한 뒤 토치를 쉬게 하는 시간 — 곧바로 다시 켜서 메시 광고와
  /// 슬롯을 다투는 플랩을 막는다.
  final Duration yieldHold;

  DateTime? _yieldedAt;
  DateTime? _lastStart;

  /// 지금 슬롯 양보로 쉬는 중인가(진단·테스트용).
  bool get holding {
    final y = _yieldedAt;
    return y != null && _now().difference(y) < yieldHold;
  }

  /// 메시 광고에 슬롯을 내준다. [yieldHold] 동안은 [tick]이 다시 켜지 않는다.
  Future<void> yieldSlot() async {
    _yieldedAt = _now();
    log?.call('wake torch stopped — mesh advertising needs the BLE slot');
    await stop();
  }

  /// 주기 틱(메시 컨트롤러의 10초 타이머)에서 호출한다. 다시 켤 때가 됐으면
  /// [start]를 부르고 true를 돌려준다.
  bool tick() {
    final now = _now();
    final yielded = _yieldedAt;
    if (yielded != null) {
      if (now.difference(yielded) < yieldHold) return false;
      _yieldedAt = null;
      _lastStart = now;
      log?.call('wake torch re-armed after slot yield');
      unawaited(start());
      return true;
    }
    final last = _lastStart;
    if (last != null && now.difference(last) < rearmEvery) return false;
    _lastStart = now;
    unawaited(start());
    return true;
  }
}
