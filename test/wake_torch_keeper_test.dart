import 'package:flutter_test/flutter_test.dart';

import 'package:spot_link/app/wake_torch_keeper.dart';

/// Android 웨이크 토치가 꺼진 채 굳지 않는지 고정한다. 토치는 죽은 친구
/// iPhone 앱을 되살리는 유일한 비콘인데, 서비스 isolate에는 꺼진 토치를 다시
/// 켜는 경로가 없었다(슬롯 양보·네이티브 심박 게이트 뒤 영구 소등).
void main() {
  late DateTime now;
  late int starts;
  late int stops;
  late List<String> logs;
  late WakeTorchKeeper keeper;

  setUp(() {
    now = DateTime(2026, 10, 16, 0, 0);
    starts = 0;
    stops = 0;
    logs = [];
    keeper = WakeTorchKeeper(
      start: () async => starts++,
      stop: () async => stops++,
      log: logs.add,
      now: () => now,
    );
  });

  test('첫 틱에 토치를 확정하고, 이후엔 간격마다만 다시 확정한다', () {
    expect(keeper.tick(), isTrue);
    expect(starts, 1);
    now = now.add(const Duration(seconds: 10));
    expect(keeper.tick(), isFalse, reason: '10초 틱마다 네이티브를 두드리지 않는다');
    now = now.add(const Duration(seconds: 50));
    expect(keeper.tick(), isTrue, reason: '심박 게이트로 꺼졌어도 1분 안에 되살린다');
    expect(starts, 2);
  });

  test('슬롯을 양보하면 토치를 끄고, 유예 동안은 다시 켜지 않는다', () async {
    keeper.tick();
    await keeper.yieldSlot();
    expect(stops, 1);
    expect(keeper.holding, isTrue);
    expect(logs.last, contains('wake torch stopped'));

    now = now.add(const Duration(seconds: 90));
    expect(keeper.tick(), isFalse, reason: '곧바로 다시 켜면 메시 광고와 슬롯을 다투는 플랩이 된다');
    expect(starts, 1);
  });

  test('유예가 끝나면 토치를 다시 켠다 — 양보가 영구 소등이 되지 않는다', () async {
    keeper.tick();
    await keeper.yieldSlot();
    now = now.add(const Duration(minutes: 2, seconds: 1));
    expect(keeper.tick(), isTrue);
    expect(starts, 2);
    expect(keeper.holding, isFalse);
    expect(logs.last, contains('re-armed after slot yield'));
  });

  test('다시 켠 뒤에는 평소 간격으로 돌아간다', () async {
    await keeper.yieldSlot();
    now = now.add(const Duration(minutes: 3));
    expect(keeper.tick(), isTrue);
    now = now.add(const Duration(seconds: 30));
    expect(keeper.tick(), isFalse);
    now = now.add(const Duration(seconds: 31));
    expect(keeper.tick(), isTrue);
    expect(starts, 2);
  });
}
