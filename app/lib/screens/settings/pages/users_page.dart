import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../access_requests_section.dart';
import '../user_admin_sections.dart';
import '../widgets/settings_ui.dart';

class UsersPage extends StatelessWidget {
  const UsersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final perms = context.watch<AuthProvider>().permissions;

    return SettingsPage(
      title: 'Utilisateurs',
      description: perms.manageUsers
          ? 'Les comptes du serveur et leurs droits, les personnes qui demandent un accès et les liens d’invitation.'
          : 'Les personnes qui demandent un accès et vos liens d’invitation.',
      children: [
        if (perms.manageUsers)
          const SettingsGroup(
            title: 'Comptes',
            footer:
                'Le propriétaire ne peut pas être rétrogradé. Réinitialiser un mot de passe déconnecte tous les appareils du compte.',
            padded: true,
            children: [UsersSection()],
          ),
        // Un inviteur sans manage_users voit aussi cette section — et seulement
        // ses propres liens.
        const SettingsGroup(
          title: 'Demandes d’accès',
          footer:
              'Accepter crée le compte et connecte aussitôt l’appareil qui a fait la demande.',
          padded: true,
          children: [AccessRequestsSection()],
        ),
        const SettingsGroup(
          title: 'Invitations',
          footer:
              'Liens à usage unique, valables 7 jours. Les droits accordés sont fixés par un administrateur.',
          padded: true,
          children: [InvitationsSection()],
        ),
      ],
    );
  }
}
