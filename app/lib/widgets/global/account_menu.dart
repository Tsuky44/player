import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../screens/player_studio/player_studio_screen.dart';
import '../../screens/settings/settings_screen.dart';
import '../../screens/settings/tv_pairing_screen.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import 'glass_chrome.dart';

/// Single owner of the account menu — consumed by the desktop header, the
/// compact tab bar and the Home overlay bar so all three stay identical.
class AccountMenu extends StatelessWidget {
  final AuthProvider authProvider;

  const AccountMenu({super.key, required this.authProvider});

  @override
  Widget build(BuildContext context) {
    // A television approving another television is a flow nobody has; the entry
    // belongs on the device that holds the camera.
    final isTv = TvScope.of(context);

    return PopupMenuButton<String>(
      tooltip: 'Menu',
      offset: const Offset(0, 44),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: AppColors.surfaceElevated.withValues(alpha: 0.96),
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Text(
            authProvider.currentUser?.username ?? '',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'settings', child: Text('Paramètres')),
        const PopupMenuItem(value: 'studio', child: Text('Player Studio')),
        if (!isTv)
          const PopupMenuItem(value: 'tv', child: Text('Connecter une TV')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: Text('Se déconnecter')),
      ],
      onSelected: (value) async {
        switch (value) {
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
              MaterialPageRoute(builder: (_) => const TvPairingScreen()),
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
