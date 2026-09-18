import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_deferred_keyboard.dart';
import '../widgets/settings_ui.dart';

/// TMDB (métadonnées, affiches, catalogue de demandes) et MediaHub (envoi des
/// demandes). Les clés ne sont jamais renvoyées en clair par le serveur.
class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage({super.key});

  @override
  State<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<IntegrationsPage> {
  static const _languages = [
    ('fr-FR', 'Français'),
    ('en-US', 'English'),
    ('es-ES', 'Español'),
    ('de-DE', 'Deutsch'),
    ('it-IT', 'Italiano'),
  ];

  final _tmdbKey = TextEditingController();
  final _mediaHubUrl = TextEditingController();
  final _mediaHubKey = TextEditingController();

  ServerSettings? _settings;
  String _language = 'fr-FR';
  String? _error;
  bool _savingTmdb = false;
  bool _savingMediaHub = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tmdbKey.dispose();
    _mediaHubUrl.dispose();
    _mediaHubKey.dispose();
    super.dispose();
  }

  void _apply(ServerSettings settings) {
    _settings = settings;
    _language = _languages.any((l) => l.$1 == settings.tmdbLanguage)
        ? settings.tmdbLanguage
        : 'fr-FR';
    _mediaHubUrl.text = settings.mediaHubUrl;
    _tmdbKey.clear();
    _mediaHubKey.clear();
  }

  Future<void> _load() async {
    try {
      final settings = await context.read<ApiClient>().getServerSettings();
      if (!mounted) return;
      setState(() {
        _apply(settings);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = settingsErrorText(
          e, 'Impossible de charger les paramètres serveur.'));
    }
  }

  Future<void> _saveTmdb({bool clearKey = false}) async {
    setState(() => _savingTmdb = true);
    final key = _tmdbKey.text.trim();
    try {
      final updated = await context.read<ApiClient>().updateServerSettings(
            tmdbApiKey: key.isEmpty ? null : key,
            clearTmdbApiKey: clearKey,
            tmdbLanguage: _language,
          );
      if (!mounted) return;
      setState(() => _apply(updated));
      showSettingsSnack(
          context, clearKey ? 'Clé TMDB effacée.' : 'TMDB enregistré.');
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, 'Échec de l’enregistrement.'),
            error: true);
      }
    }
    if (mounted) setState(() => _savingTmdb = false);
  }

  Future<void> _saveMediaHub({bool clearKey = false}) async {
    setState(() => _savingMediaHub = true);
    final key = _mediaHubKey.text.trim();
    try {
      final updated = await context.read<ApiClient>().updateServerSettings(
            mediaHubUrl: _mediaHubUrl.text.trim(),
            mediaHubApiKey: key.isEmpty ? null : key,
            clearMediaHubApiKey: clearKey,
          );
      if (!mounted) return;
      setState(() => _apply(updated));
      showSettingsSnack(
          context, clearKey ? 'Clé MediaHub effacée.' : 'MediaHub enregistré.');
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, 'Échec de l’enregistrement.'),
            error: true);
      }
    }
    if (mounted) setState(() => _savingMediaHub = false);
  }

  Widget _status(bool configured) => SettingsPill(
        configured ? 'Configuré' : 'Non configuré',
        color: configured ? AppColors.success : AppColors.warning,
        icon: configured ? Icons.check_rounded : Icons.error_outline_rounded,
      );

  @override
  Widget build(BuildContext context) {
    final settings = _settings;

    return SettingsPage(
      title: 'Métadonnées',
      description:
          'Les services qui donnent au catalogue ses affiches et ses résumés, et qui reçoivent les demandes de médias.',
      children: [
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (settings == null && _error == null) const SettingsLoading(),
        if (settings != null) ...[
          SettingsGroup(
            title: 'The Movie Database (TMDB)',
            trailing: _status(settings.tmdbApiKeySet),
            footer:
                'Sert à identifier les fichiers, récupérer affiches, résumés et distribution, et alimenter le catalogue des demandes.',
            padded: true,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _KeyField(
                    controller: _tmdbKey,
                    label: 'Clé API TMDB',
                    configured: settings.tmdbApiKeySet,
                    hint: settings.tmdbApiKeyHint,
                  ),
                  const SizedBox(height: 12),
                  DropdownMenu<String>(
                    initialSelection: _language,
                    label: const Text('Langue des métadonnées'),
                    leadingIcon: const Icon(Icons.translate_rounded),
                    expandedInsets: EdgeInsets.zero,
                    onSelected: (value) {
                      if (value != null) setState(() => _language = value);
                    },
                    dropdownMenuEntries: [
                      for (final (code, label) in _languages)
                        DropdownMenuEntry(value: code, label: label),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _Actions(
                    saving: _savingTmdb,
                    onSave: () => _saveTmdb(),
                    onClear: settings.tmdbApiKeySet
                        ? () => _saveTmdb(clearKey: true)
                        : null,
                  ),
                ],
              ),
            ],
          ),
          SettingsGroup(
            title: 'MediaHub',
            trailing: _status(
                settings.mediaHubUrl.isNotEmpty && settings.mediaHubApiKeySet),
            footer:
                'Les demandes faites depuis l’onglet Demandes y sont transmises pour être téléchargées.',
            padded: true,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TvDeferredKeyboard(
                    builder: (context, focusNode, canRequestFocus) => TextField(
                      focusNode: focusNode,
                      canRequestFocus: canRequestFocus,
                      controller: _mediaHubUrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Adresse MediaHub',
                        hintText: 'https://mediahub.example.com',
                        prefixIcon: Icon(Icons.link_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _KeyField(
                    controller: _mediaHubKey,
                    label: 'Clé API MediaHub',
                    configured: settings.mediaHubApiKeySet,
                    hint: settings.mediaHubApiKeyHint,
                  ),
                  const SizedBox(height: 14),
                  _Actions(
                    saving: _savingMediaHub,
                    onSave: () => _saveMediaHub(),
                    onClear: settings.mediaHubApiKeySet
                        ? () => _saveMediaHub(clearKey: true)
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _KeyField extends StatefulWidget {
  const _KeyField({
    required this.controller,
    required this.label,
    required this.configured,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final bool configured;
  final String? hint;

  @override
  State<_KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends State<_KeyField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TvDeferredKeyboard(
      builder: (context, focusNode, canRequestFocus) => TextField(
        focusNode: focusNode,
        canRequestFocus: canRequestFocus,
        controller: widget.controller,
        obscureText: _obscure,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.configured
              ? 'Clé active ${widget.hint ?? '••••'} — laisser vide pour la garder'
              : 'Coller la clé',
          prefixIcon: const Icon(Icons.key_rounded),
          suffixIcon: IconButton(
            tooltip: _obscure ? 'Afficher' : 'Masquer',
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(_obscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined),
          ),
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.saving,
    required this.onSave,
    required this.onClear,
  });

  final bool saving;
  final VoidCallback onSave;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        if (onClear != null)
          TextButton(
            onPressed: saving ? null : onClear,
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Effacer la clé'),
          ),
        FilledButton(
          onPressed: saving ? null : onSave,
          child: Text(saving ? 'Enregistrement…' : 'Enregistrer'),
        ),
      ],
    );
  }
}
