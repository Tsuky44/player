import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../access_requests_section.dart';
import '../otp_policy_group.dart';
import '../user_admin_sections.dart';
import '../widgets/settings_ui.dart';
import '../../../l10n/tr.dart';

class UsersPage extends StatelessWidget {
  const UsersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final perms = context.watch<AuthProvider>().permissions;

    return SettingsPage(
      title: tr('Utilisateurs'),
      description: perms.manageUsers
          ? tr('Les comptes du serveur et leurs droits, les personnes qui '
              'demandent un accès et les liens d’invitation.')
          : tr('Les personnes qui demandent un accès et vos liens d’invitation.'),
      children: [
        if (perms.manageUsers)
          SettingsGroup(
            title: tr('Comptes'),
            footer:
                tr('Le propriétaire ne peut pas être rétrogradé. '
                    'Réinitialiser un mot de passe déconnecte tous les '
                    'appareils du compte.'),
            padded: true,
            children: [UsersSection()],
          ),
        // La politique vit dans les réglages du serveur : elle suit leur droit.
        if (perms.manageSettings) const OtpPolicyGroup(),
        // Un inviteur sans manage_users voit aussi cette section — et seulement
        // ses propres liens.
        SettingsGroup(
          title: tr('Demandes d’accès'),
          footer:
              tr('Accepter crée le compte et connecte aussitôt l’appareil '
                  'qui a fait la demande.'),
          padded: true,
          children: [AccessRequestsSection()],
        ),
        SettingsGroup(
          title: tr('Invitations'),
          footer:
              tr('Liens à usage unique, valables 7 jours. Les droits '
                  'accordés sont fixés par un administrateur.'),
          padded: true,
          children: [InvitationsSection()],
        ),
      ],
    );
  }
}
