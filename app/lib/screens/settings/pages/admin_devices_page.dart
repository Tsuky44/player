import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/server_activity.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../widgets/device_tile.dart';
import '../widgets/settings_ui.dart';
import '../../../theme/app_type.dart';
import '../../../l10n/tr.dart';

/// Toutes les sessions ouvertes sur le serveur, rangées par compte.
class AdminDevicesPage extends StatefulWidget {
  const AdminDevicesPage({super.key});

  @override
  State<AdminDevicesPage> createState() => _AdminDevicesPageState();
}

class _AdminDevicesPageState extends State<AdminDevicesPage> {
  List<ConnectedDevice>? _devices;
  String? _error;
  int? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final devices = await context.read<ApiClient>().getAllDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          settingsErrorText(e, tr('Impossible de charger les appareils.')));
    }
  }

  Future<void> _revoke(ConnectedDevice device) async {
    final confirmed = await confirmSettingsAction(
      context,
      title: tr('Déconnecter {0} ?', [device.displayName]),
      message:
          tr('{0} devra se reconnecter sur cet appareil. Une lecture en '
              'cours s’arrêtera.', [device.username]),
      confirmLabel: tr('Déconnecter'),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = device.id);
    try {
      await context.read<ApiClient>().revokeAnyDevice(device.id);
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
    setState(() => _busy = null);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final byUser = <String, List<ConnectedDevice>>{};
    for (final device in devices ?? const <ConnectedDevice>[]) {
      byUser.putIfAbsent(device.username, () => []).add(device);
    }
    final remote = (devices ?? const [])
        .where((d) => d.address.isNotEmpty && !d.isLocal)
        .length;
    final activeNow = (devices ?? const [])
        .where((d) => DateTime.now().difference(d.lastSeenAt).inMinutes < 5)
        .length;

    return SettingsPage(
      title: tr('Appareils'),
      description:
          tr('Chaque appareil connecté au serveur, pour chaque compte. '
              'Déconnectez celui que vous ne reconnaissez pas.'),
      onRefresh: _load,
      actions: [
        IconButton(
          tooltip: tr('Actualiser'),
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: [
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (devices == null && _error == null)
          const SettingsLoading()
        else if (devices != null) ...[
          StatGrid(children: [
            StatTile(
              icon: Icons.devices_rounded,
              label: tr('Sessions ouvertes'),
              value: '${devices.length}',
            ),
            StatTile(
              icon: Icons.circle,
              label: tr('Actifs maintenant'),
              value: '$activeNow',
              color: AppColors.success,
            ),
            StatTile(
              icon: Icons.group_rounded,
              label: tr('Comptes'),
              value: '${byUser.length}',
              color: AppColors.accentMuted,
            ),
            StatTile(
              icon: Icons.public_rounded,
              label: tr('Hors du réseau local'),
              value: '$remote',
              color: remote > 0 ? AppColors.warning : AppColors.textMuted,
              hint: tr('depuis le démarrage'),
            ),
          ]),
          if (devices.isEmpty)
            SettingsGroup(
                children: [SettingsEmptyNote(tr('Aucun appareil connecté.'))]),
          for (final entry in byUser.entries)
            SettingsGroup(
              title: entry.key,
              trailing: Text(
                '${entry.value.length} appareil${entry.value.length > 1 ? 's' : ''}',
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: AppType.footnote),
              ),
              children: [
                for (final device in entry.value)
                  DeviceTile(
                    device: device,
                    busy: _busy == device.id,
                    onRevoke: device.isCurrent ? null : () => _revoke(device),
                  ),
              ],
            ),
        ],
      ],
    );
  }
}
