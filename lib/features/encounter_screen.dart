import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../core/ble/radio_profile.dart' show EncounterLocationPolicy;
import '../data/models.dart';
import '../l10n/l10n.dart';
import 'chat_screen.dart';
import 'ui_utils.dart';

/// "스쳐간 친구" — 친구가 근처를 지나간 기록(언제·누가·어디서). 앱을 보고
/// 있지 않았던 만남도 남아, 나중에 "못 봤지만 스쳐 갔다"는 것을 알 수 있다.
/// 위치는 이 기기에만 저장된다.
class EncounterScreen extends StatefulWidget {
  const EncounterScreen({super.key});

  @override
  State<EncounterScreen> createState() => _EncounterScreenState();
}

class _EncounterScreenState extends State<EncounterScreen> {
  List<Encounter>? _items;
  int _loadedRev = -1;

  @override
  void initState() {
    super.initState();
    final c = context.read<MeshFrontend>();
    unawaited(_load(c));
    // 오프라인일 때 좌표만 남은 기록의 장소 이름을 지금 채워 본다.
    unawaited(c.resolveEncounterPlaces());
  }

  Future<void> _load(MeshFrontend c) async {
    final rev = c.encounterRev;
    final list = await c.encounters();
    if (!mounted) return;
    setState(() {
      _items = list;
      _loadedRev = rev;
    });
  }

  Future<void> _confirmClear(MeshFrontend c) async {
    final s = context.s;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(s.encClearTitle),
        content: Text(s.encClearBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(s.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(s.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await c.clearEncounters();
    if (!mounted) return;
    setState(() => _items = const []);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(s.encCleared)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<MeshFrontend>();
    if (_items != null && c.encounterRev != _loadedRev) {
      _loadedRev = c.encounterRev;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(c));
    }
    final items = _items;
    final policy = c.encounterLocationPolicy;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.s.encTitle),
        actions: [
          if (items != null && items.isNotEmpty)
            IconButton(
              tooltip: context.s.encClear,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _confirmClear(c),
            ),
        ],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (policy != EncounterLocationPolicy.never)
                  SwitchListTile(
                    secondary: const Icon(Icons.place_outlined),
                    title: Text(context.s.encLocationToggle),
                    subtitle: Text(
                      policy == EncounterLocationPolicy.foregroundOnly
                          ? context.s.encLocationNoteForeground
                          : context.s.encLocationNote,
                    ),
                    value: c.encounterLocationEnabled,
                    onChanged: (v) => c.setEncounterLocationEnabled(v),
                  ),
                if (items.isEmpty)
                  const _EmptyEncounters()
                else
                  ..._buildRows(context, c, items),
              ],
            ),
    );
  }

  List<Widget> _buildRows(
    BuildContext context,
    MeshFrontend c,
    List<Encounter> items,
  ) {
    final rows = <Widget>[];
    int? lastDay;
    for (final e in items) {
      if (lastDay == null || !sameDay(lastDay, e.startedAt)) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              dayLabel(context, e.startedAt),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        );
        lastDay = e.startedAt;
      }
      rows.add(_EncounterTile(encounter: e, contact: _contactOf(c, e)));
    }
    return rows;
  }

  Contact? _contactOf(MeshFrontend c, Encounter e) {
    final hex = e.peerHex;
    return hex == null ? null : c.contactByHex(hex);
  }
}

class _EncounterTile extends StatelessWidget {
  final Encounter encounter;
  final Contact? contact;
  const _EncounterTile({required this.encounter, required this.contact});

  @override
  Widget build(BuildContext context) {
    final e = encounter;
    final s = context.s;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final small = theme.textTheme.bodySmall;
    final name = e.identified
        ? (contact?.displayName ?? s.encUnknownPeer)
        : s.encUnknownPeer;

    final minutes = e.duration.inMinutes;
    final when = minutes < 1
        ? '${clockTime(e.startedAt)} · ${s.encBriefly}'
        : '${clockTime(e.startedAt)} – ${clockTime(e.endedAt)} · '
              '${s.encForMinutes(minutes)}';

    final String placeText;
    if (e.place != null) {
      placeText = e.place!;
    } else if (e.hasLocation) {
      placeText = '${e.lat!.toStringAsFixed(5)}, ${e.lng!.toStringAsFixed(5)}';
    } else {
      placeText = s.encNoLocation;
    }

    final tags = <Widget>[
      if (e.missed) _Tag(text: s.encMissed, emphasized: true),
      if (e.identified)
        _Tag(text: e.hops <= 1 ? s.encDirect : s.encViaHops(e.hops)),
      if (e.autoSent) _Tag(text: s.encAutoSent),
    ];

    return ListTile(
      onTap: e.identified && contact != null
          ? () => pushWithController(
              context,
              ChatScreen(peerHex: contact!.peerHex),
            )
          : null,
      leading: e.identified
          ? PersonAvatar(
              avatar: contact?.avatar,
              displayName: name,
              colorKey: e.peerHex!,
              radius: 20,
            )
          : CircleAvatar(
              radius: 20,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: Icon(Icons.person_search_outlined, color: hint),
            ),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(when, style: small),
          Row(
            children: [
              Icon(Icons.place_outlined, size: 14, color: hint),
              const SizedBox(width: 2),
              Flexible(
                child: Text(
                  placeText,
                  style: small?.copyWith(color: e.hasLocation ? null : hint),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (!e.identified)
            Text(s.encUnknownHint, style: small?.copyWith(color: hint)),
          if (tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 6, runSpacing: 4, children: tags),
            ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final bool emphasized;
  const _Tag({required this.text, this.emphasized = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: emphasized
            ? scheme.tertiaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: emphasized ? scheme.onTertiaryContainer : null,
        ),
      ),
    );
  }
}

class _EmptyEncounters extends StatelessWidget {
  const _EmptyEncounters();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 64, 32, 0),
      child: Column(
        children: [
          Icon(
            Icons.history_toggle_off,
            size: 56,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            context.s.encEmptyTitle,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            context.s.encEmptyBody,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
