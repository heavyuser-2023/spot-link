import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:provider/provider.dart';

import '../app/app_share.dart';
import '../app/build_flags.dart';
import '../app/mesh_controller.dart';
import '../core/ble/mesh_transport.dart' show bleLogSink;
import '../core/model/peer_id.dart';
import '../data/models.dart';
import 'ui_utils.dart';

class ChatScreen extends StatefulWidget {
  final String peerHex;
  const ChatScreen({super.key, required this.peerHex});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

enum _AttachSource { gallery, file, apk }

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastCount = 0;
  MeshFrontend? _controller;

  /// 사용자가 위로 스크롤해 이전 기록을 읽는 동안 메시지가 도착하면 true.
  /// 스크롤 위치를 강제로 끌어내리지 않고, 떠 있는 "새 메시지" 칩으로
  /// 알려 준다.
  bool _showNewMsgChip = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MeshFrontend>().openConversation(widget.peerHex);
      _jumpToBottom();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = context.read<MeshFrontend>();
  }

  @override
  void dispose() {
    // 캡처해 둔 참조를 사용: dispose 중에는 context가 무효화된다.
    _controller?.closeConversation();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    try {
      await context.read<MeshFrontend>().sendText(widget.peerHex, text);
      bleLogSink?.call('chat send ok (${text.length} chars)');
    } catch (e, st) {
      bleLogSink?.call('chat send failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('전송 실패: $e')),
        );
      }
    }
    _animateToBottom();
  }

  Future<void> _attach() async {
    // 어디서 고를지 묻는다: 사진 갤러리 또는 파일 브라우저.
    final source = await showModalBottomSheet<_AttachSource>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor:
                    Theme.of(sheet).colorScheme.primaryContainer,
                child: const Icon(Icons.photo_library_outlined),
              ),
              title: const Text('사진·동영상'),
              subtitle: const Text('갤러리에서 선택 (여러 장 가능)'),
              onTap: () => Navigator.pop(sheet, _AttachSource.gallery),
            ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor:
                    Theme.of(sheet).colorScheme.secondaryContainer,
                child: const Icon(Icons.insert_drive_file_outlined),
              ),
              title: const Text('파일'),
              subtitle: const Text('문서·압축 등 모든 파일'),
              onTap: () => Navigator.pop(sheet, _AttachSource.file),
            ),
            if (Platform.isAndroid && !kStoreBuild)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      Theme.of(sheet).colorScheme.tertiaryContainer,
                  child: const Icon(Icons.android),
                ),
                title: const Text('SpotLink 앱 보내기'),
                subtitle: const Text('설치 파일(APK)을 전달 — 스토어 없이 설치'),
                onTap: () => Navigator.pop(sheet, _AttachSource.apk),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    if (source == _AttachSource.apk) {
      await _sendApk();
      return;
    }

    // 갤러리는 플랫폼 미디어 피커(iOS는 PHPicker, Android는 갤러리)를 쓰며
    // 다중 선택을 허용한다. 파일은 단일 선택 브라우저를 그대로 쓴다.
    // withData: false — 피커가 경로를 넘겨주고, 디스크 기반 전송은 페이로드를
    // RAM에 절대 올리지 않는다(예전에는 선택한 동영상이 몇 분에 걸친 전송
    // 내내 Dart 힙에 상주했다).
    final result = await FilePicker.platform.pickFiles(
      type: source == _AttachSource.gallery ? FileType.media : FileType.any,
      allowMultiple: source == _AttachSource.gallery,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    final controller = context.read<MeshFrontend>();
    for (final f in result.files) {
      final mime = lookupMimeType(f.name) ?? 'application/octet-stream';
      if (f.path != null) {
        await controller.sendFilePath(
          widget.peerHex,
          path: f.path!,
          name: f.name,
          mime: mime,
        );
      } else if (f.bytes != null) {
        // 경로가 없는 경우(드묾: 웹/가상 프로바이더) — 바이트로 대체.
        await controller.sendFile(
          widget.peerHex,
          bytes: f.bytes!,
          name: f.name,
          mime: mime,
        );
      }
    }
    _animateToBottom();
  }

  /// 설치된 자체 APK를 메시로 전송한다 — 수신자가 말풍선을 탭하면 설치되므로,
  /// 스토어도 인터넷도 없이 앱이 퍼진다.
  Future<void> _sendApk() async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = context.read<MeshFrontend>();
    final apk = await AppShare.apkFile();
    if (apk == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('설치 파일을 꺼내지 못했습니다')));
      return;
    }
    // 디스크 기반: ~76MB APK를 RAM에 읽어 들이는 것 자체가 jetsam을 유발했다.
    await controller.sendFilePath(
      widget.peerHex,
      path: apk.path,
      name: AppShare.apkName,
      mime: AppShare.apkMime,
    );
    _animateToBottom();
  }

  // 목록은 reverse: true(채팅 표준)로 렌더링하므로 offset 0이 곧 맨 아래다 —
  // 키보드 유무와 관계없이, 최신 말풍선이 오래된 maxScrollExtent에 잘릴 일이
  // 없다.
  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.offset < 240;
  }

  void _jumpToBottom() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _animateToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  void _onScroll() {
    if (_showNewMsgChip && _nearBottom) {
      setState(() => _showNewMsgChip = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    final contact = c.contactByHex(widget.peerHex);
    // 연락처가 아닐 때는 (내 것이 아니라) 상대의 짧은 id로 대체한다.
    final name = contact?.displayName ?? PeerId.fromHex(widget.peerHex).short;
    final messages = c.conversation(widget.peerHex);
    final nearby = c.isNearby(widget.peerHex);
    final hops = c.hopsTo(widget.peerHex);

    // 이미 맨 아래 근처면 새 메시지가 오면 자동 스크롤한다. 사용자가 이전
    // 기록을 읽는 중이면 강제로 끌어내리지 않고 "새 메시지" 칩을 제시한다.
    if (messages.length != _lastCount) {
      final grew = messages.length > _lastCount;
      _lastCount = messages.length;
      if (grew) {
        if (_nearBottom) {
          _animateToBottom();
        } else {
          _showNewMsgChip = true;
        }
      }
    }

    final items = _buildItems(messages);

    final presence = nearby
        ? (hops <= 1 ? '주변에 있음' : '주변 · $hops홉 경유')
        : '오프라인 · 전달 대기';

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showPeerSheet(context, c, name, presence, nearby),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 17,
                  backgroundColor: avatarColor(widget.peerHex),
                  foregroundColor: Colors.white,
                  child: Text(initialsOf(name),
                      style: const TextStyle(fontSize: 14)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          if (contact?.verified ?? false)
                            const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(Icons.verified,
                                  size: 15, color: Colors.blue),
                            ),
                        ],
                      ),
                      Text(
                        presence,
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: nearby
                                      ? const Color(0xFF2E7D32)
                                      : Theme.of(context).hintColor,
                                ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const _EmptyChat()
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        itemCount: items.length,
                        itemBuilder: (_, i) {
                          // reverse: 인덱스 0이 맨 아래 항목이다.
                          final item = items[items.length - 1 - i];
                          if (item is _DateItem) {
                            return _DateChip(label: item.label);
                          }
                          return _Bubble(
                            message: (item as _MsgItem).message,
                            controller: c,
                          );
                        },
                      ),
                      if (_showNewMsgChip)
                        Positioned(
                          bottom: 10,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Material(
                              color: Theme.of(context).colorScheme.primary,
                              elevation: 3,
                              borderRadius: BorderRadius.circular(20),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: () {
                                  setState(() => _showNewMsgChip = false);
                                  _animateToBottom();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.arrow_downward,
                                          size: 16,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onPrimary),
                                      const SizedBox(width: 6),
                                      Text('새 메시지',
                                          style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onPrimary,
                                              fontSize: 13)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: '파일 첨부',
                    onPressed: _attach,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: '메시지',
                        isDense: true,
                        filled: true,
                        fillColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.55),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: '보내기',
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 앱 바에서 여는 상대 상세 시트: 대화를 벗어나지 않고 신원을 한눈에 확인
  /// (인증 여부, 메시 거리, ID 복사).
  void _showPeerSheet(BuildContext context, MeshFrontend c, String name,
      String presence, bool nearby) {
    final contact = c.contactByHex(widget.peerHex);
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: avatarColor(widget.peerHex),
                foregroundColor: Colors.white,
                child: Text(initialsOf(name),
                    style: const TextStyle(fontSize: 26)),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(name,
                        style: Theme.of(context).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (contact?.verified ?? false)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child:
                          Icon(Icons.verified, size: 20, color: Colors.blue),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(presence,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: nearby
                            ? const Color(0xFF2E7D32)
                            : Theme.of(context).hintColor,
                      )),
              const SizedBox(height: 12),
              if (!(contact?.verified ?? false))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '아직 QR로 인증하지 않은 상대입니다.\n만나면 서로의 QR을 스캔해 신원을 확인하세요.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                      text: PeerId.fromHex(widget.peerHex).hex));
                  Navigator.pop(sheetContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('ID를 복사했습니다')),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: Text('ID ${PeerId.fromHex(widget.peerHex).short} 복사'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<_Item> _buildItems(List<ChatMessage> messages) {
    final items = <_Item>[];
    int? lastDay;
    for (final m in messages) {
      if (lastDay == null || !sameDay(lastDay, m.timestamp)) {
        items.add(_DateItem(dayLabel(m.timestamp)));
        lastDay = m.timestamp;
      }
      items.add(_MsgItem(m));
    }
    return items;
  }
}

sealed class _Item {}

class _DateItem extends _Item {
  final String label;
  _DateItem(this.label);
}

class _MsgItem extends _Item {
  final ChatMessage message;
  _MsgItem(this.message);
}

class _DateChip extends StatelessWidget {
  final String label;
  const _DateChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final MeshFrontend controller;
  const _Bubble({required this.message, required this.controller});

  bool get _isMe => message.direction == MsgDirection.outgoing;

  /// 한동안 전달 확인(✓✓)이 안 된 발신 메시지: 여전히 "sent"(링크에 넘겼지만
  /// 수신 확인이 없음) 또는 "queued"(경로 없음) 상태다. 경고와 원탭 재전송을
  /// 함께 노출해, 메시지가 사용자도 모르게 조용히 도착 실패하는 일이 없게 한다.
  static const _undeliveredAfterMs = 90 * 1000;
  bool get _undeliveredWarn {
    if (!_isMe) return false;
    if (message.status != MsgStatus.sent &&
        message.status != MsgStatus.queued) {
      return false;
    }
    return DateTime.now().millisecondsSinceEpoch - message.timestamp >
        _undeliveredAfterMs;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = _isMe ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = _isMe ? scheme.onPrimary : scheme.onSurface;
    final failed = message.status == MsgStatus.failed;

    // 메신저 스타일의 비대칭 모서리: 보낸 사람 쪽을 가리키는 모서리는 뾰족하게,
    // 나머지는 둥글게.
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(_isMe ? 18 : 5),
      bottomRight: Radius.circular(_isMe ? 5 : 18),
    );

    return Align(
      alignment: _isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => _onTap(context),
        onLongPress: () => _showMenu(context),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: failed ? scheme.errorContainer : bg,
            borderRadius: radius,
          ),
          child: Column(
            crossAxisAlignment:
                _isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (message.kind == MsgKind.text)
                Text(message.text ?? '',
                    style: TextStyle(color: failed ? scheme.onErrorContainer : fg))
              else
                _fileContent(context, failed ? scheme.onErrorContainer : fg),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_timeLabel(),
                      style: TextStyle(
                          color: (failed ? scheme.onErrorContainer : fg)
                              .withValues(alpha: 0.7),
                          fontSize: 11)),
                  if (_isMe) ...[
                    const SizedBox(width: 4),
                    _statusIcon(context, fg, scheme),
                  ],
                ],
              ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                      _isMe ? '탭하여 다시 시도' : '수신이 중단되었습니다',
                      style: TextStyle(
                          color: scheme.onErrorContainer, fontSize: 11)),
                ),
              // 오래 전달 안 됨(✓✓ 없음): 놓칠 수 없게 표시하고 원탭 재전송을
              // 제공한다. 더 차분한 "queued" 안내보다 우선한다.
              if (!failed && _undeliveredWarn)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 13, color: scheme.error),
                      const SizedBox(width: 3),
                      Text('아직 전달 안 됨 · 탭하여 다시 보내기',
                          style: TextStyle(
                              color: scheme.error,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              if (!failed &&
                  !_undeliveredWarn &&
                  message.status == MsgStatus.queued)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('상대를 만나면 자동 전달',
                      style: TextStyle(
                          color: fg.withValues(alpha: 0.7), fontSize: 11)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 말풍선 시간 라벨. 수신 텍스트는 봉투에 보낸 사람의 전송 시각을 담고 있다.
  /// 이 시각이 도착 시각과 유의미하게 다르면(>1분 — 즉 메시지가 한동안
  /// store-and-forward를 거친 경우) 둘 다 표시해, 수신자가 작성 시점과 도착
  /// 시점을 구분할 수 있게 한다.
  String _timeLabel() {
    final sent = message.sentTs;
    if (_isMe || sent == null) return clockTime(message.timestamp);
    // 보낸 사람 시계가 우리보다 앞선 경우(시계 오차): "도착보다 늦게 전송"
    // 이라는 라벨은 말이 안 되므로 — 도착 시각만 표시하도록 대체한다.
    if (sent > message.timestamp) return clockTime(message.timestamp);
    if (message.timestamp - sent < 60 * 1000) {
      return clockTime(message.timestamp);
    }
    return '${clockTime(sent)} 전송 · ${clockTime(message.timestamp)} 도착';
  }

  void _onTap(BuildContext context) {
    if (message.status == MsgStatus.failed || _undeliveredWarn) {
      if (message.kind == MsgKind.text) {
        controller.retryText(message);
      } else if (message.direction == MsgDirection.outgoing) {
        controller.retryFile(message);
      }
    } else if (message.kind == MsgKind.file &&
        message.direction == MsgDirection.outgoing &&
        message.status == MsgStatus.sending) {
      _confirmCancel(context);
    } else if (message.kind == MsgKind.file && message.filePath != null) {
      _view(context);
    }
  }

  bool get _isImage => (lookupMimeType(
          message.fileName ?? message.filePath ?? '') ??
          '')
      .startsWith('image/');

  bool get _isMedia {
    final mime =
        lookupMimeType(message.fileName ?? message.filePath ?? '') ?? '';
    return mime.startsWith('image/') || mime.startsWith('video/');
  }

  /// 이미지는 앱 내 뷰어로 열고, 그 외에는 모두 시스템 앱으로 연다.
  void _view(BuildContext context) {
    if (_isImage) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              _ImageViewerPage(message: message, controller: controller),
        ),
      );
    } else {
      controller.openFile(message);
    }
  }

  /// 길게 눌러 여는 관리 메뉴: 파일은 보기/저장/공유/삭제, 텍스트는
  /// 복사/삭제.
  void _showMenu(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    final isText = message.kind == MsgKind.text;
    final hasFile = message.kind == MsgKind.file && message.filePath != null;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isText)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('복사'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: message.text ?? ''));
                  Navigator.pop(sheet);
                  messenger.showSnackBar(
                      const SnackBar(content: Text('복사했습니다')));
                },
              ),
            if (hasFile) ...[
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('보기'),
                onTap: () {
                  Navigator.pop(sheet);
                  _view(context);
                },
              ),
              if (_isMedia)
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('갤러리에 저장'),
                  onTap: () async {
                    Navigator.pop(sheet);
                    final ok = await controller.saveToGallery(message);
                    messenger.showSnackBar(SnackBar(
                        content: Text(ok
                            ? '갤러리에 저장했습니다'
                            : '갤러리에 저장하지 못했습니다')));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: const Text('공유 · 파일 앱에 저장'),
                onTap: () {
                  Navigator.pop(sheet);
                  controller.shareFile(message);
                },
              ),
            ],
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text('삭제',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(sheet);
                _confirmDelete(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final isFile = message.kind == MsgKind.file;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('메시지 삭제'),
        content: Text(isFile
            ? '${message.fileName ?? '파일'}이(가) 내 기기에서 삭제됩니다. '
                '상대방 기기에는 남아 있습니다.'
            : '이 메시지를 내 기기에서 삭제할까요? '
                '상대방 기기에는 남아 있습니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('삭제')),
        ],
      ),
    );
    if (ok == true) await controller.deleteMessage(message);
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('전송 취소'),
        content: Text('${message.fileName ?? '파일'} 전송을 취소할까요?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('계속 보내기')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('전송 취소')),
        ],
      ),
    );
    if (ok == true) await controller.cancelFile(message);
  }

  Widget _statusIcon(BuildContext context, Color fg, ColorScheme scheme) {
    final (icon, label, color) = switch (message.status) {
      MsgStatus.sending => (Icons.schedule, '보내는 중', fg),
      MsgStatus.sent => (Icons.check, '전송됨', fg),
      MsgStatus.delivered => (Icons.done_all, '전달됨', fg),
      MsgStatus.failed => (Icons.error_outline, '실패', scheme.error),
      MsgStatus.queued => (Icons.schedule_send, '전달 대기', fg),
      _ => (Icons.check, '전송됨', fg),
    };
    return Semantics(
      label: label,
      child: Icon(icon, size: 13, color: color.withValues(alpha: 0.85)),
    );
  }

  Widget _fileContent(BuildContext context, Color fg) {
    final progress = controller.transferProgress[message.msgId];
    final canOpen = message.filePath != null;
    // 받은/보낸 이미지는 인라인 썸네일로 렌더링된다 — 탭하면 뷰어로 연다.
    if (canOpen && _isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: Image.file(
            File(message.filePath!),
            cacheWidth: 720,
            fit: BoxFit.cover,
            errorBuilder: (_, e, s) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image_outlined, color: fg),
                const SizedBox(width: 8),
                Text(message.fileName ?? '이미지',
                    style: TextStyle(color: fg)),
              ],
            ),
          ),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(canOpen ? Icons.file_open : Icons.insert_drive_file, color: fg),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message.fileName ?? '파일',
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
              Text(
                canOpen
                    ? '${humanSize(message.fileSize ?? 0)} · 탭하여 열기'
                    : humanSize(message.fileSize ?? 0),
                style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 11),
              ),
              if (progress != null && progress < 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SizedBox(
                    width: 140,
                    child: LinearProgressIndicator(value: progress),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 일관된 빈 상태 언어: 밋밋한 힌트-그레이 글리프가 아니라 은은하게
            // 틴트된 원. 자물쇠는 종단 간 암호화를 나타낸다.
            CircleAvatar(
              radius: 36,
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.lock_outline,
                  size: 34, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Text('종단 간 암호화된 대화입니다',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('첫 인사를 건네보세요 👋',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// 핀치 줌과 빠른 저장/공유 액션을 갖춘 전체 화면 이미지 뷰어.
class _ImageViewerPage extends StatelessWidget {
  final ChatMessage message;
  final MeshFrontend controller;
  const _ImageViewerPage({required this.message, required this.controller});

  @override
  Widget build(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(message.fileName ?? '이미지',
            style: const TextStyle(fontSize: 16),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: '갤러리에 저장',
            onPressed: () async {
              final ok = await controller.saveToGallery(message);
              messenger.showSnackBar(SnackBar(
                  content: Text(
                      ok ? '갤러리에 저장했습니다' : '갤러리에 저장하지 못했습니다')));
            },
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '공유',
            onPressed: () => controller.shareFile(message),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 6,
          // 디코딩 크기를 제한: 12MP 사진은 전체 해상도로 디코딩하면 ~48MB
          // 비트맵이 된다 — 폰 화면이 보여줄 수 있는 것보다 한참 크다. 2048px면
          // RAM은 10분의 1로 쓰면서 확대해도 선명하다.
          child: Image.file(File(message.filePath!), cacheWidth: 2048),
        ),
      ),
    );
  }
}
