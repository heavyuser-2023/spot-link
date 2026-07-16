import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../core/ble/mesh_transport.dart' show bleLogSink;
import '../data/app_database.dart';
import '../data/identity_store.dart';
import '../features/guide_screen.dart';
import '../features/home_screen.dart';
import '../features/onboarding_screen.dart';
import 'background_service.dart';
import 'beacon_wake.dart';
import 'mesh_controller.dart';
import 'notification_service.dart';
import 'permissions.dart';
import 'remote_mesh_controller.dart';

/// 앱이 빈 시작 화면을 절대 보이지 않도록 브랜드 스플래시 뒤에서 일회성 비동기
/// 시작 작업을 실행한 뒤, 온보딩(최초 실행) 또는 홈으로 라우팅한다.
class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

enum _Stage { loading, onboarding, ready }

class _BootstrapState extends State<Bootstrap> {
  _Stage _stage = _Stage.loading;
  MeshFrontend? _controller;
  final _identityStore = IdentityStore();

  /// 최초 실행 가이드 게이트. 사용자가 "다시 보지 않기"를 체크했을 때만 작은
  /// 플래그 파일로 해제된다 — 체크하지 않으면 요청에 따라 다음 실행 때 다시
  /// 보게 된다. Me 탭에서 언제든 다시 볼 수 있다.
  bool _guideSeen = true;
  File? _guideFlagFile;

  /// 마지막 부팅 실패, 스플래시에 표시된다 — 불투명한 무한 스피너를 어떤
  /// 폰에서든 읽을 수 있는 진단으로 바꿔 준다.
  String? _bootError;

  /// BLE 스택이 올라온 뒤 발생하는 두 번째 웨이크 이벤트 드레인([_wireBleFileLog]
  /// 참고). 우리가 먼저 dispose될 경우 취소할 수 있도록 보관해 둔다.
  Timer? _lateWakeDrain;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await initializeDateFormatting('ko', null);
    await _wireBleFileLog();
    try {
      final dir = await getApplicationDocumentsDirectory();
      _guideFlagFile = File(p.join(dir.path, 'guide_seen'));
      _guideSeen = _guideFlagFile!.existsSync();
    } catch (_) {
      _guideSeen = true; // 저장소 문제: 가이드 때문에 진입을 막는 일은 절대 없게 한다
    }

    // 최초 실행(아직 이름 없음): OS 권한을 요청하기 전(BEFORE)에 온보딩을
    // 보여 준다. 그러지 않으면 권한 다이얼로그가 스플래시 위에 쌓여 온보딩
    // 화면을 가리고, 앱이 "로딩 중"에서 멈춘 것처럼 보인다 — 게다가 메시는
    // 이름이 설정된 뒤에야 시작되므로, 폰은 광고도 스캔도 전혀 하지 않는다
    // (온라인처럼 보이지만 발견되지 않음). 대신 권한은 [_onNameChosen]에서
    // 요청한다.
    final stored = await _identityStore.storedName();
    if (stored == null || stored.trim().isEmpty) {
      if (mounted) setState(() => _stage = _Stage.onboarding);
      return;
    }

    // 재방문 사용자: 서비스 + 권한을 먼저 올린 뒤 실행한다.
    await _step('알림 준비', () async {
      await BackgroundService.init();
      await NotificationService.init();
    });
    await _step(
        '권한 요청',
        () => Permissions.request()
            .timeout(const Duration(seconds: 45), onTimeout: () => false));
    await _startMesh(stored);
  }

  /// 부팅 단계 하나를 실행하며, 조용히 죽는 대신 실패를 스플래시에 드러낸다 —
  /// 이유 없이 멈춘 "로딩 중" 화면은 남의 폰에서는 디버깅이 불가능하다.
  Future<void> _step(String label, Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      bleLogSink?.call('bootstrap step "$label" failed: $e');
      if (mounted) setState(() => _bootError = '$label 실패: $e');
    }
  }

  /// 메시를 부팅하며, 실패 시 재시도한다. 잠긴 폰에서의 백그라운드 재실행(BLE 상태
  /// 복원 / 비콘 웨이크)은 Keychain을 읽을 수 없다(errSecInteractionNotAllowed) —
  /// 재시도한다는 것은, 조용히 죽는 대신 사용자가 잠금을 푸는 순간 노드가 스스로
  /// 올라온다는 뜻이다.
  Future<void> _startMesh(String name) async {
    for (var attempt = 0;; attempt++) {
      try {
        await _launch(name);
        if (mounted && _bootError != null) {
          setState(() => _bootError = null);
        }
        return;
      } catch (e) {
        bleLogSink?.call('bootstrap failed (attempt $attempt): $e');
        if (!mounted) return;
        // 무엇이 잘못됐는지 스플래시에 바로 보여줘서, 멈춘 폰을 화면을 읽는 것만으로
        // 진단할 수 있게 한다.
        setState(() => _bootError = '시작 실패 (${attempt + 1}회): $e');
        await Future<void>.delayed(Duration(seconds: attempt < 6 ? 10 : 60));
        if (!mounted) return;
      }
    }
  }

  Future<void> _onNameChosen(String name) async {
    await _identityStore.setDisplayName(name);
    if (mounted) setState(() => _stage = _Stage.loading);
    // 이제 사용자에게 이름이 생겼으니, 서비스를 올리고 메시가 필요로 하는 OS 권한을
    // 요청한 뒤 시작한다.
    await _step('알림 준비', () async {
      await BackgroundService.init();
      await NotificationService.init();
    });
    await _step(
        '권한 요청',
        () => Permissions.request()
            .timeout(const Duration(seconds: 45), onTimeout: () => false));
    await _startMesh(name);
  }

  Future<void> _launch(String name) async {
    final identity = await _identityStore.loadOrCreate();
    final db = AppDatabase();
    final MeshFrontend controller;
    if (Platform.isAndroid) {
      // 단일 소유자 구조: foreground 서비스가 유일한 메시를 소유한다; 이 isolate는
      // 그것을 미러링만 하며 BLE 스택을 결코 열어서는 안 된다.
      final remote = RemoteMeshController(
        identity: identity,
        displayName: name,
        db: db,
        identityStore: _identityStore,
      );
      await remote.init(); // 서비스를 시작하고, 그 첫 스냅샷을 기다린다
      controller = remote;
    } else {
      final local = MeshController(
        identity: identity,
        displayName: name,
        db: db,
        identityStore: _identityStore,
      );
      await local.init();
      controller = local;
    }
    if (!mounted) {
      // 실행 도중 언마운트됨: 컨트롤러의 타이머/구독을 누수시키지 않는다.
      controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _stage = _Stage.ready;
    });
  }

  /// BLE 진단을 Documents/ble.log에 미러링하여, 릴리스 빌드를 기기에서 진단할 수
  /// 있게 한다(`devicectl device copy from --domain-type appDataContainer`로 파일을
  /// 가져온다). 콘솔 출력은 릴리스에서 버려진다.
  Future<void> _wireBleFileLog() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'ble.log'));
      // 실행을 거듭해도 크기가 제한되도록 유지한다.
      if (file.existsSync() && file.lengthSync() > 256 * 1024) {
        file.deleteSync();
      }
      final sink = file.openWrite(mode: FileMode.append);
      // 실행 중인 바이너리의 버전을 찍는다: 설치된 업데이트는 재실행할 때만
      // 반영되며, "실제로 어느 빌드가 이걸 보내고/받았나?"라는 물음이 예전 현장
      // 진단에서 우리를 곤란하게 한 적이 있다(디스크의 번들은 이미 더 최신인데,
      // 오래된 프로세스가 옛 wire-format 코드를 돌리고 있었다).
      var ver = '';
      try {
        final info = await PackageInfo.fromPlatform();
        ver = ' v${info.version}+${info.buildNumber}';
      } catch (_) {}
      sink.writeln(
          '=== app start$ver ${DateTime.now().toIso8601String()} ===');
      bleLogSink = (line) =>
          sink.writeln('${DateTime.now().toIso8601String()} $line');

      // 웨이크 원인 진단: 이번 부팅을 iBeacon 경로 대 BLE 상태 복원 중 어느 쪽으로
      // 귀속시키고, iBeacon 재실행이 의존하는 "항상" 위치 권한이 여전히 유효한지
      // 기록한다. 최선의 노력이며; 시작을 절대 막지 않는다.
      final loggedWakeEvents = <String>{};
      try {
        final now = DateTime.now().toIso8601String();
        final s = await BeaconWake.status();
        sink.writeln(
            '$now wake: beacon auth=${s['auth']} monitoring=${s['monitoring']}');
        for (final e in await BeaconWake.wakeEvents()) {
          loggedWakeEvents.add(e);
          sink.writeln('$now wake-event: $e');
        }
      } catch (_) {}

      // willRestoreState는 CoreBluetooth 매니저가 생성되는 동안 발생하는데, 이는
      // 메시 시작 중에 — 즉 이 이른 드레인 이후에 일어난다. 두 번째 패스가 없으면
      // 복원 이벤트는 다음 부팅의 드레인에서야 드러난다. 스택이 올라온 뒤 다시 읽어서
      // ble-*-restore 이벤트가 같은 세션의 로그에 담기도록 한다. 최선의 노력이며;
      // 이른 드레인과 중복 제거된다.
      _lateWakeDrain = Timer(const Duration(seconds: 8), () async {
        try {
          for (final e in await BeaconWake.wakeEvents()) {
            if (loggedWakeEvents.add(e)) {
              bleLogSink?.call('wake-event (late): $e');
            }
          }
        } catch (_) {}
      });

      // 잡히지 않은 에러를 같은 파일로 보낸다: 릴리스 모드에서 위젯 빌드 예외는
      // 조용한 빈 화면으로 렌더링되므로, 이것이 실제 기기에서 그 흔적을 남기는 유일한
      // 방법이다.
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        bleLogSink?.call('FLUTTER ERROR: ${details.exception}\n${details.stack}');
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        bleLogSink?.call('UNCAUGHT: $error\n$stack');
        return true;
      };
    } catch (_) {
      // 진단 전용 — 로깅 때문에 시작을 절대 막지 않는다.
    }
  }

  @override
  void dispose() {
    _lateWakeDrain?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return _Splash(error: _bootError);
      case _Stage.onboarding:
        return OnboardingScreen(onSubmit: _onNameChosen);
      case _Stage.ready:
        if (!_guideSeen) {
          return GuideScreen(
            firstRun: true,
            onDone: (dontShowAgain) {
              if (dontShowAgain) {
                try {
                  _guideFlagFile?.writeAsStringSync('1');
                } catch (_) {}
              }
              setState(() => _guideSeen = true);
            },
          );
        }
        return ChangeNotifierProvider.value(
          value: _controller!,
          child: const HomeScreen(),
        );
    }
  }
}

class _Splash extends StatelessWidget {
  final String? error;
  const _Splash({this.error});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.primary,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hub, size: 72, color: scheme.onPrimary),
              const SizedBox(height: 16),
              Text('SpotLink',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: scheme.onPrimary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: scheme.onPrimary),
              ),
              if (error != null) ...[
                const SizedBox(height: 24),
                Text(
                  '$error\n자동으로 다시 시도합니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: scheme.onPrimary.withValues(alpha: 0.9),
                      fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
