import 'package:dio/dio.dart' show DioException;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../tv/tv_mode.dart';
import 'tv_link_scanner_screen.dart';

import '../../models/app_download.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/player_layout_provider.dart';
import '../../services/api_client.dart';
import '../player/display_frame_rate.dart';
import '../player/hardware_decoding.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_platform.dart';
import '../../utils/external_url.dart';
import '../player_studio/player_studio_screen.dart';
import '../player_studio/widgets/player_layouts_sheet.dart';
import 'exoplayer_probe_screen.dart';
import 'playback_preferences_screen.dart';
import 'user_admin_sections.dart';

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

  /// Set while an installer is being sent, so the section can show progress and
  /// refuse a second upload at the same time.
  String? _uploadingLabel;
  double? _uploadProgress;

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

    // Server settings are only readable with manage_settings — asking without
    // it would answer 403 and turn into a spurious error banner.
    if (!context.read<AuthProvider>().permissions.manageSettings) {
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }

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

  /// Picks an installer and publishes it, replacing whatever the server had for
  /// that platform. Reserved to the admin account: the route rejects anyone
  /// else, this only decides whether the entry point is shown.
  ///
  /// [replacing] restricts the picker to that artifact's extension, so
  /// "remplacer le DMG" cannot silently overwrite the APK — the platform is
  /// deduced from the extension server-side.
  Future<void> _uploadInstaller({AppDownload? replacing}) async {
    if (_uploadingLabel != null) return;

    final extensions = replacing != null
        ? [_extensionOf(replacing.file)]
        : const ['exe', 'zip', 'dmg', 'apk'];

    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
        // Only the web has no file path to stream from; elsewhere reading a
        // 150 MB installer into memory would be pointless.
        withData: kIsWeb,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Sélecteur de fichiers indisponible.');
      return;
    }
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    if (!mounted) return;

    final version = await _askVersion(file.name, replacing?.version ?? '');
    if (version == null || !mounted) return;

    setState(() {
      _uploadingLabel = file.name;
      _uploadProgress = null;
      _error = null;
      _success = null;
    });

    try {
      final api = context.read<ApiClient>();
      final downloads = await api.uploadAppDownload(
        filename: file.name,
        path: kIsWeb ? null : file.path,
        bytes: kIsWeb ? file.bytes : null,
        version: version,
        onProgress: (sent, total) {
          if (!mounted || total <= 0) return;
          setState(() => _uploadProgress = sent / total);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloads = downloads;
        _uploadingLabel = null;
        _uploadProgress = null;
        _success = 'Installeur publié : ${file.name}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploadingLabel = null;
        _uploadProgress = null;
        _error = _installerError(e, 'Échec de l’envoi de l’installeur.');
      });
    }
  }

  Future<void> _deleteInstaller(AppDownload download) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Supprimer l’installeur ?'),
        content: Text(
          '${download.file} ne sera plus proposé au téléchargement.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final api = context.read<ApiClient>();
      final downloads = await api.deleteAppDownload(download);
      if (!mounted) return;
      setState(() {
        _downloads = downloads;
        _success = 'Installeur supprimé.';
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _installerError(e, 'Échec de la suppression.');
        _success = null;
      });
    }
  }

  /// Asks for the version to publish under, pre-filled with the one found in
  /// the file name — a locally built `ProjectPlayer-Setup.exe` carries none, and
  /// the listing shows that version to every user.
  Future<String?> _askVersion(String filename, String fallback) {
    final match = RegExp(r'(\d+\.\d+(?:\.\d+)?)').firstMatch(filename);
    final controller = TextEditingController(
      text: match?.group(1) ?? (fallback.isNotEmpty ? fallback : '1.0.0'),
    );
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Publier l’installeur'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              filename,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Version',
                hintText: '1.0.0',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Publier'),
          ),
        ],
      ),
    );
  }

  String _extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  }

  /// Surfaces the server's own message (403 for a non-admin, 413 for a file
  /// over the cap) rather than a generic failure.
  String _installerError(Object error, String fallback) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] != null) return data['error'].toString();
    }
    return fallback;
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

  /// Self-service password rotation. Asks for the current password, so this is
  /// a rotation and not a recovery — other sessions keep working.
  Future<void> _changeOwnPassword() async {
    final current = await promptPassword(
      context,
      title: 'Mot de passe actuel',
      label: 'Mot de passe actuel',
    );
    if (current == null || !mounted) return;

    final next = await promptPassword(
      context,
      title: 'Nouveau mot de passe',
      hint: 'Minimum 4 caractères.',
    );
    if (next == null || !mounted) return;

    try {
      await context.read<ApiClient>().changeOwnPassword(current, next);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mot de passe mis à jour.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mot de passe actuel incorrect.'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeProvider>();
    final auth = context.watch<AuthProvider>();
    final perms = auth.permissions;
    // Publishing the installers this server hands out is server administration.
    final canManageInstallers = perms.manageSettings;
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
                    // Sections a user has no right to are absent, not greyed
                    // out: what is not drawn cannot produce a 403, and nobody
                    // needs to know a TMDB key exists.
                    if (perms.manageSettings)
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
                    if (perms.manageSettings)
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
                    // Paths belong to manage_settings, indexing actions to
                    // manage_library: delegating a scan is harmless, repointing
                    // MoviesDir is not.
                    if (perms.manageSettings || perms.manageLibrary)
                    _Section(
                      title: 'Bibliothèque',
                      subtitle: perms.manageSettings
                          ? 'Chemins scannés côté serveur, puis actions d’indexation.'
                          : 'Actions d’indexation de la bibliothèque.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (perms.manageSettings) ...[
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
                          ],
                          if (perms.manageLibrary) ...[
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
                        ],
                      ),
                    ),
                    if (perms.manageUsers)
                      const _Section(
                        title: 'Utilisateurs',
                        subtitle:
                            'Comptes du serveur et droits de chacun. Le propriétaire ne peut pas être rétrogradé.',
                        child: UsersSection(),
                      ),
                    // An inviter without manage_users still gets this section —
                    // and sees only their own links.
                    if (perms.inviteUsers || perms.manageUsers)
                      const _Section(
                        title: 'Invitations',
                        subtitle:
                            'Liens à usage unique, valables 7 jours. Les droits accordés sont fixés par un administrateur.',
                        child: InvitationsSection(),
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
                    if (_downloads.isNotEmpty || canManageInstallers)
                      _Section(
                        title: 'Applications',
                        subtitle: canManageInstallers
                            ? 'Installer Onyx sur un autre appareil. En tant qu’administrateur, vous pouvez remplacer les installeurs publiés par ce serveur.'
                            : 'Installer Onyx sur un autre appareil. Les fichiers sont servis par ce serveur.',
                        child: Column(
                          children: [
                            for (final download in _downloads)
                              _NavTile(
                                icon: _downloadIcon(download.platform),
                                title: download.label,
                                subtitle: _downloadSubtitle(download),
                                onTap: () => _openDownload(download),
                                trailing: canManageInstallers
                                    ? _InstallerMenu(
                                        enabled: _uploadingLabel == null,
                                        onReplace: () => _uploadInstaller(
                                          replacing: download,
                                        ),
                                        onDelete: () =>
                                            _deleteInstaller(download),
                                      )
                                    : null,
                              ),
                            if (canManageInstallers) ...[
                              if (_downloads.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    'Aucun installeur publié pour l’instant.',
                                    style: TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              _ActionTile(
                                icon: Icons.upload_file_rounded,
                                title: _uploadingLabel == null
                                    ? 'Ajouter ou remplacer un installeur'
                                    : 'Envoi de $_uploadingLabel…',
                                subtitle: _uploadingLabel == null
                                    ? 'Fichier .exe, .zip, .dmg ou .apk — un par plateforme'
                                    : _uploadProgressLabel(),
                                busy: _uploadingLabel != null,
                                onTap: _uploadingLabel == null
                                    ? () => _uploadInstaller()
                                    : null,
                              ),
                              if (_uploadProgress != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: _uploadProgress,
                                      minHeight: 4,
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    _Section(
                      title: 'Téléviseur',
                      subtitle:
                          'Navigation à la télécommande et connexion par QR code.',
                      child: Column(
                        children: [
                          if (AppPlatform.isMobile && !TvScope.of(context))
                            _NavTile(
                              icon: Icons.tv_rounded,
                              title: 'Connecter un téléviseur',
                              subtitle:
                                  'Scanner le code affiché sur le téléviseur',
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const TvLinkScannerScreen(),
                                ),
                              ),
                            ),
                          const _TvModeTile(),
                          const _HardwareDecodingTile(),
                          const _FrameRateMatchingTile(),
                          // Temporaire — banc d'essai du portage ExoPlayer.
                          // À retirer avec l'écran qu'il ouvre, dès que le
                          // jalon a rendu son verdict.
                          if (AppPlatform.isAndroid)
                            _NavTile(
                              icon: Icons.science_outlined,
                              title: 'Banc d’essai ExoPlayer',
                              subtitle:
                                  'Mesure les images perdues sur un fichier',
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const ExoPlayerProbeScreen(),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    _Section(
                      title: 'Compte',
                      subtitle: auth.currentUser?.username ?? '',
                      child: Column(
                        children: [
                          // Without this, the password an admin typed when
                          // creating the account would stay theirs forever.
                          _NavTile(
                            icon: Icons.password_rounded,
                            title: 'Changer mon mot de passe',
                            subtitle: 'Remplacer le mot de passe de ce compte',
                            onTap: _changeOwnPassword,
                          ),
                          _NavTile(
                            icon: Icons.logout_rounded,
                            title: 'Se déconnecter',
                            subtitle: 'Revenir à l’écran de connexion',
                            destructive: true,
                            onTap: () {
                              Navigator.of(context).pop();
                              auth.logout();
                            },
                          ),
                        ],
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

  String _uploadProgressLabel() {
    final progress = _uploadProgress;
    if (progress == null) return 'Envoi en cours…';
    return 'Envoi ${(progress * 100).clamp(0, 100).toStringAsFixed(0)} %';
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

/// Per-artifact admin actions, in place of the tile's chevron so tapping the
/// tile itself still means "télécharger".
class _InstallerMenu extends StatelessWidget {
  final bool enabled;
  final VoidCallback onReplace;
  final VoidCallback onDelete;

  const _InstallerMenu({
    required this.enabled,
    required this.onReplace,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: 'Gérer cet installeur',
      color: AppColors.surfaceElevated,
      icon: const Icon(Icons.more_vert_rounded, color: AppColors.textMuted),
      onSelected: (value) {
        if (value == 'replace') {
          onReplace();
        } else {
          onDelete();
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'replace',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.upload_file_rounded, size: 18),
            title: Text('Remplacer'),
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline_rounded,
                size: 18, color: AppColors.error),
            title: Text('Supprimer', style: TextStyle(color: AppColors.error)),
          ),
        ),
      ],
    );
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

  /// Replaces the chevron, for tiles that carry their own actions.
  final Widget? trailing;

  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
    this.trailing,
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
                trailing ??
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

/// Escape hatch for a device whose zero-copy decoder is broken.
///
/// The default hands decoded frames straight to the GPU, which is what makes a
/// 4K film playable on a streaming stick. Some Android vendors ship a
/// MediaCodec that reports success and produces a green or black picture; that
/// cannot be detected from the app, because mpv is told the frames decoded and
/// displayed fine. So it is offered as a choice, with the fast path as the
/// default and a working picture always one tap away.
class _HardwareDecodingTile extends StatefulWidget {
  const _HardwareDecodingTile();

  @override
  State<_HardwareDecodingTile> createState() => _HardwareDecodingTileState();
}

class _HardwareDecodingTileState extends State<_HardwareDecodingTile> {
  Future<void> _apply(HardwareDecodingPreference preference) async {
    await HardwareDecoding.setPreference(preference);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Décodage matériel',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Passez sur « Compatible » si l\'image est noire ou verte alors '
            'que le son fonctionne.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          SegmentedButton<HardwareDecodingPreference>(
            segments: const [
              ButtonSegment(
                value: HardwareDecodingPreference.auto,
                label: Text('Rapide'),
              ),
              ButtonSegment(
                value: HardwareDecodingPreference.copy,
                label: Text('Compatible'),
              ),
              ButtonSegment(
                value: HardwareDecodingPreference.off,
                label: Text('Logiciel'),
              ),
            ],
            selected: {HardwareDecoding.preference},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => _apply(selection.first),
          ),
          const SizedBox(height: 6),
          const Text(
            'Le changement prend effet à la prochaine lecture.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Override for the automatic television detection.
///
/// Detection reads the hardware and is right almost always. The two ways it is
/// wrong pull in opposite directions — a no-name Android box that never
/// advertises leanback, and a tablet in a dock that does — so the override has
/// to be able to push both ways, not just off.
class _TvModeTile extends StatefulWidget {
  const _TvModeTile();

  @override
  State<_TvModeTile> createState() => _TvModeTileState();
}

class _TvModeTileState extends State<_TvModeTile> {
  Future<void> _apply(TvModePreference preference) async {
    await TvMode.setPreference(preference);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final detected = TvMode.detected ? 'un téléviseur' : 'un appareil tactile';

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mode télécommande',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Cet appareil est détecté comme $detected.',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          SegmentedButton<TvModePreference>(
            segments: const [
              ButtonSegment(
                value: TvModePreference.auto,
                label: Text('Auto'),
              ),
              ButtonSegment(
                value: TvModePreference.on,
                label: Text('Activé'),
              ),
              ButtonSegment(
                value: TvModePreference.off,
                label: Text('Désactivé'),
              ),
            ],
            selected: {TvMode.preference},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => _apply(selection.first),
          ),
        ],
      ),
    );
  }
}

/// Whether the player may take over the television's display mode.
///
/// Left on by default: matching the panel to the film is what removes the 3:2
/// judder, and it is the single biggest difference between this and a set-top
/// player. But a mode switch makes the set renegotiate HDMI, and a set that
/// comes back badly from that renegotiation turns some films — the ones with a
/// mode to switch to — into a playback that stalls. This is the way out.
class _FrameRateMatchingTile extends StatefulWidget {
  const _FrameRateMatchingTile();

  @override
  State<_FrameRateMatchingTile> createState() => _FrameRateMatchingTileState();
}

class _FrameRateMatchingTileState extends State<_FrameRateMatchingTile> {
  Future<void> _apply(bool value) async {
    await DisplayFrameRate.setEnabled(value);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Android only: nothing else lets an app choose the display mode, and the
    // toggle would sit there doing nothing.
    if (!AppPlatform.isAndroid) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Adapter l’écran au film',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Switch(
                value: DisplayFrameRate.enabled,
                onChanged: _apply,
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Fait passer le téléviseur à une fréquence multiple de celle du '
            'film, ce qui supprime les saccades des travellings. Désactivez-le '
            'si la lecture se fige peu après le démarrage sur certains films.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          const Text(
            'Le changement prend effet à la prochaine lecture.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
