import 'package:flutter/material.dart';

import '../../../models/server_activity.dart';
import '../../../theme/app_colors.dart';
import 'settings_ui.dart';

/// Une session ouverte : l'appareil, son application, sa dernière activité, et
/// de quoi la fermer.
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.device,
    required this.onRevoke,
    this.busy = false,
    this.showUser = false,
  });

  final ConnectedDevice device;
  final VoidCallback? onRevoke;
  final bool busy;
  final bool showUser;

  @override
  Widget build(BuildContext context) {
    final active = DateTime.now().difference(device.lastSeenAt).inMinutes < 5;
    final details = <String>[
      if (showUser) device.username,
      if (device.client.isNotEmpty) device.client,
      active ? 'actif maintenant' : relativeTime(device.lastSeenAt),
    ];

    return SettingsTile(
      icon: deviceIconFor(device.client),
      iconColor: active ? AppColors.success : null,
      title: device.displayName,
      subtitle: [
        details.join(' · '),
        if (device.nowPlaying.isNotEmpty) '▶ ${device.nowPlaying}',
      ].join('\n'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (device.isCurrent)
            const SettingsPill('Cet appareil', color: AppColors.primary)
          else if (device.address.isNotEmpty)
            Tooltip(
              message: device.address,
              child: SettingsPill(
                device.isLocal ? 'Local' : 'Distant',
                color: device.isLocal
                    ? AppColors.textSecondary
                    : AppColors.warning,
                icon:
                    device.isLocal ? Icons.home_rounded : Icons.public_rounded,
              ),
            ),
          if (onRevoke != null) ...[
            const SizedBox(width: 4),
            busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Déconnecter cet appareil',
                    onPressed: onRevoke,
                    icon: const Icon(Icons.logout_rounded,
                        size: 20, color: AppColors.textMuted),
                  ),
          ],
        ],
      ),
    );
  }
}
