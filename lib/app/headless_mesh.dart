import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path/path.dart' as p;

import '../core/ble/mesh_transport.dart' show bleLogSink;
import '../data/app_database.dart';
import '../data/identity_store.dart';
import 'background_service.dart';
import 'mesh_controller.dart';
import 'mesh_host.dart';
import 'notification_service.dart';
import 'app_paths.dart';

/// Android 포그라운드 서비스 자체 isolate의 진입점 — 메시의 단일 소유자
/// (SINGLE OWNER, v1.4.0).
///
/// 메시 노드는 서비스가 UI에 의해 시작됐든 시스템에 의해 시작됐든(부팅 /
/// 스와이프킬 재시작 / 앱 업데이트 / OEM 킬 복구) 여기, 오직 여기에만(ONLY)
/// 존재한다. UI isolate는 존재할 경우 task 포트를 통해 얇은 클라이언트로
/// 붙으며([MeshHost] / RemoteMeshController 참고), 자신만의 BLE 스택은 결코
/// 열지 않는다.
///
/// 이력: v1.3.2–1.3.5는 UI가 죽어 있을 때만 여기서 두 번째(SECOND) 메시를
/// 돌리고 ping/pong, 이어 파일, 다시 prefs 하트비트로 소유권을 조율했다 —
/// 모든 방식이 결국 경쟁 상태를 일으켜 GATT 서버를 이중화했고, iOS central은
/// 그런 상태로는 연결할 수 없다. v1.3.6은 헤드리스 메시를 완전히 제거했다
/// (스와이프킬 후 릴레이 없음). 단일 소유권은 조율 문제를 이기려 애쓰는 대신
/// 아예 없애 버린다.
@pragma('vm:entry-point')
void headlessMeshMain() {
  // 서비스 isolate에 **잡히지 않은 에러 핸들러를 건다** — UI isolate([Bootstrap]의
  // _wireBleFileLog)에는 있는데 여기엔 없던 치명적 비대칭이었다.
  //
  // 왜 치명적인가: 안드로이드에서 메시는 **오직 이 isolate**가 소유한다(단일
  // 소유자). 이 isolate엔 root-zone uncaught 핸들러가 없어서, 타이머 콜백·BLE
  // 이벤트·파일 IO 등 어떤 async 경로에서 예외가 하나만 새어도 isolate 전체가
  // 조용히 죽었다 → 광고·스캔 정지(= 아무에게도 발견되지 않음). 그런데 네이티브
  // 웨이크 토치는 프로세스 전역이라 계속 타올라(유령 토치) 친구들의 iPhone을
  // 헛되이 깨웠다: "주변에 친구가 있어요" 알림은 오는데 정작 앱을 열면 아무도
  // 없는 정확한 증상(2026-07-30·09-18 heavy: saw>0 spot=0, 상대 광고 전무).
  //
  // UI isolate와 똑같이 삼켜서 생존시키고, 원인을 ble-service.log에 남긴다 —
  // 단일 소유 노드에서는 "예외로 죽는 것"보다 "살아서 계속 릴레이하는 것"이
  // 언제나 옳다. bleLogSink는 onStart→_wireServiceLog에서 연결되므로, 그 전에
  // 난 예외는 로그가 안 남을 수 있으나 isolate 생존(return true)은 보장된다.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    bleLogSink?.call(
        'SERVICE FLUTTER ERROR: ${details.exception}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    bleLogSink?.call('SERVICE UNCAUGHT: $error\n$stack');
    return true; // 처리됨 — isolate를 죽이지 않는다
  };
  FlutterForegroundTask.setTaskHandler(_MeshOwnerHandler());
}

class _MeshOwnerHandler extends TaskHandler {
  MeshController? _controller;
  MeshHost? _host;
  bool _starting = false;
  Timer? _retryTimer;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _startMesh();
    // 아직 신원 없음(온보딩이 끝나기 전 최초 실행) 또는 일시적 부팅 실패:
    // UI로부터 어떤 신호도 없이, 가능해지는 순간 메시가 스스로 올라오도록
    // 계속 재시도한다.
    _retryTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _startMesh());
  }

  Future<void> _startMesh() async {
    if (_controller != null || _starting) return;
    _starting = true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      // 서비스의 백그라운드 엔진은 Dart 플러그인 구현을 자동 등록하지
      // 않는다(NOT). 이것이 없으면 모든 플러그인 채널(BLE, sqflite, secure
      // storage, notifications)이 MissingPluginException을 던진다.
      DartPluginRegistrant.ensureInitialized();
      await _wireServiceLog();
      await NotificationService.init();
      final store = IdentityStore();
      final name = await store.storedName();
      // 이 기기에서 온보딩이 완료된 적 없음: 아직 실행할 것이 없다.
      if (name == null || name.trim().isEmpty) return;
      final identity = await store.loadOrCreate();
      final controller = MeshController(
        identity: identity,
        displayName: name,
        db: AppDatabase(),
        identityStore: store,
        headless: true,
      );
      await controller.init();
      _controller = controller;
      _host = MeshHost(controller);
      await BackgroundService.updateStatus(controller.linkCount);
      bleLogSink?.call('MESH service owner up (started=${controller.started})');
    } catch (e) {
      // 최선의 노력(best-effort): 시작 실패가 서비스를 크래시시키는 일은 절대
      // 없어야 한다 — 재시도 타이머가(그리고 다음 시스템 재시작이) 다시 시도한다.
      bleLogSink?.call('MESH service start failed: $e');
    } finally {
      _starting = false;
    }
  }

  /// 서비스 isolate 진단 로그를 Documents/ble-service.log에 미러링한다 — 두
  /// isolate에서의 동시 추가 기록이 서로 뒤섞이지 않도록 UI isolate의 ble.log와
  /// 분리한다. ble.log처럼 `devicectl`/`adb`로 꺼낸다.
  Future<void> _wireServiceLog() async {
    if (bleLogSink != null) return; // 이 isolate에서는 이미 연결됨
    try {
      final dir = await AppPaths.dataDir();
      final file = File(p.join(dir.path, 'ble-service.log'));
      if (file.existsSync() && file.lengthSync() > 256 * 1024) {
        file.deleteSync();
      }
      final sink = file.openWrite(mode: FileMode.append);
      sink.writeln(
          '=== mesh service start ${DateTime.now().toIso8601String()} ===');
      bleLogSink =
          (line) => sink.writeln('${DateTime.now().toIso8601String()} $line');
    } catch (_) {} // 진단 전용
  }

  @override
  void onReceiveData(Object data) {
    _host?.handle(data);
    // 우리가 꺼져 있는 동안 들어온 명령(예: 온보딩 직후): 부팅을 시도한다.
    if (_controller == null) _startMesh();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _host?.dispose();
    _host = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      try {
        await controller.node.dispose();
        controller.dispose();
      } catch (_) {}
    }
  }
}
