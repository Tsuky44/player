import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/app_download.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_deferred_keyboard.dart';
import '../../../utils/external_url.dart';
import '../widgets/settings_ui.dart';

class AppsPage extends StatefulWidget {
  const AppsPage({super.key});

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  List<AppDownload>? _downloads;

  /// Set while an installer is being sent, so the page can show progress and
  /// refuse a second upload at the same time.
  String? _uploadingLabel;
  double? _uploadProgress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// An older server has no /api/downloads route: the list simply stays empty.
  Future<void> _load() async {
    try {
      final downloads = await context.read<ApiClient>().getAppDownloads();
      if (mounted) setState(() => _downloads = downloads);
    } catch (_) {
      if (mounted) setState(() => _downloads = const []);
    }
  }

  Future<void> _open(AppDownload download) async {
    final url = context.read<ApiClient>().getAppDownloadUrl(download);
    final opened = await openExternalUrl(url);
    if (!mounted || opened) return;
    // Mobile has no way to hand a URL off, so show it for the user to copy.
    showSettingsSnack(context, 'Téléchargement disponible ici : $url');
  }

  /// Picks an installer and publishes it, replacing whatever the server had for
  /// that platform. [replacing] restricts the picker to that artifact's
  /// extension, so "remplacer le DMG" cannot silently overwrite the APK — the
  /// platform is deduced from the extension server-side.
  Future<void> _upload({AppDownload? replacing}) async {
    if (_uploadingLabel != null) return;
    final extensions = replacing != null
        ? [_extensionOf(replacing.file)]
        : const ['exe', 'zip', 'dmg', 'apk', 'ipa'];

    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
        // Only the web has no file path to stream from.
        withData: kIsWeb,
      );
    } catch (_) {
      if (mounted) {
        showSettingsSnack(context, 'Sélecteur de fichiers indisponible.',
            error: true);
      }
      return;
    }
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final file = picked.files.single;

    final version = await _askVersion(file.name, replacing?.version ?? '');
    if (version == null || !mounted) return;

    setState(() {
      _uploadingLabel = file.name;
      _uploadProgress = null;
    });
    try {
      final downloads = await context.read<ApiClient>().uploadAppDownload(
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
      });
      showSettingsSnack(context, 'Installeur publié : ${file.name}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploadingLabel = null;
        _uploadProgress = null;
      });
      showSettingsSnack(
          context, settingsErrorText(e, 'Échec de l’envoi de l’installeur.'),
          error: true);
    }
  }

  Future<void> _delete(AppDownload download) async {
    final confirmed = await confirmSettingsAction(
      context,
      title: 'Supprimer l’installeur ?',
      message: '${download.file} ne sera plus proposé au téléchargement.',
      confirmLabel: 'Supprimer',
    );
    if (!confirmed || !mounted) return;
    try {
      final downloads =
          await context.read<ApiClient>().deleteAppDownload(download);
      if (!mounted) return;
      setState(() => _downloads = downloads);
      showSettingsSnack(context, 'Installeur supprimé.');
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, 'Échec de la suppression.'),
            error: true);
      }
    }
  }

  /// Asks for the version to publish under, pre-filled with the one found in
  /// the file name — a locally built installer carries none.
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
            Text(filename,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 14),
            TvDeferredKeyboard(
              builder: (context, focusNode, canRequestFocus) => TextField(
                focusNode: focusNode,
                canRequestFocus: canRequestFocus,
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Version',
                  hintText: '1.0.0',
                ),
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

  IconData _icon(String platform) => switch (platform) {
        'windows' => Icons.desktop_windows_rounded,
        'windows-portable' => Icons.folder_zip_outlined,
        'macos' => Icons.laptop_mac_rounded,
        'android' => Icons.android_rounded,
        'ios' => Icons.phone_iphone_rounded,
        'tvos' => Icons.tv_rounded,
        _ => Icons.download_rounded,
      };

  @override
  Widget build(BuildContext context) {
    // Publishing the installers this server hands out is server administration.
    final canManage = context.watch<AuthProvider>().permissions.manageSettings;
    final downloads = _downloads;

    return SettingsPage(
      title: 'Applications',
      description:
          'Installer Onyx sur un autre appareil. Les fichiers sont servis directement par votre serveur.',
      children: [
        SettingsGroup(
          title: 'Disponibles au téléchargement',
          children: [
            if (downloads == null)
              const SettingsLoading()
            else if (downloads.isEmpty)
              const SettingsEmptyNote(
                  'Aucun installeur publié sur ce serveur pour l’instant.')
            else
              for (final download in downloads)
                SettingsTile(
                  icon: _icon(download.platform),
                  iconColor: AppColors.primary,
                  title: download.label,
                  subtitle: [
                    if (download.version.isNotEmpty)
                      'Version ${download.version}',
                    if (download.formattedSize.isNotEmpty)
                      download.formattedSize,
                  ].join(' · '),
                  onTap: () => _open(download),
                  trailing: canManage
                      ? _InstallerMenu(
                          enabled: _uploadingLabel == null,
                          onReplace: () => _upload(replacing: download),
                          onDelete: () => _delete(download),
                        )
                      : const Icon(Icons.download_rounded,
                          color: AppColors.textMuted, size: 20),
                ),
          ],
        ),
        if (canManage)
          SettingsGroup(
            title: 'Publication',
            footer:
                'Un installeur par plateforme : en publier un nouveau remplace le précédent.',
            children: [
              SettingsTile(
                icon: Icons.upload_file_rounded,
                title: _uploadingLabel == null
                    ? 'Ajouter ou remplacer un installeur'
                    : 'Envoi de $_uploadingLabel…',
                subtitle: _uploadingLabel == null
                    ? 'Fichier .exe, .zip, .dmg, .apk ou .ipa'
                    : _uploadProgress == null
                        ? 'Envoi en cours…'
                        : 'Envoi ${(_uploadProgress! * 100).clamp(0, 100).toStringAsFixed(0)} %',
                onTap: _uploadingLabel == null ? () => _upload() : null,
              ),
              if (_uploadProgress != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                        value: _uploadProgress, minHeight: 4),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Per-artifact admin actions, so tapping the row itself still downloads.
class _InstallerMenu extends StatelessWidget {
  const _InstallerMenu({
    required this.enabled,
    required this.onReplace,
    required this.onDelete,
  });

  final bool enabled;
  final VoidCallback onReplace;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: 'Gérer cet installeur',
      color: AppColors.surfaceElevated,
      icon: const Icon(Icons.more_horiz_rounded, color: AppColors.textMuted),
      onSelected: (value) => value == 'replace' ? onReplace() : onDelete(),
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
