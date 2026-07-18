import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:fluttermoji/fluttermoji.dart';
import 'package:fluttermoji/fluttermoji_assets/fluttermojimodel.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../data/avatar_codec.dart';
import '../l10n/l10n.dart';

/// 파츠 조합 아바타 빌더 — 내 정보의 아바타를 탭하면 열린다.
///
/// 위: 큰 라이브 미리보기(파츠를 고르는 순간 즉시 반영), 아래: 카테고리별
/// 파츠 선택기(Avataaars 세트). 🎲 셔플이 무작위 캐릭터를 만들어 "빈 캔버스
/// 공포" 없이 굴리다-다듬는 흐름으로 시작하게 한다. 저장하면 레시피(~30바이트
/// 텍스트)만 ANNOUNCE에 실려 이웃에게 전파된다 — 이미지는 전송되지 않는다.
class AvatarBuilderScreen extends StatefulWidget {
  const AvatarBuilderScreen({super.key});

  @override
  State<AvatarBuilderScreen> createState() => _AvatarBuilderScreenState();
}

class _AvatarBuilderScreenState extends State<AvatarBuilderScreen> {
  late final FluttermojiController _fm;

  @override
  void initState() {
    super.initState();
    _fm = Get.put(FluttermojiController());
    // 현재 저장된 레시피에서 시작한다(있다면) — 편집은 항상 이어하기.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final my = context.read<MeshFrontend>().myAvatar;
      final json = AvatarCodec.jsonFromCompact(my);
      if (json != null) {
        _fm.selectedOptions = Map<String?, dynamic>.from(jsonDecode(json));
        _fm.updatePreview();
      }
    });
  }

  /// 🎲 무작위 조합. 스타일(원형 배경)은 고정하고 나머지 파츠를 굴린다.
  void _shuffle() {
    final rng = Random();
    for (final key in AvatarCodec.keys) {
      if (key == 'style') continue;
      final count = fluttermojiProperties[key]?.property?.length ?? 1;
      _fm.selectedOptions[key] = rng.nextInt(count);
    }
    _fm.updatePreview();
    setState(() {});
  }

  Future<void> _save() async {
    final controller = context.read<MeshFrontend>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final savedMessage = context.s.avatarSaved;
    // 선택값을 fluttermoji 저장소에 확정한 뒤 레시피로 압축한다.
    await _fm.setFluttermoji();
    final compact =
        AvatarCodec.compactFromJson(jsonEncode(_fm.selectedOptions));
    if (compact == null) return;
    await controller.setAvatarRecipe(compact);
    messenger.showSnackBar(SnackBar(content: Text(savedMessage)));
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.s.avatarTitle),
        actions: [
          IconButton(
            tooltip: context.s.avatarShuffleTooltip,
            icon: const Text('🎲', style: TextStyle(fontSize: 22)),
            onPressed: _shuffle,
          ),
          TextButton(onPressed: _save, child: Text(context.s.commonSave)),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 12),
          FluttermojiCircleAvatar(radius: 72),
          const SizedBox(height: 4),
          Text(
            context.s.avatarHint,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: FluttermojiCustomizer(
                scaffoldWidth: size.width,
                autosave: true,
                // 파츠 카테고리 라벨 한글화(순서는 패키지의 기본 타이틀 순서
                // 고정: Hairstyle→Hair Colour→Facial Hair→Facial Hair
                // Colour→Outfit→Outfit Colour→Eyes→Eyebrows→Mouth→Skin→
                // Accessories).
                attributeTitles: [
                  context.s.avatarPartHairstyle,
                  context.s.avatarPartHairColor,
                  context.s.avatarPartFacialHair,
                  context.s.avatarPartFacialHairColor,
                  context.s.avatarPartOutfit,
                  context.s.avatarPartOutfitColor,
                  context.s.avatarPartEyes,
                  context.s.avatarPartEyebrows,
                  context.s.avatarPartMouth,
                  context.s.avatarPartSkin,
                  context.s.avatarPartAccessories,
                ],
                theme: FluttermojiThemeData(
                  primaryBgColor:
                      Theme.of(context).colorScheme.surfaceContainerLow,
                  secondaryBgColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  selectedIconColor: Theme.of(context).colorScheme.primary,
                  unselectedIconColor:
                      Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
