import 'package:flutter/material.dart';

/// 사용법 + 동작 원리 안내. 첫 실행 시([firstRun]) "다시 보지 않기" 체크와
/// 시작 버튼이 붙고, 내 정보 탭에서는 일반 화면으로 다시 볼 수 있다.
class GuideScreen extends StatefulWidget {
  final bool firstRun;

  /// firstRun일 때 닫히며 호출: dontShowAgain 체크 여부를 넘긴다.
  final void Function(bool dontShowAgain)? onDone;
  const GuideScreen({super.key, this.firstRun = false, this.onDone});

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  bool _dontShowAgain = true;

  static const _sections = [
    (
      Icons.wifi_off,
      '인터넷이 필요 없어요',
      'SpotLink는 블루투스로 주변 기기와 직접 연결됩니다. 통신망이 끊긴 곳,'
          ' 해외, 재난 상황에서도 근처 친구와 대화할 수 있어요.',
    ),
    (
      Icons.qr_code_scanner,
      '친구는 QR로 안전하게',
      '친구 탭의 QR 버튼으로 상대의 코드를 스캔하면 서로의 암호 키가 교환되어'
          ' 인증된 친구가 됩니다. 주변에서 발견된 사용자도 자동으로 나타나요.',
    ),
    (
      Icons.hub_outlined,
      '친구를 건너 멀리까지',
      '직접 닿지 않는 거리라도 중간에 다른 SpotLink 기기가 있으면 메시지가'
          ' 릴레이되어 전달됩니다. 친구 탭의 레이더에서 누가 몇 홉 거리인지'
          ' 볼 수 있어요.',
    ),
    (
      Icons.schedule_send,
      '지금 없으면, 만났을 때',
      '상대가 범위 밖이면 메시지를 보관했다가 다시 만나는 순간 자동으로'
          ' 전달합니다. 늦게 도착한 메시지에는 보낸 시각과 도착한 시각이 함께'
          ' 표시돼요.',
    ),
    (
      Icons.lock_outline,
      '내용은 둘만 볼 수 있어요',
      '모든 메시지는 종단간 암호화됩니다. 중간에서 릴레이해 주는 기기도 내용을'
          ' 읽을 수 없어요.',
    ),
    (
      Icons.battery_saver_outlined,
      '배터리는 알아서 아껴요',
      '연결이 안정되면 자동으로 절전 모드로 내려가고, 충전 중이거나 새 친구를'
          ' 찾을 땐 빠른 모드로 올라갑니다. 앱을 꺼도 근처 친구가 다시 깨워줄'
          ' 수 있어요.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SpotLink 사용법'),
        automaticallyImplyLeading: !widget.firstRun,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                for (final (icon, title, body) in _sections)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(icon,
                              size: 24, color: scheme.onPrimaryContainer),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                          fontWeight: FontWeight.w600)),
                              const SizedBox(height: 3),
                              Text(body,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          height: 1.4)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (widget.firstRun)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CheckboxListTile(
                      value: _dontShowAgain,
                      onChanged: (v) =>
                          setState(() => _dontShowAgain = v ?? true),
                      title: const Text('다시 보지 않기'),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => widget.onDone?.call(_dontShowAgain),
                        child: const Text('시작하기'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
