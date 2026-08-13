import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/player_layout.dart';
import '../../../models/player_layout_templates.dart';
import '../../../providers/player_layout_provider.dart';
import '../../../theme/app_colors.dart';

/// Opens the prefabricated playeur catalog, then creates an account preset.
Future<void> showPlayerTemplatePicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _PlayerTemplatePickerSheet(),
  );
}

class _PlayerTemplatePickerSheet extends StatefulWidget {
  const _PlayerTemplatePickerSheet();

  @override
  State<_PlayerTemplatePickerSheet> createState() =>
      _PlayerTemplatePickerSheetState();
}

class _PlayerTemplatePickerSheetState extends State<_PlayerTemplatePickerSheet> {
  PlayerTemplateId? _creatingId;
  bool _creatingBlank = false;

  Future<void> _createFromTemplate(PlayerLayoutTemplate template) async {
    if (_creatingId != null || _creatingBlank) return;
    setState(() => _creatingId = template.id);
    final navigator = Navigator.of(context);
    final layout = context.read<PlayerLayoutProvider>();
    final created = await layout.createPreset(
      name: template.name,
      config: template.buildValidated(),
      useModular: template.useModular,
    );
    if (!mounted) return;
    setState(() => _creatingId = null);
    if (created != null) {
      // Close template picker, then « Mes playeurs » if stacked under it.
      navigator.pop();
      if (navigator.canPop()) navigator.pop();
    }
  }

  Future<void> _createBlank() async {
    if (_creatingId != null || _creatingBlank) return;
    setState(() => _creatingBlank = true);
    final navigator = Navigator.of(context);
    final layout = context.read<PlayerLayoutProvider>();
    final created = await layout.createPreset(
      config: PlayerLayoutConfig.standard(),
      useModular: true,
    );
    if (!mounted) return;
    setState(() => _creatingBlank = false);
    if (created != null) {
      navigator.pop();
      if (navigator.canPop()) navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final templates = PlayerLayoutTemplates.all;
    final busy = _creatingId != null || _creatingBlank;

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
            const Text(
              'Choisir un modèle',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.02 * 20,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Tous incluent les contrôles essentiels. Certains ajoutent des boutons.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.55,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: templates.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final template = templates[index];
                  final loading = _creatingId == template.id;
                  return _TemplateCard(
                    template: template,
                    enabled: !busy || loading,
                    loading: loading,
                    onTap: () => _createFromTemplate(template),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: busy ? null : _createBlank,
              icon: _creatingBlank
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.dashboard_customize_outlined, size: 18),
              label: Text(
                _creatingBlank ? 'Création…' : 'Personnalisé (Studio)',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                disabledForegroundColor: AppColors.textMuted,
                side: const BorderSide(color: AppColors.border),
                padding: const EdgeInsets.symmetric(vertical: 14),
                minimumSize: const Size(44, 48),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  final PlayerLayoutTemplate template;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;

  const _TemplateCard({
    required this.template,
    required this.enabled,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHover,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled && !loading ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(template.icon, color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      template.name,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      template.tagline,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      template.description,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    if (template.extrasLabels.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final label in template.extrasLabels)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Text(
                                label,
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: 10),
                      Text(
                        'CORE uniquement',
                        style: TextStyle(
                          color: AppColors.primary.withValues(alpha: 0.85),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
