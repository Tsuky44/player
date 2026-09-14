import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/server_activity.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../user_admin_sections.dart' show promptPassword;
import '../widgets/device_tile.dart';
import '../widgets/settings_ui.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  PlaybackStats? _stats;
  List<ConnectedDevice>? _devices;
  String? _devicesError;
  int? _busyDevice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<ApiClient>();
    await Future.wait([
      api.getMyPlaybackStats(days: 30).then((stats) {
        if (mounted) setState(() => _stats = stats);
      }).catchError((_) {}),
      api.getMyDevices().then((devices) {
        if (mounted) {
          setState(() {
            _devices = devices;
            _devicesError = null;
          });
        }
      }).catchError((Object e) {
        if (mounted) {
          setState(() => _devicesError =
              settingsErrorText(e, 'Impossible de charger vos appareils.'));
        }
      }),
    ]);
  }

  Future<void> _changePassword() async {
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
      if (mounted) showSettingsSnack(context, 'Mot de passe mis à jour.');
    } catch (_) {
      if (mounted) {
        showSettingsSnack(context, 'Mot de passe actuel incorrect.',
            error: true);
      }
    }
  }

  Future<void> _revoke(ConnectedDevice device) async {
    final confirmed = await confirmSettingsAction(
      context,
      title: 'Déconnecter ${device.displayName} ?',
      message:
          'Cet appareil devra se reconnecter pour accéder au serveur. Une lecture en cours s’arrêtera.',
      confirmLabel: 'Déconnecter',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyDevice = device.id);
    try {
      await context.read<ApiClient>().revokeMyDevice(device.id);
      if (mounted) {
        showSettingsSnack(context, '${device.displayName} déconnecté.');
      }
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, 'Échec de la déconnexion.'),
            error: true);
      }
    }
    if (!mounted) return;
    setState(() => _busyDevice = null);
    _load();
  }

  Future<void> _revokeOthers() async {
    final others = (_devices ?? const []).where((d) => !d.isCurrent).toList();
    if (others.isEmpty) return;
    final confirmed = await confirmSettingsAction(
      context,
      title: 'Déconnecter les autres appareils ?',
      message:
          '${others.length} appareil${others.length > 1 ? 's' : ''} devront se reconnecter. Celui-ci reste connecté.',
      confirmLabel: 'Tout déconnecter',
    );
    if (!confirmed || !mounted) return;
    final api = context.read<ApiClient>();
    for (final device in others) {
      try {
        await api.revokeMyDevice(device.id);
      } catch (_) {}
    }
    if (!mounted) return;
    showSettingsSnack(context, 'Les autres appareils ont été déconnectés.');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final stats = _stats;
    final devices = _devices;
    final others = devices?.where((d) => !d.isCurrent).length ?? 0;

    return SettingsPage(
      title: 'Mon compte',
      description:
          'Votre profil sur ${auth.activeServer?.displayName ?? 'ce serveur'}, votre activité et les appareils où vous êtes connecté.',
      onRefresh: _load,
      children: [
        if (stats != null) ...[
          StatGrid(children: [
            StatTile(
              icon: Icons.schedule_rounded,
              label: 'Temps de visionnage',
              value: formatWatchTime(stats.watchedSeconds),
              hint: '30 derniers jours',
            ),
            StatTile(
              icon: Icons.play_arrow_rounded,
              label: 'Lectures',
              value: '${stats.plays}',
              hint: '30 derniers jours',
            ),
            StatTile(
              icon: Icons.movie_outlined,
              label: 'Films',
              value: '${stats.movies}',
              color: AppColors.warning,
            ),
            StatTile(
              icon: Icons.tv_rounded,
              label: 'Épisodes',
              value: '${stats.episodes}',
              color: AppColors.success,
            ),
          ]),
          if (stats.topMedia.isNotEmpty)
            SettingsGroup(
              title: 'Vos titres du mois',
              children: [
                for (final media in stats.topMedia.take(3))
                  SettingsTile(
                    icon: media.mediaType == 'show'
                        ? Icons.tv_rounded
                        : Icons.movie_outlined,
                    title: media.label,
                    subtitle: [
                      if (media.secondary.isNotEmpty) media.secondary,
                      '${media.plays} lecture${media.plays > 1 ? 's' : ''}',
                    ].join(' · '),
                    trailing: Text(
                      formatWatchTime(media.watchedSeconds),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
        ],
        SettingsGroup(
          title: 'Sécurité',
          children: [
            SettingsTile(
              icon: Icons.password_rounded,
              title: 'Changer mon mot de passe',
              subtitle: 'Vos autres appareils restent connectés.',
              onTap: _changePassword,
            ),
          ],
        ),
        SettingsGroup(
          title: 'Mes appareils connectés',
          trailing: others > 0
              ? TextButton(
                  onPressed: _revokeOthers,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.error,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Déconnecter les autres'),
                )
              : null,
          footer:
              'Une session inutilisée pendant 90 jours est fermée automatiquement.',
          children: [
            if (_devicesError != null)
              SettingsEmptyNote(_devicesError!, icon: Icons.error_outline)
            else if (devices == null)
              const SettingsLoading()
            else if (devices.isEmpty)
              const SettingsEmptyNote('Aucun appareil.')
            else
              for (final device in devices)
                DeviceTile(
                  device: device,
                  busy: _busyDevice == device.id,
                  onRevoke: device.isCurrent ? null : () => _revoke(device),
                ),
          ],
        ),
        SettingsGroup(
          children: [
            SettingsTile(
              icon: Icons.logout_rounded,
              title: 'Se déconnecter',
              subtitle: 'Fermer la session de cet appareil',
              destructive: true,
              showChevron: false,
              onTap: () {
                Navigator.of(context).popUntil((route) => route.isFirst);
                auth.logout();
              },
            ),
          ],
        ),
      ],
    );
  }
}
