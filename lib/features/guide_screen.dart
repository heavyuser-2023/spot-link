import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

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

  List<(IconData, String, String)> _sections(BuildContext context) => [
        (
          Icons.wifi_off,
          context.s.guideSection1Title,
          context.s.guideSection1Body,
        ),
        (
          Icons.qr_code_scanner,
          context.s.guideSection2Title,
          context.s.guideSection2Body,
        ),
        (
          Icons.hub_outlined,
          context.s.guideSection3Title,
          context.s.guideSection3Body,
        ),
        (
          Icons.schedule_send,
          context.s.guideSection4Title,
          context.s.guideSection4Body,
        ),
        (
          Icons.lock_outline,
          context.s.guideSection5Title,
          context.s.guideSection5Body,
        ),
        (
          Icons.battery_saver_outlined,
          context.s.guideSection6Title,
          context.s.guideSection6Body,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.s.guideTitle),
        automaticallyImplyLeading: !widget.firstRun,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                for (final (icon, title, body) in _sections(context))
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
                      title: Text(context.s.guideDontShowAgain),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => widget.onDone?.call(_dontShowAgain),
                        child: Text(context.s.guideStart),
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
