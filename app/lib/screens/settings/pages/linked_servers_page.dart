import 'package:flutter/material.dart';

import '../linked_servers_section.dart';
import '../widgets/settings_ui.dart';

/// Les serveurs liés à celui-ci (ADR-0017).
class LinkedServersPage extends StatelessWidget {
  const LinkedServersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsPage(
      title: 'Serveurs liés',
      description:
          'Autoriser un lien permet à deux serveurs de se transmettre la progression des comptes que leurs utilisateurs ont liés. À accepter une fois par serveur, de chaque côté.',
      children: [
        SettingsGroup(
          title: 'Serveurs',
          padded: true,
          children: [LinkedServersSection()],
        ),
      ],
    );
  }
}
