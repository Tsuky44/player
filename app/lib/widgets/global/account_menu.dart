import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../screens/player_studio/player_studio_screen.dart';
import '../../screens/settings/servers_screen.dart';
import '../../screens/settings/settings_screen.dart';
import '../../screens/settings/tv_link_scanner_screen.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import '../../utils/app_platform.dart';
import 'glass_chrome.dart';

/// Single owner of the account menu — consumed by the desktop header, the
/// compact tab bar and the Home overlay bar so all three stay identical.
class AccountMenu extends StatelessWidget {
  final AuthProvider authProvider;

  const AccountMenu({super.key, required this.authProvider});

  @override
  Widget build(BuildContext context) {
    // A television linking another television is a flow nobody has, and the
    // entry point is a QR scanner — so it belongs on the device that holds a
    // camera, which is the phone and only the phone.
    final canLinkTv = AppPlatform.isMobile && !TvScope.of(context);

    // Un seul serveur n'a pas besoin d'un sélecteur ; à partir de deux, c'est
    // le geste le plus fréquent du menu, donc il est là et pas dans les
    // réglages. Voir ADR-0013.
    final servers = authProvider.servers;
    final activeId = authProvider.activeServer?.id;
    final canSwitch = servers.length > 1;

    return PopupMenuButton<String>(
      tooltip: 'Menu',
      offset: const Offset(0, 44),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: AppColors.surfaceElevated.withValues(alpha: 0.96),
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                authProvider.currentUser?.username ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (authProvider.activeServer != null)
                Text(
                  authProvider.activeServer!.displayName,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        if (canSwitch) ...[
          for (final account in servers)
            if (account.id != activeId)
              PopupMenuItem(
                value: 'switch:${account.id}',
                child: Row(
                  children: [
                    const Icon(Icons.swap_horiz_rounded, size: 16),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Passer sur ${account.displayName}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(value: 'servers', child: Text('Serveurs')),
        const PopupMenuItem(value: 'settings', child: Text('Paramètres')),
        const PopupMenuItem(value: 'studio', child: Text('Player Studio')),
        if (canLinkTv)
          const PopupMenuItem(
            value: 'tv',
            child: Text('Connecter un téléviseur'),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: Text('Se déconnecter')),
      ],
      onSelected: (value) async {
        if (value.startsWith('switch:')) {
          await authProvider.switchServer(value.substring('switch:'.length));
          return;
        }
        switch (value) {
          case 'servers':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ServersScreen()),
            );
          case 'settings':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
          case 'studio':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerStudioScreen()),
            );
          case 'tv':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TvLinkScannerScreen()),
            );
          case 'logout':
            authProvider.logout();
        }
      },
      child: GlassIconButton(
        size: 34,
        child: Text(
          (authProvider.currentUser?.username ?? '?')[0].toUpperCase(),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
