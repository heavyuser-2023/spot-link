/// Message-type and command names for the UI ↔ service JSON bridge
/// ([RemoteMeshController] ↔ [MeshHost]).
///
/// Both sides reference these constants, so adding or renaming a command is
/// one edit here — and a typo becomes a compile error instead of a silently
/// dropped message.
abstract final class Bridge {
  // ---- service → UI message types (key: 't') ----
  static const typeSnapshot = 'snap';
  static const typeError = 'err';

  // ---- UI → service commands (key: 'c') ----
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
