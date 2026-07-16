import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/ble/mesh_transport.dart' show bleLogSink;
import '../data/app_database.dart';
import '../data/identity_store.dart';
import 'background_service.dart';
import 'mesh_controller.dart';
import 'mesh_host.dart';
import 'notification_service.dart';

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
      final dir = await getApplicationDocumentsDirectory();
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
