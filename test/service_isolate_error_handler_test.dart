import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spot_link/app/headless_mesh.dart';
import 'package:spot_link/core/ble/mesh_transport.dart' show bleLogSink;

/// 안드로이드 메시 사망(유령 토치) 근본 수정의 계약 검증.
///
/// 실기기 UX 검증(heavy가 안드로이드를 발견)은 물리 행동이 필요하지만, 수정의
/// 핵심 계약 — "서비스 isolate 전역 에러 핸들러가 async 예외를 삼켜 isolate를
/// 죽이지 않는다" — 는 여기서 자동 검증한다. 이 계약이 깨지면(예: 누군가
/// return false로 바꾸거나 핸들러 설치를 제거) 안드로이드 메시가 다시 조용히
/// 죽어 "친구 알림 오는데 안 보임"이 재발한다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 전역 상태를 건드리므로 앞뒤로 백업/복원한다.
  late void Function(FlutterErrorDetails) prevFlutter;
  ErrorCallback? prevPlatform;
  void Function(String)? prevSink;

  setUp(() {
    prevFlutter = FlutterError.onError!;
    prevPlatform = PlatformDispatcher.instance.onError;
    prevSink = bleLogSink;
  });

  tearDown(() {
    FlutterError.onError = prevFlutter;
    PlatformDispatcher.instance.onError = prevPlatform;
    bleLogSink = prevSink;
  });

  test('async uncaught 예외를 삼켜(return true) isolate를 살린다', () {
    final logged = <String>[];
    bleLogSink = logged.add;

    installServiceIsolateErrorHandlers();

    final handler = PlatformDispatcher.instance.onError;
    expect(handler, isNotNull,
        reason: 'PlatformDispatcher.onError가 설치돼야 root-zone async 예외를 잡는다');

    // 서비스 isolate에서 타이머/BLE 콜백이 던지는 것과 같은 uncaught 예외.
    final swallowed = handler!(StateError('boom in timer'), StackTrace.current);

    expect(swallowed, isTrue,
        reason: 'return true여야 예외가 isolate를 죽이지 않는다 — '
            'false면 안드로이드 메시가 다시 조용히 죽어 유령 토치가 된다');
    expect(logged.any((l) => l.contains('SERVICE UNCAUGHT') &&
        l.contains('boom in timer')), isTrue,
        reason: '원인을 ble-service.log에 남겨 다음 사건의 스택을 확보해야 한다');
  });

  test('FlutterError.onError도 설치된다(프레임워크/플러그인 동기 에러)', () {
    bleLogSink = (_) {};
    final before = FlutterError.onError;
    installServiceIsolateErrorHandlers();
    expect(FlutterError.onError, isNotNull);
    expect(FlutterError.onError, isNot(same(before)),
        reason: '서비스 전용 핸들러로 교체돼야 한다');
  });

  test('bleLogSink가 아직 없어도 예외를 삼킨다(부팅 초기 창)', () {
    // onStart→_wireServiceLog 이전엔 sink가 null이다. 그 창에서도 isolate
    // 생존(return true)은 보장돼야 한다 — 로그만 못 남길 뿐.
    bleLogSink = null;
    installServiceIsolateErrorHandlers();
    final handler = PlatformDispatcher.instance.onError!;
    expect(() => handler(StateError('early boom'), StackTrace.current),
        returnsNormally);
    expect(handler(StateError('early boom'), StackTrace.current), isTrue);
  });
}
