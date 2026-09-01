import 'package:flutter/material.dart';
import '../../../tv/tv_deferred_keyboard.dart';
import 'package:provider/provider.dart';
import '../../../models/player_layout.dart';
import '../../../providers/player_layout_provider.dart';
import '../../../theme/app_colors.dart';
import 'player_template_picker_sheet.dart';

/// Bottom sheet to switch, create, rename or delete account-linked playeurs.
Future<void> showPlayerLayoutsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _PlayerLayoutsSheet(),
  );
}

class _PlayerLayoutsSheet extends StatelessWidget {
  const _PlayerLayoutsSheet();

  @override
  Widget build(BuildContext context) {
    final layout = context.watch<PlayerLayoutProvider>();
    final bottom = MediaQuery.paddingOf(context).bottom;
    // Fixed chromes get their own section above, so they must not also show
    // up in the modular list — the same playeur twice reads as a bug.
    final modularPresets =
        layout.presets.where((p) => !p.config.isFixedChrome).toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Mes playeurs',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (layout.isSyncing)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'Synchroniser',
                    onPressed: layout.syncFromAccount,
                    icon: const Icon(Icons.sync, color: Colors.white70),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Liés à ton compte. Choisis un modèle prêt à l’emploi, ou duplique pour customiser.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            const _SectionLabel('Playeurs fixes'),
            const SizedBox(height: 8),
            for (final chrome in FixedChromeId.values) ...[
              _FixedChromeCard(
                chrome: chrome,
                selected: layout.fixedChrome == chrome,
                onTap: () async {
                  await layout.activateFixedChrome(chrome);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            const _SectionLabel('Playeurs modulaires'),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.35,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: modularPresets.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final preset = modularPresets[index];
                  final selected = preset.id == layout.activePresetId;
                  return Material(
                    color: selected
                        ? const Color(0xFF0A84FF).withValues(alpha: 0.18)
                        : const Color(0xFF252525),
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        await layout.selectPreset(preset.id);
                        if (context.mounted) Navigator.pop(context);
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                        child: Row(
                          children: [
                            Icon(
                              selected
                                  ? Icons.check_circle_rounded
                                  : Icons.dashboard_customize_outlined,
                              color: selected
                                  ? const Color(0xFF0A84FF)
                                  : Colors.white54,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    preset.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    preset.useModular
                                        ? 'Layout modulaire'
                                        : 'HUD standard',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.45),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert,
                                  color: Colors.white54),
                              color: const Color(0xFF2A2A2A),
                              onSelected: (value) async {
                                switch (value) {
                                  case 'rename':
                                    await _renamePreset(context, preset.id, preset.name);
                                    break;
                                  case 'delete':
                                    await _deletePreset(context, preset.id, preset.name);
                                    break;
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'rename',
                                  child: Text('Renommer'),
                                ),
                                if (layout.presets.length > 1)
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text(
                                      'Supprimer',
                                      style: TextStyle(color: Colors.redAccent),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => showPlayerTemplatePicker(context),
                    icon: const Icon(Icons.auto_awesome_mosaic_outlined, size: 18),
                    label: const Text('Modèles'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      minimumSize: const Size(44, 48),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final created = await layout.duplicateActivePreset();
                      if (created != null && context.mounted) {
                        Navigator.pop(context);
                      }
                    },
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    label: const Text('Dupliquer'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onAccent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      minimumSize: const Size(44, 48),
                    ),
                  ),
                ),
              ],
            ),
            if (layout.errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                layout.errorMessage!,
                style: const TextStyle(color: AppColors.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _renamePreset(
    BuildContext context,
    String id,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text('Renommer le playeur'),
        content: TvDeferredKeyboard(
          builder: (context, focusNode, canRequestFocus) => TextField(
            focusNode: focusNode,
            canRequestFocus: canRequestFocus,
            controller: controller,
            autofocus: true,
            maxLength: 64,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'Nom',
              counterText: '',
            ),
            onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
                  ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    await context.read<PlayerLayoutProvider>().renamePreset(id, name);
  }

  Future<void> _deletePreset(
    BuildContext context,
    String id,
    String name,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text('Supprimer ce playeur ?'),
        content: Text('« $name » sera retiré de ton compte sur tous les appareils.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<PlayerLayoutProvider>().deletePreset(id);
  }
}

/// Small uppercase heading separating the two kinds of playeur.
class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.45),
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
  }
}

/// Card for a hand-written, non-editable chrome.
///
/// Deliberately has no rename/duplicate/delete affordances: there is nothing
/// to customise, which is the whole point — selecting it is the only action.
class _FixedChromeCard extends StatelessWidget {
  final FixedChromeId chrome;
  final bool selected;
  final VoidCallback onTap;

  const _FixedChromeCard({
    required this.chrome,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? const Color(0xFF0A84FF).withValues(alpha: 0.18)
          : const Color(0xFF252525),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.movie_creation_outlined,
                color:
                    selected ? const Color(0xFF0A84FF) : Colors.white54,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chrome.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Fidèle au lecteur Emby. Non modifiable.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.lock_outline_rounded,
                size: 18,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
