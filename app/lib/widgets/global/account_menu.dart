import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../screens/settings/settings_screen.dart';
import '../../screens/settings/tv_link_scanner_screen.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import '../../utils/app_platform.dart';
import 'glass_chrome.dart';
import 'join_watch_party_dialog.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';

/// Single owner of the account menu — consumed by the desktop header, the
/// compact tab bar and the Home overlay bar so all three stay identical.
class AccountMenu extends StatelessWidget {
  final AuthProvider authProvider;

  const AccountMenu({super.key, required this.authProvider});

  @override
  Widget build(BuildContext context) {
    // The entry point is a QR scanner — for a television, a browser or a
    // desktop app (ADR-0020) — so it belongs on the device that holds a camera,
    // which is the phone and only the phone.
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
                  // Le rôle, pour qu'un membre sache d'emblée ce qu'il peut
                  // faire sur ce serveur — et pourquoi il ne voit pas les
                  // actions d'administration.
                  '${authProvider.activeServer!.displayName} · '
                  '${authProvider.permissions.isAdmin ? 'Administrateur' : 'Membre'}',
                  style: const TextStyle(
                    fontSize: AppType.caption,
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
                    const Icon(AppIcons.switchServer, size: 16),
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
        const PopupMenuItem(
          value: 'watch-party',
          child: Row(
            children: [
              Icon(AppIcons.watchParty, size: 16),
              SizedBox(width: 8),
              Text('Rejoindre une séance'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        // « Serveurs » et « Player Studio » ont quitté ce menu : le premier
        // ouvrait les mêmes Paramètres sur une autre section, le second est
        // dans Paramètres › Lecture, avec le reste de l'interface du lecteur.
        const PopupMenuItem(
          value: 'settings',
          child: _MenuRow(icon: AppIcons.settings, label: 'Paramètres'),
        ),
        if (canLinkTv)
          const PopupMenuItem(
            value: 'tv',
            child: _MenuRow(
              icon: AppIcons.scan,
              label: 'Connecter un appareil',
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'logout',
          child: _MenuRow(icon: AppIcons.signOut, label: 'Se déconnecter'),
        ),
      ],
      onSelected: (value) async {
        if (value.startsWith('switch:')) {
          await authProvider.switchServer(value.substring('switch:'.length));
          return;
        }
        switch (value) {
          case 'watch-party':
            await showJoinWatchPartyDialog(context, authProvider: authProvider);
          case 'settings':
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
          case 'tv':
            Navigator.of(context, rootNavigator: true).push(
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
            fontSize: AppType.subhead,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Une entrée du menu : une icône de 16 px et son libellé, comme les entrées
/// « Passer sur… » et « Rejoindre une séance » au-dessus.
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}
