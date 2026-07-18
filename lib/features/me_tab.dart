import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_share.dart';
import '../app/background_service.dart';
import '../app/build_flags.dart';
import '../app/mesh_controller.dart';
import '../l10n/l10n.dart';
import 'avatar_builder_screen.dart';
import 'guide_screen.dart';
import 'ui_utils.dart';

/// 아바타 커스텀 유도 카드의 세션 단위 '나중에' 상태. 콜드 스타트마다
/// 초기화되므로 넛지가 "실행 주기"라는 자연스러운 리듬으로 재등장한다 —
/// 빌더에서 한 번 저장하면(avatarCustomized) 영구히 사라진다.
class AvatarNudge {
  static bool dismissedThisSession = false;

  static bool shouldShow(MeshFrontend c) =>
      !c.avatarCustomized && !dismissedThisSession;
}

class MeTab extends StatelessWidget {
  const MeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    final hint = Theme.of(context).textTheme.bodySmall?.color;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 8),
        // 아바타를 탭하면 파츠 조합 빌더로 — 편집 가능함을 연필 배지로 알린다.
        Center(
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () =>
                pushWithController(context, const AvatarBuilderScreen()),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                PersonAvatar(
                  avatar: c.myAvatar,
                  displayName: c.displayName,
                  colorKey: c.myId.hex,
                  radius: 36,
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Theme.of(context).colorScheme.surface,
                          width: 1.5),
                    ),
                    child: Icon(Icons.edit,
                        size: 13,
                        color:
                            Theme.of(context).colorScheme.onPrimaryContainer),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 커스텀 유도 카드: 미커스텀 + 이번 세션에 '나중에' 안 눌렀을 때만.
        // 모달·푸시가 아니라 제자리(아바타 바로 아래)의 조용한 카드다.
        if (AvatarNudge.shouldShow(c))
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: _AvatarNudgeCard(),
          ),
        const SizedBox(height: 12),
        Center(
          child: InkWell(
            onTap: () => _editName(context, c),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(c.displayName,
                        style: Theme.of(context).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.edit, size: 18, color: hint),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: c.myId.hex));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.s.meIdCopied)),
              );
            },
            icon: const Icon(Icons.copy, size: 14),
            label: Text(context.s.meIdLabel(c.myId.short),
                style: TextStyle(color: hint, fontSize: 12)),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Card(
            elevation: 0,
            color: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: QrImageView(
                data: c.myQrPayload,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            context.s.meQrGuide,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: FilledButton.tonalIcon(
            onPressed: () => SharePlus.instance.share(ShareParams(
                text: c.myQrPayload, subject: context.s.meShareSubject)),
            icon: const Icon(Icons.share),
            label: Text(context.s.meShareInvite),
          ),
        ),
        const SizedBox(height: 28),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(context.s.meSettingsTitle,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: hint)),
        ),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.battery_saver),
            title: Text(context.s.meBatterySaverTitle),
            subtitle: Text(context.s.meBatterySaverSubtitle),
            value: c.powerSaver,
            onChanged: (v) => context.read<MeshFrontend>().setPowerSaver(v),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.move_to_inbox_outlined),
            title: Text(context.s.meRelayStoreTitle),
            subtitle: Text(
              c.relayStoreCount == 0
                  ? context.s.meRelayStoreEmpty
                  : context.s.meRelayStorePending(
                      c.relayStoreCount, humanSize(c.relayStoreBytes)),
            ),
            isThreeLine: c.relayStoreCount > 0,
            trailing: c.relayStoreCount == 0
                ? null
                : TextButton(
                    onPressed: () => _confirmClearRelay(context, c),
                    child: Text(context.s.meRelayClear),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: Text(context.s.meGuideTitle),
            subtitle: Text(context.s.meGuideSubtitle),
            onTap: () =>
                pushWithController(context, const GuideScreen()),
          ),
        ),
        if (Platform.isAndroid) ...[
          if (!kStoreBuild) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.android),
                title: Text(context.s.meShareApkTitle),
                subtitle: Text(context.s.meShareApkSubtitle),
                isThreeLine: true,
                onTap: () => _shareApk(context),
              ),
            ),
          ],
          const SizedBox(height: 8),
          const _BatteryExemptionCard(),
        ],
        if (Platform.isIOS) ...[
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.wifi_tethering),
              title: Text(context.s.meBeaconTitle),
              subtitle: Text(context.s.meBeaconSubtitle),
              isThreeLine: true,
              value: c.beaconMonitoring,
              onChanged: (v) =>
                  context.read<MeshFrontend>().setBeaconMonitoring(v),
            ),
          ),
          // 경고가 아니라, 부드럽게 권하는 선택형 안내. 기본적인 백그라운드
          // 재연결은 "앱 사용 중"에서도 이미 동작한다(BLE 상태 복원); "항상 허용"은
          // 강제 종료/재부팅 후 깨우기와 더 빠른 깨우기만 추가로 얹어 줄 뿐이다.
          if (c.beaconNeedsAlways) ...[
            const SizedBox(height: 8),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: ListTile(
                leading: const Icon(Icons.lightbulb_outline),
                title: Text(context.s.meBeaconAlwaysTitle),
                subtitle: Text(context.s.meBeaconAlwaysSubtitle),
                isThreeLine: true,
                trailing: TextButton(
                  onPressed: () => openAppSettings(),
                  child: Text(context.s.meOpenSettings),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(context.s.meLiveReceiveTitle),
              subtitle: Text(context.s.meLiveReceiveSubtitle),
              isThreeLine: true,
            ),
          ),
        ],
        const SizedBox(height: 24),
        const _VersionFooter(),
        const SizedBox(height: 12),
      ],
    );
  }

  /// 설치된 APK를 꺼내 공유 시트에 넘긴다 — Quick Share/블루투스는 인터넷
  /// 없이도 동작하므로, 앱이 오프라인으로 퍼져 나갈 수 있다.
  Future<void> _shareApk(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // await 이전에 문구를 캡처한다 — 비동기 틈 뒤의 context 사용 금지.
    final failedMsg = context.s.meShareApkFailed;
    final subject = context.s.meShareApkSubject;
    final apk = await AppShare.apkFile();
    if (apk == null) {
      messenger.showSnackBar(SnackBar(content: Text(failedMsg)));
      return;
    }
    await SharePlus.instance.share(ShareParams(
      files: [XFile(apk.path, mimeType: AppShare.apkMime)],
      subject: subject,
    ));
  }

  Future<void> _confirmClearRelay(BuildContext context, MeshFrontend c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.s.meRelayClearTitle),
        content: Text(context.s.meRelayClearBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.s.commonCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.s.meRelayClear)),
        ],
      ),
    );
    if (ok == true) await c.clearRelayStore();
  }

  Future<void> _editName(BuildContext context, MeshFrontend c) async {
    final controller = TextEditingController(text: c.displayName);
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.s.meEditNameTitle),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 32,
            decoration: InputDecoration(labelText: context.s.meDisplayNameLabel),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.s.commonCancel)),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: Text(context.s.commonSave),
            ),
          ],
        ),
      );
      if (name != null && name.isNotEmpty) {
        await c.setDisplayName(name);
      }
    } finally {
      controller.dispose();
    }
  }
}

/// 안드로이드 전용: OEM 배터리 관리자(Samsung 등)는 시간이 지나면 백그라운드
/// 서비스를 조용히 종료시킨다. 이 카드는 SpotLink가 제외되어 있는지 보여 주고
/// 제외를 요청한다 — 한 시간 만에 죽는 중계와 며칠씩 돌아가는 중계를 가르는
/// 차이다.
class _BatteryExemptionCard extends StatefulWidget {
  const _BatteryExemptionCard();

  @override
  State<_BatteryExemptionCard> createState() => _BatteryExemptionCardState();
}

class _BatteryExemptionCardState extends State<_BatteryExemptionCard>
    with WidgetsBindingObserver {
  bool? _exempted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 시스템 대화상자/설정에서 돌아왔을 때: 다시 확인한다.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final v = await BackgroundService.isIgnoringBatteryOptimizations;
    if (mounted) setState(() => _exempted = v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final exempted = _exempted;
    return Card(
      child: ListTile(
        leading: Icon(
          exempted == true
              ? Icons.verified_outlined
              : Icons.battery_alert_outlined,
          color: exempted == true ? Colors.green : scheme.error,
        ),
        title: Text(context.s.meBatteryExemptTitle),
        subtitle: Text(
          exempted == null
              ? context.s.meBatteryChecking
              : exempted
                  ? context.s.meBatteryExemptOn
                  : context.s.meBatteryExemptOff,
        ),
        isThreeLine: exempted == false,
        trailing: exempted == false
            ? FilledButton.tonal(
                onPressed: () async {
                  await BackgroundService.requestIgnoreBatteryOptimization();
                  await _refresh();
                },
                child: Text(context.s.meBatteryAllow),
              )
            : null,
      ),
    );
  }
}

/// 앱 버전 푸터. 런타임에 설치된 패키지에서 읽어 오므로 언제나 출시된 빌드와
/// 일치한다(수동 동기화 불필요). 탭하면 복사된다 — 사용자가 버그를 제보해
/// 정확한 버전을 알아야 할 때 편리하다.
class _VersionFooter extends StatefulWidget {
  const _VersionFooter();

  @override
  State<_VersionFooter> createState() => _VersionFooterState();
}

class _VersionFooterState extends State<_VersionFooter> {
  String? _label;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _label = 'SpotLink ${info.version} (${info.buildNumber})');
      }
    }).catchError((_) {
      // 플러그인 없음(위젯 테스트 / 미지원 플랫폼) — 폴백 값을 유지한다.
    });
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).textTheme.bodySmall?.color;
    final label = _label ?? 'SpotLink';
    return Center(
      child: TextButton(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: label));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.s.meVersionCopied)),
          );
        },
        child: Text(label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: hint)),
      ),
    );
  }
}

/// "지금은 무작위 아바타" 커스텀 유도 카드. 디자인 시스템의 틴트 카드
/// 언어(primaryContainer)를 따르고, 행동 두 개만 준다: 만들기 / 나중에.
class _AvatarNudgeCard extends StatefulWidget {
  @override
  State<_AvatarNudgeCard> createState() => _AvatarNudgeCardState();
}

class _AvatarNudgeCardState extends State<_AvatarNudgeCard> {
  bool _hidden = false;

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Text('🎲', style: TextStyle(fontSize: 22)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.s.meAvatarNudgeText,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onPrimaryContainer, height: 1.35),
            ),
          ),
          const SizedBox(width: 4),
          Column(
            children: [
              FilledButton(
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12)),
                onPressed: () => pushWithController(
                    context, const AvatarBuilderScreen()),
                child: Text(context.s.meAvatarNudgeCreate),
              ),
              TextButton(
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                onPressed: () {
                  AvatarNudge.dismissedThisSession = true; // 세션 동안 침묵
                  setState(() => _hidden = true);
                },
                child: Text(context.s.meAvatarNudgeLater,
                    style: TextStyle(
                        color:
                            scheme.onPrimaryContainer.withValues(alpha: 0.7))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
