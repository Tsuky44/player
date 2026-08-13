import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_download.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/player_layout_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../utils/external_url.dart';
import '../player_studio/player_studio_screen.dart';
import '../player_studio/widgets/player_layouts_sheet.dart';
import 'playback_preferences_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _serverUrlController = TextEditingController();
  final _mediaHubUrlController = TextEditingController();
  final _mediaHubKeyController = TextEditingController();
  final _tmdbKeyController = TextEditingController();
  final _moviesDirController = TextEditingController();
  final _seriesDirController = TextEditingController();

  String _tmdbLanguage = 'fr-FR';
  bool _loading = true;
  bool _saving = false;
  bool _obscureMediaHubKey = true;
  bool _obscureTmdbKey = true;
  bool _mediaHubKeySet = false;
  bool _tmdbKeySet = false;
  String? _mediaHubKeyHint;
  String? _tmdbKeyHint;
  String? _error;
  String? _success;

  List<AppDownload> _downloads = const [];

  static const _languages = [
    ('fr-FR', 'Français'),
    ('en-US', 'English'),
    ('es-ES', 'Español'),
    ('de-DE', 'Deutsch'),
    ('it-IT', 'Italiano'),
  ];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _mediaHubUrlController.dispose();
    _mediaHubKeyController.dispose();
    _tmdbKeyController.dispose();
    _moviesDirController.dispose();
    _seriesDirController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final api = context.read<ApiClient>();
    _serverUrlController.text = api.baseUrl;
    _loadDownloads(api);
    try {
      final settings = await api.getServerSettings();
      if (!mounted) return;
      setState(() {
        _mediaHubUrlController.text = settings.mediaHubUrl;
        _moviesDirController.text = settings.moviesDir;
        _seriesDirController.text = settings.seriesDir;
        _tmdbLanguage = settings.tmdbLanguage.isEmpty
            ? 'fr-FR'
            : settings.tmdbLanguage;
        _mediaHubKeySet = settings.mediaHubApiKeySet;
        _tmdbKeySet = settings.tmdbApiKeySet;
        _mediaHubKeyHint = settings.mediaHubApiKeyHint;
        _tmdbKeyHint = settings.tmdbApiKeyHint;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Impossible de charger les paramètres serveur.';
      });
    }
  }

  /// Loads the installable apps separately from the settings: an older server
  /// has no /api/downloads route, and that must not turn into a "paramètres
  /// serveur illisibles" banner. On failure the section simply stays hidden.
  Future<void> _loadDownloads(ApiClient api) async {
    try {
      final downloads = await api.getAppDownloads();
      if (!mounted) return;
      setState(() => _downloads = downloads);
    } catch (_) {
      if (!mounted) return;
      setState(() => _downloads = const []);
    }
  }

  Future<void> _openDownload(AppDownload download) async {
    final api = context.read<ApiClient>();
    final url = api.getAppDownloadUrl(download);
    final opened = await openExternalUrl(url);
    if (!mounted || opened) return;
    // Mobile has no way to hand a URL off, so show it for the user to copy.
    setState(() {
      _success = null;
      _error = 'Téléchargement disponible ici : $url';
    });
  }

  Future<void> _saveConnection() async {
    final api = context.read<ApiClient>();
    final url = _serverUrlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });
    try {
      await api.setConnection(url);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _success = 'Adresse du serveur enregistrée.';
        _serverUrlController.text = api.baseUrl;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Échec de l’enregistrement de l’adresse.';
      });
    }
  }

  Future<void> _saveServerSettings({
    bool clearMediaHubKey = false,
    bool clearTmdbKey = false,
  }) async {
    final api = context.read<ApiClient>();
    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });
    try {
      final updated = await api.updateServerSettings(
        mediaHubUrl: _mediaHubUrlController.text.trim(),
        mediaHubApiKey: _mediaHubKeyController.text.trim().isEmpty
            ? null
            : _mediaHubKeyController.text.trim(),
        clearMediaHubApiKey: clearMediaHubKey,
        tmdbApiKey: _tmdbKeyController.text.trim().isEmpty
            ? null
            : _tmdbKeyController.text.trim(),
        clearTmdbApiKey: clearTmdbKey,
        tmdbLanguage: _tmdbLanguage,
        moviesDir: _moviesDirController.text.trim(),
        seriesDir: _seriesDirController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _success = 'Paramètres enregistrés.';
        _mediaHubUrlController.text = updated.mediaHubUrl;
        _moviesDirController.text = updated.moviesDir;
        _seriesDirController.text = updated.seriesDir;
        _tmdbLanguage = updated.tmdbLanguage;
        _mediaHubKeySet = updated.mediaHubApiKeySet;
        _tmdbKeySet = updated.tmdbApiKeySet;
        _mediaHubKeyHint = updated.mediaHubApiKeyHint;
        _tmdbKeyHint = updated.tmdbApiKeyHint;
        _mediaHubKeyController.clear();
        _tmdbKeyController.clear();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Échec de l’enregistrement des paramètres.';
      });
    }
  }

  Future<void> _runLibraryAction(
    String label,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label lancé…')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Impossible de lancer : $label'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeProvider>();
    final auth = context.watch<AuthProvider>();
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Paramètres'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.7, -0.85),
                        radius: 1.2,
                        colors: [
                          AppColors.primary.withValues(alpha: 0.07),
                          AppColors.background,
                        ],
                      ),
                    ),
                  ),
                ),
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                  children: [
                    if (_error != null) ...[
                      _Banner(
                        message: _error!,
                        tone: _BannerTone.error,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_success != null) ...[
                      _Banner(
                        message: _success!,
                        tone: _BannerTone.success,
                      ),
                      const SizedBox(height: 12),
                    ],
                    _Section(
                      title: 'Connexion',
                      subtitle:
                          'Adresse du serveur Onyx utilisée par cette app.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _serverUrlController,
                            decoration: const InputDecoration(
                              labelText: 'URL du serveur',
                              hintText: 'http://127.0.0.1:8080',
                              prefixIcon: Icon(Icons.dns_outlined),
                            ),
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _saveConnection(),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton(
                              onPressed: _saving ? null : _saveConnection,
                              child: const Text('Enregistrer l’adresse'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _Section(
                      title: 'MediaHub',
                      subtitle:
                          'Intégration demandes / disponibilité. Les clés ne sont jamais affichées en clair.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _mediaHubUrlController,
                            decoration: const InputDecoration(
                              labelText: 'URL MediaHub',
                              hintText: 'https://mediahub.example.com',
                              prefixIcon: Icon(Icons.link_rounded),
                            ),
                            keyboardType: TextInputType.url,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _mediaHubKeyController,
                            obscureText: _obscureMediaHubKey,
                            decoration: InputDecoration(
                              labelText: 'Clé API MediaHub',
                              hintText: _mediaHubKeySet
                                  ? (_mediaHubKeyHint ?? 'Clé déjà configurée')
                                  : 'Coller une nouvelle clé',
                              prefixIcon:
                                  const Icon(Icons.key_rounded),
                              suffixIcon: IconButton(
                                tooltip: _obscureMediaHubKey
                                    ? 'Afficher'
                                    : 'Masquer',
                                onPressed: () => setState(
                                  () => _obscureMediaHubKey =
                                      !_obscureMediaHubKey,
                                ),
                                icon: Icon(
                                  _obscureMediaHubKey
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),
                          if (_mediaHubKeySet)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'Clé active : ${_mediaHubKeyHint ?? "••••"} — laissez vide pour conserver.',
                                style: textTheme.bodySmall?.copyWith(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton(
                                onPressed:
                                    _saving ? null : () => _saveServerSettings(),
                                child: const Text('Enregistrer MediaHub'),
                              ),
                              if (_mediaHubKeySet)
                                TextButton(
                                  onPressed: _saving
                                      ? null
                                      : () => _saveServerSettings(
                                            clearMediaHubKey: true,
                                          ),
                                  child: const Text('Effacer la clé'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _Section(
                      title: 'TMDB',
                      subtitle:
                          'Métadonnées, affiches et catalogue de demandes.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _tmdbKeyController,
                            obscureText: _obscureTmdbKey,
                            decoration: InputDecoration(
                              labelText: 'Clé API TMDB',
                              hintText: _tmdbKeySet
                                  ? (_tmdbKeyHint ?? 'Clé déjà configurée')
                                  : 'Clé The Movie Database',
                              prefixIcon:
                                  const Icon(Icons.movie_filter_outlined),
                              suffixIcon: IconButton(
                                tooltip:
                                    _obscureTmdbKey ? 'Afficher' : 'Masquer',
                                onPressed: () => setState(
                                  () => _obscureTmdbKey = !_obscureTmdbKey,
                                ),
                                icon: Icon(
                                  _obscureTmdbKey
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),
                          if (_tmdbKeySet)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'Clé active : ${_tmdbKeyHint ?? "••••"} — laissez vide pour conserver.',
                                style: textTheme.bodySmall?.copyWith(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                          DropdownMenu<String>(
                            initialSelection:
                                _languages.any((e) => e.$1 == _tmdbLanguage)
                                    ? _tmdbLanguage
                                    : 'fr-FR',
                            label: const Text('Langue des métadonnées'),
                            leadingIcon: const Icon(Icons.translate_rounded),
                            expandedInsets: EdgeInsets.zero,
                            onSelected: (v) {
                              if (v == null) return;
                              setState(() => _tmdbLanguage = v);
                            },
                            dropdownMenuEntries: [
                              for (final (code, label) in _languages)
                                DropdownMenuEntry(value: code, label: label),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton(
                                onPressed:
                                    _saving ? null : () => _saveServerSettings(),
                                child: const Text('Enregistrer TMDB'),
                              ),
                              if (_tmdbKeySet)
                                TextButton(
                                  onPressed: _saving
                                      ? null
                                      : () => _saveServerSettings(
                                            clearTmdbKey: true,
                                          ),
                                  child: const Text('Effacer la clé'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _Section(
                      title: 'Bibliothèque',
                      subtitle:
                          'Chemins scannés côté serveur, puis actions d’indexation.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _moviesDirController,
                            decoration: const InputDecoration(
                              labelText: 'Dossier films',
                              hintText: '/media/Films',
                              prefixIcon: Icon(Icons.folder_outlined),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _seriesDirController,
                            decoration: const InputDecoration(
                              labelText: 'Dossier séries',
                              hintText: '/media/Series',
                              prefixIcon: Icon(Icons.folder_copy_outlined),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton.tonal(
                              onPressed:
                                  _saving ? null : () => _saveServerSettings(),
                              child: const Text('Enregistrer les chemins'),
                            ),
                          ),
                          const SizedBox(height: 20),
                          _ActionTile(
                            icon: Icons.sync_rounded,
                            title: 'Synchroniser la bibliothèque',
                            subtitle: home.isScanning
                                ? 'Scan en cours…'
                                : 'Indexer films et séries sur le disque',
                            busy: home.isScanning,
                            onTap: home.isScanning
                                ? null
                                : () => _runLibraryAction(
                                      'Scan',
                                      home.triggerLibraryScan,
                                    ),
                          ),
                          _ActionTile(
                            icon: Icons.image_outlined,
                            title: 'Mettre à jour les affiches',
                            subtitle: home.isBackfillingMetadata
                                ? 'Récupération TMDB…'
                                : 'Compléter posters et synopsis manquants',
                            busy: home.isBackfillingMetadata,
                            onTap: home.isBackfillingMetadata
                                ? null
                                : () => _runLibraryAction(
                                      'Mise à jour des affiches',
                                      () async {
                                        home.triggerMetadataBackfill();
                                      },
                                    ),
                          ),
                          _ActionTile(
                            icon: Icons.manage_search_rounded,
                            title: 'Re-détecter tous les matchs',
                            subtitle: home.isRedetectingAll
                                ? _redetectProgress(home)
                                : 'Retester l’identification TMDB (films et séries)',
                            busy: home.isRedetectingAll,
                            onTap: home.isRedetectingAll
                                ? null
                                : () => _runLibraryAction(
                                      'Re-détection des matchs',
                                      home.triggerRedetectAllMatches,
                                    ),
                          ),
                          _ActionTile(
                            icon: Icons.subtitles_outlined,
                            title: 'Extraire les sous-titres',
                            subtitle: home.isExtractingSubtitles
                                ? _subtitleProgress(home)
                                : 'Préparer les pistes pour la lecture',
                            busy: home.isExtractingSubtitles,
                            onTap: home.isExtractingSubtitles
                                ? null
                                : () => _runLibraryAction(
                                      'Extraction des sous-titres',
                                      home.triggerSubtitleExtract,
                                    ),
                          ),
                        ],
                      ),
                    ),
                    _Section(
                      title: 'Lecture & studio',
                      subtitle:
                          'Playeurs liés au compte, sélection par appareil.',
                      child: Column(
                        children: [
                          _NavTile(
                            icon: Icons.tune_rounded,
                            title: 'Préférences de lecture',
                            subtitle: 'Langue audio par défaut',
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      const PlaybackPreferencesScreen(),
                                ),
                              );
                            },
                          ),
                          _NavTile(
                            icon: Icons.widgets_outlined,
                            title: 'Mes playeurs',
                            subtitle: context
                                    .watch<PlayerLayoutProvider>()
                                    .activePresetName,
                            onTap: () => showPlayerLayoutsSheet(context),
                          ),
                          _NavTile(
                            icon: Icons.dashboard_customize_outlined,
                            title: 'Player Studio',
                            subtitle: 'Composer l’interface du lecteur',
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const PlayerStudioScreen(),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    if (_downloads.isNotEmpty)
                      _Section(
                        title: 'Applications',
                        subtitle:
                            'Installer Onyx sur un autre appareil. Les fichiers sont servis par ce serveur.',
                        child: Column(
                          children: [
                            for (final download in _downloads)
                              _NavTile(
                                icon: _downloadIcon(download.platform),
                                title: download.label,
                                subtitle: _downloadSubtitle(download),
                                onTap: () => _openDownload(download),
                              ),
                          ],
                        ),
                      ),
                    _Section(
                      title: 'Compte',
                      subtitle: auth.currentUser?.username ?? '',
                      child: _NavTile(
                        icon: Icons.logout_rounded,
                        title: 'Se déconnecter',
                        subtitle: 'Revenir à l’écran de connexion',
                        destructive: true,
                        onTap: () {
                          Navigator.of(context).pop();
                          auth.logout();
                        },
                      ),
                    ),
                    if (_saving)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  IconData _downloadIcon(String platform) {
    switch (platform) {
      case 'windows':
        return Icons.desktop_windows_rounded;
      case 'windows-portable':
        return Icons.folder_zip_outlined;
      case 'macos':
        return Icons.laptop_mac_rounded;
      case 'android':
        return Icons.android_rounded;
      default:
        return Icons.download_rounded;
    }
  }

  String _downloadSubtitle(AppDownload download) {
    final parts = <String>[
      if (download.version.isNotEmpty) 'Version ${download.version}',
      if (download.formattedSize.isNotEmpty) download.formattedSize,
    ];
    return parts.join(' · ');
  }

  String _subtitleProgress(HomeProvider home) {
    final stats = home.subtitleStats;
    if (stats.total > 0) {
      return 'Progression ${stats.processed}/${stats.total}';
    }
    return 'Extraction en cours…';
  }

  String _redetectProgress(HomeProvider home) {
    final stats = home.redetectAllProgress;
    if (stats.total > 0) {
      return 'Progression ${stats.processed}/${stats.total}';
    }
    return 'Re-détection en cours…';
  }
}

enum _BannerTone { error, success }

class _Banner extends StatelessWidget {
  final String message;
  final _BannerTone tone;

  const _Banner({required this.message, required this.tone});

  @override
  Widget build(BuildContext context) {
    final isError = tone == _BannerTone.error;
    final color = isError ? AppColors.error : AppColors.success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_outline,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: AppColors.textPrimary.withValues(alpha: 0.92),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _Section({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool busy;
  final VoidCallback? onTap;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: busy
                      ? const Padding(
                          padding: EdgeInsets.all(9),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(icon, color: AppColors.primary, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onTap != null)
                  const Icon(Icons.chevron_right_rounded,
                      color: AppColors.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool destructive;

  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = destructive ? AppColors.error : AppColors.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: accent, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: destructive
                              ? AppColors.error
                              : AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
