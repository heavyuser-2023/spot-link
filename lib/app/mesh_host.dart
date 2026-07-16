import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../core/ble/mesh_transport.dart' show bleLogSink;
import 'bridge_protocol.dart';
import 'mesh_controller.dart';

/// UI 브리지의 서비스 isolate 쪽: 유일하게 진짜인 [MeshController]를
/// 포그라운드 task 포트를 통해 JSON 메시지로 (선택적) UI isolate에 노출한다.
///
/// 프로토콜:
///  UI → service: `{"c": command, ...args}`  ([handle] 참고)
///  service → UI: `{"t":"snap", ...state}`   스로틀된 전체 스냅샷
///                `{"t":"err","m":...}`      일시적 오류 → 스낵바
///
/// 채팅 기록 자체는 절대 포트를 건너지 않는다 — 두 isolate가 SQLite 파일(WAL)을
/// 공유하므로, UI는 스냅샷의 `rev` 카운터가 움직일 때마다 열려 있는 대화를
/// 다시 로드한다.
class MeshHost {
  final MeshController controller;

  Timer? _throttle;
  Timer? _uiStaleTimer;
  StreamSubscription? _errSub;

  /// UI isolate로부터의 마지막 신호. 이것이 조용해지면(스와이프킬 — 'bye'가
  /// 오지 않음) 백그라운드 알림 동작으로 되돌린다.
  DateTime _lastUiSignal = DateTime.fromMillisecondsSinceEpoch(0);
  bool _uiForeground = false;

  MeshHost(this.controller) {
    controller.addListener(_scheduleSnapshot);
    _errSub = controller.errorEvents.listen(
        (m) => _send({'t': Bridge.typeError, 'm': m}));
    // UI keepalive는 존재하는 동안 약 10초마다 틱을 보낸다; 35초의 침묵은 UI
    // isolate가 사라졌음(또는 얼어붙었음)을 뜻한다 — 알림을 재개한다.
    _uiStaleTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_uiForeground) return;
      if (DateTime.now().difference(_lastUiSignal) >
          const Duration(seconds: 35)) {
        _uiForeground = false;
        controller.setRemoteForeground(false);
        controller.closeConversation();
      }
    });
    _scheduleSnapshot();
  }

  /// 곧 새 스냅샷을 보내되, 몰아치는 것을 합친다(RSSI 샘플은 피어마다 몇 초에
  /// 한 번씩 도착한다; notifyListeners마다 직렬화하면 낭비가 심할 것이다).
  void _scheduleSnapshot() {
    _throttle ??= Timer(const Duration(milliseconds: 250), () {
      _throttle = null;
      _send({'t': Bridge.typeSnapshot, ...controller.snapshotForRemote()});
    });
  }

  void _send(Map<String, Object?> m) {
    try {
      FlutterForegroundTask.sendDataToMain(jsonEncode(m));
    } catch (_) {} // 붙어 있는 UI 없음 — 괜찮다
  }

  Future<void> handle(Object data) async {
    if (data is! String) return;
    Map<String, Object?> m;
    try {
      m = (jsonDecode(data) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    _lastUiSignal = DateTime.now();
    final c = controller;
    try {
      switch (m['c']) {
        case Bridge.cmdHello:
          _scheduleSnapshot();
        case Bridge.cmdForeground:
          _uiForeground = m['v'] == true;
          c.setRemoteForeground(_uiForeground);
        case Bridge.cmdBye:
          _uiForeground = false;
          c.setRemoteForeground(false);
          c.closeConversation();
        case Bridge.cmdOpen:
          await c.openConversation(m['p'] as String);
        case Bridge.cmdClose:
          c.closeConversation();
        case Bridge.cmdSendText:
          await c.sendText(m['p'] as String, m['x'] as String);
        case Bridge.cmdRetryText:
          await c.retryTextById(m['p'] as String, m['id'] as String);
        case Bridge.cmdSendFile:
          await _sendFile(m);
        case Bridge.cmdRetryFile:
          await c.retryFileById(m['p'] as String, m['id'] as String);
        case Bridge.cmdCancelFile:
          await c.cancelFileById(m['id'] as String);
        case Bridge.cmdDeleteMessage:
          await c.deleteMessageById(m['p'] as String, m['id'] as String);
        case Bridge.cmdAddContact:
          await c.addContactFromBundle(
            base64Decode(m['b'] as String),
            name: m['name'] as String?,
            verified: m['v'] != false,
          );
        case Bridge.cmdDeleteContact:
          await c.deleteContact(m['p'] as String);
        case Bridge.cmdRenameContact:
          await c.renameContact(m['p'] as String, m['name'] as String);
        case Bridge.cmdSetName:
          await c.setDisplayName(m['v'] as String);
        case Bridge.cmdSetSaver:
          c.setPowerSaver(m['v'] == true);
        case Bridge.cmdClearRelay:
          await c.clearRelayStore();
      }
    } catch (e) {
      bleLogSink?.call('MeshHost command ${m['c']} failed: $e');
      _send({'t': 'err', 'm': '$e'});
    }
  }

  /// UI가 경로를 넘겨준다(바이트는 절대 포트를 건너지 않으며, 여기서 페이로드가
  /// RAM에 올라오는 일도 없다 — 컨트롤러가 네이티브 File.copy로 복사하고 디스크에서
  /// 청크를 스트리밍한다). outbox 임시 파일은 우리가 삭제할 몫이고, 피커 경로는
  /// OS 캐시 소유이므로 건드리지 않는다.
  Future<void> _sendFile(Map<String, Object?> m) async {
    final path = m['path'] as String;
    try {
      await controller.sendFilePath(
        m['p'] as String,
        path: path,
        name: m['name'] as String,
        mime: m['mime'] as String,
      );
    } finally {
      if (path.contains(
          '${Platform.pathSeparator}outbox${Platform.pathSeparator}')) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }

  void dispose() {
    controller.removeListener(_scheduleSnapshot);
    _errSub?.cancel();
    _throttle?.cancel();
    _throttle = null;
    _uiStaleTimer?.cancel();
  }
}
