import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/server_activity.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../user_admin_sections.dart' show promptPassword;
import '../widgets/device_tile.dart';
import '../widgets/otp_security_group.dart';
import '../widgets/settings_ui.dart';
import '../../../l10n/tr.dart';

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
      }).catchError((_) {
        // Sans statistiques, la page s'affiche sans ce bloc.
      }),
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
              settingsErrorText(e, tr('Impossible de charger vos appareils.')));
        }
      }),
    ]);
  }

  Future<void> _changePassword() async {
    final current = await promptPassword(
      context,
      title: tr('Mot de passe actuel'),
      label: tr('Mot de passe actuel'),
    );
    if (current == null || !mounted) return;
    final next = await promptPassword(
      context,
      title: tr('Nouveau mot de passe'),
      hint: tr('Minimum 4 caractères.'),
    );
    if (next == null || !mounted) return;
    try {
      await context.read<ApiClient>().changeOwnPassword(current, next);
      if (mounted) showSettingsSnack(context, tr('Mot de passe mis à jour.'));
    } catch (_) {
      if (mounted) {
        showSettingsSnack(context, tr('Mot de passe actuel incorrect.'),
            error: true);
      }
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await confirmSettingsAction(
      context,
      title: tr('Supprimer votre compte ?'),
      message:
          tr('Votre compte, votre progression, vos réglages et vos sessions '
              'sont effacés de ce serveur, définitivement. Les fichiers de '
              'la médiathèque ne sont pas touchés.'),
      confirmLabel: tr('Continuer'),
    );
    if (!confirmed || !mounted) return;
    final password = await promptPassword(
      context,
      title: tr('Confirmez avec votre mot de passe'),
      label: tr('Mot de passe'),
    );
    if (password == null || !mounted) return;
    final auth = context.read<AuthProvider>();
    final navigator = Navigator.of(context);
    try {
      await context.read<ApiClient>().deleteOwnAccount(password);
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, tr('Impossible de supprimer le compte.')),
            error: true);
      }
      return;
    }
    navigator.popUntil((route) => route.isFirst);
    await auth.logout();
  }

  Future<void> _revoke(ConnectedDevice device) async {
    final confirmed = await confirmSettingsAction(
      context,
      title: tr('Déconnecter {0} ?', [device.displayName]),
      message:
          tr('Cet appareil devra se reconnecter pour accéder au serveur. '
              'Une lecture en cours s’arrêtera.'),
      confirmLabel: tr('Déconnecter'),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyDevice = device.id);
    try {
      await context.read<ApiClient>().revokeMyDevice(device.id);
      if (mounted) {
        showSettingsSnack(context, tr('{0} déconnecté.', [device.displayName]));
      }
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, tr('Échec de la déconnexion.')),
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
      title: tr('Déconnecter les autres appareils ?'),
      message:
          tr('{0} appareil{1} devront se reconnecter. Celui-ci reste connecté.', [others.length, others.length > 1 ? 's' : '']),
      confirmLabel: tr('Tout déconnecter'),
    );
    if (!confirmed || !mounted) return;
    final api = context.read<ApiClient>();
    for (final device in others) {
      try {
        await api.revokeMyDevice(device.id);
      } catch (_) {
        // Un appareil qui échoue ne retient pas les autres ; la liste rechargée
        // dit ce qu'il reste.
      }
    }
    if (!mounted) return;
    showSettingsSnack(context, tr('Les autres appareils ont été déconnectés.'));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final stats = _stats;
    final devices = _devices;
    final others = devices?.where((d) => !d.isCurrent).length ?? 0;

    return SettingsPage(
      title: tr('Mon compte'),
      description:
          tr('Votre profil sur {0}, votre activité et les appareils où vous '
              'êtes connecté.', [auth.activeServer?.displayName ?? tr('ce serveur')]),
      onRefresh: _load,
      children: [
        if (stats != null) ...[
          StatGrid(children: [
            StatTile(
              icon: Icons.schedule_rounded,
              label: tr('Temps de visionnage'),
              value: formatWatchTime(stats.watchedSeconds),
              hint: tr('30 derniers jours'),
            ),
            StatTile(
              icon: Icons.play_arrow_rounded,
              label: tr('Lectures'),
              value: '${stats.plays}',
              hint: tr('30 derniers jours'),
            ),
            StatTile(
              icon: Icons.movie_outlined,
              label: tr('Films'),
              value: '${stats.movies}',
              color: AppColors.warning,
            ),
            StatTile(
              icon: Icons.tv_rounded,
              label: tr('Épisodes'),
              value: '${stats.episodes}',
              color: AppColors.success,
            ),
          ]),
          if (stats.topMedia.isNotEmpty)
            SettingsGroup(
              title: tr('Vos titres du mois'),
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
          title: tr('Sécurité'),
          children: [
            SettingsTile(
              icon: Icons.password_rounded,
              title: tr('Changer mon mot de passe'),
              subtitle: tr('Vos autres appareils restent connectés.'),
              onTap: _changePassword,
            ),
          ],
        ),
        const OtpSecurityGroup(),
        SettingsGroup(
          title: tr('Mes appareils connectés'),
          trailing: others > 0
              ? TextButton(
                  onPressed: _revokeOthers,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.error,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(tr('Déconnecter les autres')),
                )
              : null,
          footer:
              tr('Une session inutilisée pendant 90 jours est fermée '
                  'automatiquement.'),
          children: [
            if (_devicesError != null)
              SettingsEmptyNote(_devicesError!, icon: Icons.error_outline)
            else if (devices == null)
              const SettingsLoading()
            else if (devices.isEmpty)
              SettingsEmptyNote(tr('Aucun appareil.'))
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
              title: tr('Se déconnecter'),
              subtitle: tr('Fermer la session de cet appareil'),
              destructive: true,
              showChevron: false,
              onTap: () {
                Navigator.of(context).popUntil((route) => route.isFirst);
                auth.logout();
              },
            ),
            SettingsTile(
              icon: Icons.person_remove_outlined,
              title: tr('Supprimer mon compte'),
              subtitle: tr('Effacer ce compte et ses données de ce serveur'),
              destructive: true,
              showChevron: false,
              onTap: _deleteAccount,
            ),
          ],
        ),
      ],
    );
  }
}
