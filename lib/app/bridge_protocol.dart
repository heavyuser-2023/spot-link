/// UI ↔ 서비스 JSON 브리지([RemoteMeshController] ↔ [MeshHost])를 위한
/// 메시지 타입과 명령 이름.
///
/// 양쪽 모두 이 상수들을 참조하므로, 명령을 추가하거나 이름을 바꾸는 것은
/// 여기 한 곳만 수정하면 된다 — 그리고 오타는 조용히 버려지는 메시지가 아니라
/// 컴파일 오류가 된다.
abstract final class Bridge {
  // ---- 서비스 → UI 메시지 타입 (key: 't') ----
  static const typeSnapshot = 'snap';
  static const typeError = 'err';

  // ---- UI → 서비스 명령 (key: 'c') ----
  static const cmdHello = 'hello';
  static const cmdForeground = 'fg';
  static const cmdBye = 'bye';
  static const cmdOpen = 'open';
  static const cmdClose = 'close';
  static const cmdSendText = 'send';
  static const cmdRetryText = 'retryText';
  static const cmdSendFile = 'sendFile';
  static const cmdRetryFile = 'retryFile';
  static const cmdCancelFile = 'cancelFile';
  static const cmdDeleteMessage = 'delMsg';
  static const cmdAddContact = 'addContact';
  static const cmdDeleteContact = 'delContact';
  static const cmdRenameContact = 'renameContact';
  static const cmdSetName = 'name';
  static const cmdSetSaver = 'saver';
  static const cmdClearRelay = 'clearRelay';
}
