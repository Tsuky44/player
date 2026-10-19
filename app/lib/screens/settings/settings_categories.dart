import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../tv/tv_mode.dart';
import '../../utils/app_platform.dart';
import 'pages/account_page.dart';
import 'pages/activity_page.dart';
import 'pages/admin_devices_page.dart';
import 'pages/announcement_page.dart';
import 'pages/dashboard_page.dart';
import 'pages/device_page.dart';
import 'pages/downloads_page.dart';
import 'pages/emby_sync_page.dart';
import 'pages/integrations_page.dart';
import 'pages/library_page.dart';
import 'pages/linked_servers_page.dart';
import 'pages/playback_page.dart';
import 'pages/servers_page.dart';
import 'pages/shares_page.dart';
import 'pages/stats_page.dart';
import 'pages/users_page.dart';
import 'settings_sections.dart';
import 'widgets/settings_category_body.dart';
import '../../l10n/tr.dart';

/// Une entrée de la navigation des paramètres.
///
/// Une entrée réunit les pages qu'on cherche au même endroit : on ne fouille
/// pas trois catégories pour trouver où l'on a laissé un réglage qu'on ouvre
/// deux fois par an. Les pages restent séparées dans le code et gardent leur
/// adresse ([SettingsSections]).
class SettingsCategory {
  const SettingsCategory({
    required this.id,
    required this.label,
    required this.icon,
    required this.hint,
    required this.admin,
    required this.sections,
    this.layout = SettingsSectionsLayout.stacked,
  });

  final String id;
  final String label;
  final IconData icon;

  /// La ligne sous le libellé dans la liste mobile : ce qu'on y trouve.
  final String hint;
  final bool admin;
  final List<SettingsSection> sections;
  final SettingsSectionsLayout layout;

  /// Vrai si [sectionId] désigne cette entrée ou l'une de ses pages.
  bool opens(String sectionId) =>
      sectionId == id || sections.any((s) => s.id == sectionId);

  Widget build(BuildContext context, {String? section}) =>
      SettingsCategoryBody(
        title: label,
        sections: sections,
        layout: layout,
        initialSection: section,
      );
}

/// Ce qu'un compte voit dépend de ses droits : une page qu'il ne peut pas
/// utiliser n'est pas grisée, elle est absente, et une catégorie vidée
/// disparaît. Ce qui n'est pas dessiné ne produit pas de 403.
///
/// « Mon espace » va du plus personnel (le compte) au plus technique (les
/// serveurs) ; « Administration » du plus consulté (l'activité) au plus rare.
List<SettingsCategory> settingsCategoriesFor(Permissions p) {
  final anyAdmin = p.manageSettings || p.manageLibrary || p.manageUsers;
  // Ouvrir un lien reçu ne demande aucun droit (ADR-0037 §11) ; seul un
  // téléviseur, sans presse-papiers où le recevoir, n'a rien à y faire tant
  // que le compte n'a pas de liens à lui.
  final shares = p.shareMedia || !TvMode.isTv;

  final categories = [
    SettingsCategory(
      id: SettingsSections.account,
      label: tr('Mon compte'),
      icon: Icons.person_rounded,
      hint: tr('Profil, mot de passe, appareils connectés'),
      admin: false,
      sections: [
        SettingsSection(
          id: SettingsSections.account,
          label: tr('Mon compte'),
          builder: (_) => const AccountPage(),
        ),
      ],
    ),
    SettingsCategory(
      id: SettingsSections.device,
      label: tr('Général'),
      icon: Icons.tune_rounded,
      hint: tr('Langue, affichage, notifications, aide'),
      admin: false,
      sections: [
        SettingsSection(
          id: SettingsSections.device,
          label: tr('Général'),
          builder: (_) => const DevicePage(),
        ),
      ],
    ),
    SettingsCategory(
      id: SettingsSections.playback,
      label: tr('Lecture'),
      icon: Icons.play_circle_outline_rounded,
      hint: tr('Langue audio, décodage, interface du lecteur'),
      admin: false,
      sections: [
        SettingsSection(
          id: SettingsSections.playback,
          label: tr('Lecture'),
          builder: (_) => const PlaybackPage(),
        ),
      ],
    ),
    // Un navigateur n'a pas de dossier privé où garder un film, une Apple TV
    // n'en a qu'un que le système vide à sa guise : la catégorie n'aurait que
    // des réglages sans effet à proposer.
    if (!AppPlatform.isWeb && !AppPlatform.isTvOS)
      SettingsCategory(
        id: SettingsSections.downloads,
        label: tr('Téléchargements'),
        icon: Icons.download_rounded,
        hint: tr('Épisodes d’avance, réseau autorisé, place occupée'),
        admin: false,
        sections: [
          SettingsSection(
            id: SettingsSections.downloads,
            label: tr('Téléchargements'),
            builder: (_) => const DownloadsPage(),
          ),
        ],
      ),
    // Les serveurs Onyx, le serveur Emby dont on reprend la progression, et
    // les liens qui ouvrent un média d'un serveur sans compte : tout ce qui
    // relie cet appareil à un serveur.
    SettingsCategory(
      id: SettingsSections.servers,
      label: tr('Serveurs et partage'),
      icon: Icons.dns_rounded,
      hint: shares
          ? tr('Vos serveurs, synchro Emby, liens de partage')
          : tr('Vos serveurs et la synchro Emby'),
      admin: false,
      sections: [
        SettingsSection(
          id: SettingsSections.servers,
          label: tr('Serveurs'),
          builder: (_) => const ServersPage(),
        ),
        SettingsSection(
          id: SettingsSections.emby,
          label: tr('Synchro Emby'),
          builder: (_) => const EmbySyncPage(),
        ),
        if (shares)
          SettingsSection(
            id: SettingsSections.shares,
            label: tr('Liens de partage'),
            builder: (_) => const SharesPage(),
          ),
      ],
    ),
    if (anyAdmin)
      SettingsCategory(
        id: SettingsSections.dashboard,
        label: tr('Activité'),
        icon: Icons.space_dashboard_rounded,
        hint: p.manageUsers
            ? tr('Lectures en cours, historique, statistiques')
            : tr('Lectures en cours, état du serveur'),
        admin: true,
        layout: SettingsSectionsLayout.tabbed,
        sections: [
          SettingsSection(
            id: SettingsSections.dashboard,
            label: tr('Vue d’ensemble'),
            builder: (_) => const DashboardPage(),
          ),
          if (p.manageUsers) ...[
            SettingsSection(
              id: SettingsSections.activity,
              label: tr('Historique'),
              builder: (_) => const ActivityPage(),
            ),
            SettingsSection(
              id: SettingsSections.stats,
              label: tr('Statistiques'),
              builder: (_) => const StatsPage(),
            ),
          ],
        ],
      ),
    SettingsCategory(
      id: SettingsSections.users,
      label: tr('Utilisateurs'),
      icon: Icons.group_rounded,
      hint: tr('Comptes, invitations, appareils, message à tous'),
      admin: true,
      layout: SettingsSectionsLayout.tabbed,
      sections: [
        if (p.manageUsers || p.inviteUsers)
          SettingsSection(
            id: SettingsSections.users,
            label: tr('Comptes'),
            builder: (_) => const UsersPage(),
          ),
        if (p.manageUsers)
          SettingsSection(
            id: SettingsSections.devices,
            label: tr('Appareils'),
            builder: (_) => const AdminDevicesPage(),
          ),
        if (p.manageSettings)
          SettingsSection(
            id: SettingsSections.announcement,
            label: tr('Message à tous'),
            builder: (_) => const AnnouncementPage(),
          ),
      ],
    ),
    SettingsCategory(
      id: SettingsSections.library,
      label: tr('Bibliothèque'),
      icon: Icons.video_library_rounded,
      hint: p.manageSettings
          ? tr('Dossiers, analyse, métadonnées')
          : tr('Analyse, maintenance'),
      admin: true,
      sections: [
        if (p.manageSettings || p.manageLibrary)
          SettingsSection(
            id: SettingsSections.library,
            label: tr('Bibliothèque'),
            builder: (_) => const LibraryPage(),
          ),
        if (p.manageSettings)
          SettingsSection(
            id: SettingsSections.integrations,
            label: tr('Métadonnées'),
            builder: (_) => const IntegrationsPage(),
          ),
      ],
    ),
    if (p.manageSettings)
      SettingsCategory(
        id: SettingsSections.linkedServers,
        label: tr('Serveurs liés'),
        icon: Icons.hub_rounded,
        hint: tr('Progression partagée entre serveurs'),
        admin: true,
        sections: [
          SettingsSection(
            id: SettingsSections.linkedServers,
            label: tr('Serveurs liés'),
            builder: (_) => const LinkedServersPage(),
          ),
        ],
      ),
  ];
  return [
    for (final category in categories)
      if (category.sections.isNotEmpty) category,
  ];
}
