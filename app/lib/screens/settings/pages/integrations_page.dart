import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_deferred_keyboard.dart';
import '../widgets/settings_ui.dart';
import '../../../l10n/tr.dart';

/// TMDB (métadonnées, affiches, catalogue de demandes), Fanart.tv (affiches
/// en plus, ADR-0068) et MediaHub (demandes, ADR-0089 ; un OnyxHub à la même
/// adresse est reconnu par le serveur). Les clés ne sont jamais renvoyées en
/// clair par le serveur.
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
  final _fanartKey = TextEditingController();
  final _mediaHubUrl = TextEditingController();
  final _mediaHubKey = TextEditingController();

  ServerSettings? _settings;
  String _language = 'fr-FR';
  String? _error;
  bool _savingTmdb = false;
  bool _savingFanart = false;
  bool _savingMediaHub = false;
  bool _testingMediaHub = false;

  /// Les réserves du dernier test de liaison réussi (compte absent de
  /// MediaHub, notifications sans adresse).
  List<String> _linkNotes = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tmdbKey.dispose();
    _fanartKey.dispose();
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
    _fanartKey.clear();
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
          e, tr('Impossible de charger les paramètres serveur.')));
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
          context, clearKey ? tr('Clé TMDB effacée.') : tr('TMDB enregistré.'));
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, tr('Échec de l’enregistrement.')),
            error: true);
      }
    }
    if (mounted) setState(() => _savingTmdb = false);
  }

  Future<void> _saveFanart({bool clearKey = false}) async {
    setState(() => _savingFanart = true);
    final key = _fanartKey.text.trim();
    try {
      final updated = await context.read<ApiClient>().updateServerSettings(
            fanartApiKey: key.isEmpty ? null : key,
            clearFanartApiKey: clearKey,
          );
      if (!mounted) return;
      setState(() => _apply(updated));
      showSettingsSnack(context,
          clearKey ? tr('Clé Fanart.tv effacée.') : tr('Fanart.tv enregistré.'));
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, tr('Échec de l’enregistrement.')),
            error: true);
      }
    }
    if (mounted) setState(() => _savingFanart = false);
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
          context, clearKey ? tr('Clé effacée.') : tr('MediaHub enregistré.'));
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, tr('Échec de l’enregistrement.')),
            error: true);
      }
    }
    if (mounted) setState(() => _savingMediaHub = false);
  }

  /// Les valeurs du formulaire, pas encore enregistrées, sont celles qu'on
  /// teste : on vérifie avant d'enregistrer, pas après.
  Future<void> _testMediaHub() async {
    setState(() => _testingMediaHub = true);
    try {
      final result = await context.read<ApiClient>().testMediaHubLink(
            url: _mediaHubUrl.text.trim(),
            apiKey: _mediaHubKey.text.trim(),
          );
      if (!mounted) return;
      if (result == null) {
        showSettingsSnack(
            context,
            tr('Ce serveur est trop ancien pour cette fonction. Mettez-le à jour.'),
            error: true);
      } else {
        setState(() => _linkNotes = result.ok ? result.notes : const []);
        showSettingsSnack(context, result.message, error: !result.ok);
      }
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, tr('Le test n’a pas pu se faire.')),
            error: true);
      }
    }
    if (mounted) setState(() => _testingMediaHub = false);
  }

  Widget _status(bool configured) => SettingsPill(
        configured ? tr('Configuré') : tr('Non configuré'),
        color: configured ? AppColors.success : AppColors.warning,
        icon: configured ? Icons.check_rounded : Icons.error_outline_rounded,
      );

  @override
  Widget build(BuildContext context) {
    final settings = _settings;

    return SettingsPage(
      title: tr('Métadonnées'),
      description:
          tr('Les services qui donnent au catalogue ses affiches et ses '
              'résumés, et qui reçoivent les demandes de médias.'),
      children: [
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (settings == null && _error == null) const SettingsLoading(),
        if (settings != null) ...[
          SettingsGroup(
            title: tr('The Movie Database (TMDB)'),
            trailing: _status(settings.tmdbApiKeySet),
            footer:
                tr('Sert à identifier les fichiers, récupérer affiches, '
                    'résumés et distribution, et alimenter le catalogue des '
                    'demandes.'),
            padded: true,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _KeyField(
                    controller: _tmdbKey,
                    label: tr('Clé API TMDB'),
                    configured: settings.tmdbApiKeySet,
                    hint: settings.tmdbApiKeyHint,
                  ),
                  const SizedBox(height: 12),
                  DropdownMenu<String>(
                    initialSelection: _language,
                    label: Text(tr('Langue des métadonnées')),
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
            title: tr('Fanart.tv'),
            trailing: _status(settings.fanartApiKeySet),
            footer: tr('Facultatif. Ajoute les affiches de Fanart.tv à celles '
                'de TMDB quand on change l’affiche d’un film ou d’une série. '
                'Clé personnelle gratuite sur fanart.tv.'),
            padded: true,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _KeyField(
                    controller: _fanartKey,
                    label: tr('Clé API Fanart.tv'),
                    configured: settings.fanartApiKeySet,
                    hint: settings.fanartApiKeyHint,
                  ),
                  const SizedBox(height: 14),
                  _Actions(
                    saving: _savingFanart,
                    onSave: () => _saveFanart(),
                    onClear: settings.fanartApiKeySet
                        ? () => _saveFanart(clearKey: true)
                        : null,
                  ),
                ],
              ),
            ],
          ),
          SettingsGroup(
            title: tr('Service de demandes'),
            trailing: _status(
                settings.mediaHubUrl.isNotEmpty && settings.mediaHubApiKeySet),
            footer: tr('Les demandes faites depuis l’onglet Demander sont '
                'transmises à MediaHub pour être téléchargées. La clé est '
                'PLAYER_INTEGRATION_API_KEY de MediaHub. Pour que MediaHub '
                'prévienne Onyx des imports, réglez-y ONYX_WEBHOOK_URL sur '
                '{0}/api/integrations/mediahub/events.', [
              context.read<ApiClient>().baseUrl
            ]),
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
                      decoration: InputDecoration(
                        labelText: tr('Adresse de MediaHub'),
                        hintText: 'http://192.168.1.10:4400',
                        prefixIcon: Icon(Icons.link_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _KeyField(
                    controller: _mediaHubKey,
                    label: tr('Clé d’intégration MediaHub'),
                    configured: settings.mediaHubApiKeySet,
                    hint: settings.mediaHubApiKeyHint,
                  ),
                  const SizedBox(height: 14),
                  for (final note in _linkNotes) ...[
                    SettingsBanner(note),
                    const SizedBox(height: 10),
                  ],
                  _Actions(
                    saving: _savingMediaHub || _testingMediaHub,
                    onTest: _testMediaHub,
                    testing: _testingMediaHub,
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
              ? tr('Clé active {0} — laisser vide pour la garder', [widget.hint ?? '••••'])
              : tr('Coller la clé'),
          prefixIcon: const Icon(Icons.key_rounded),
          suffixIcon: IconButton(
            tooltip: _obscure ? tr('Afficher') : tr('Masquer'),
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
    this.onTest,
    this.testing = false,
  });

  final bool saving;
  final VoidCallback onSave;
  final VoidCallback? onClear;

  /// Seul MediaHub se teste : c'est le serveur qui doit le joindre.
  final VoidCallback? onTest;
  final bool testing;

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
            child: Text(tr('Effacer la clé')),
          ),
        if (onTest != null)
          OutlinedButton(
            onPressed: saving ? null : onTest,
            child: Text(testing ? tr('Test…') : tr('Tester')),
          ),
        FilledButton(
          onPressed: saving ? null : onSave,
          child: Text(saving && !testing
              ? tr('Enregistrement…')
              : tr('Enregistrer')),
        ),
      ],
    );
  }
}
