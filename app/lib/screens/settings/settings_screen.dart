import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../services/client_identity.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import '../../utils/app_platform.dart';
import 'pages/account_page.dart';
import 'pages/activity_page.dart';
import 'pages/admin_devices_page.dart';
import 'pages/apps_page.dart';
import 'pages/dashboard_page.dart';
import 'pages/device_page.dart';
import 'pages/downloads_page.dart';
import 'pages/emby_sync_page.dart';
import 'pages/integrations_page.dart';
import 'pages/library_page.dart';
import 'pages/linked_servers_page.dart';
import 'pages/logs_page.dart';
import 'pages/playback_page.dart';
import 'pages/servers_page.dart';
import 'pages/stats_page.dart';
import 'pages/users_page.dart';
import 'widgets/settings_ui.dart';

/// Les catégories des paramètres, dans l'ordre de la navigation.
abstract final class SettingsSections {
  static const account = 'account';
  static const playback = 'playback';
  static const downloads = 'downloads';
  static const servers = 'servers';
  static const emby = 'emby';
  static const device = 'device';
  static const apps = 'apps';
  static const dashboard = 'dashboard';
  static const activity = 'activity';
  static const stats = 'stats';
  static const users = 'users';
  static const devices = 'devices';
  static const library = 'library';
  static const integrations = 'integrations';
  static const linkedServers = 'linked-servers';
  static const logs = 'logs';
}

class _Category {
  const _Category({
    required this.id,
    required this.label,
    required this.icon,
    required this.hint,
    required this.admin,
    required this.builder,
  });

  final String id;
  final String label;
  final IconData icon;

  /// La ligne sous le libellé dans la liste mobile.
  final String hint;
  final bool admin;
  final WidgetBuilder builder;
}

/// Ce qu'un compte voit dépend de ses droits : une catégorie qu'il ne peut pas
/// utiliser n'est pas grisée, elle est absente. Ce qui n'est pas dessiné ne
/// produit pas de 403.
List<_Category> _categoriesFor(Permissions p) {
  final anyAdmin = p.manageSettings || p.manageLibrary || p.manageUsers;
  return [
    _Category(
      id: SettingsSections.account,
      label: 'Mon compte',
      icon: Icons.person_rounded,
      hint: 'Profil, mot de passe, appareils connectés',
      admin: false,
      builder: (_) => const AccountPage(),
    ),
    _Category(
      id: SettingsSections.playback,
      label: 'Lecture',
      icon: Icons.play_circle_outline_rounded,
      hint: 'Langue audio, décodage, interface du lecteur',
      admin: false,
      builder: (_) => const PlaybackPage(),
    ),
    // Un navigateur n'a pas de dossier privé où garder un film : la catégorie
    // n'aurait que des réglages sans effet à proposer.
    if (!AppPlatform.isWeb)
      _Category(
        id: SettingsSections.downloads,
        label: 'Téléchargements',
        icon: Icons.download_rounded,
        hint: 'Épisodes d’avance, réseau autorisé, place occupée',
        admin: false,
        builder: (_) => const DownloadsPage(),
      ),
    _Category(
      id: SettingsSections.servers,
      label: 'Serveurs',
      icon: Icons.dns_rounded,
      hint: 'Serveur actif, comptes et comptes liés',
      admin: false,
      builder: (_) => const ServersPage(),
    ),
    _Category(
      id: SettingsSections.emby,
      label: 'Synchro Emby',
      icon: Icons.sync_rounded,
      hint: 'Reprendre là où vous en êtes sur Emby',
      admin: false,
      builder: (_) => const EmbySyncPage(),
    ),
    _Category(
      id: SettingsSections.device,
      label: 'Cet appareil',
      icon: Icons.devices_rounded,
      hint: 'Mode télécommande, téléviseur, stockage',
      admin: false,
      builder: (_) => const DevicePage(),
    ),
    _Category(
      id: SettingsSections.apps,
      label: 'Applications',
      icon: Icons.download_for_offline_rounded,
      hint: 'Installer Onyx sur un autre appareil',
      admin: false,
      builder: (_) => const AppsPage(),
    ),
    _Category(
      id: SettingsSections.logs,
      label: 'Journal',
      icon: Icons.receipt_long_rounded,
      hint: 'Journaux de l’app et des lectures, pour comprendre une erreur',
      admin: false,
      builder: (_) => const LogsPage(),
    ),
    if (anyAdmin)
      _Category(
        id: SettingsSections.dashboard,
        label: 'Tableau de bord',
        icon: Icons.space_dashboard_rounded,
        hint: 'Lectures en cours, état du serveur',
        admin: true,
        builder: (_) => const DashboardPage(),
      ),
    if (p.manageUsers)
      _Category(
        id: SettingsSections.activity,
        label: 'Historique',
        icon: Icons.history_rounded,
        hint: 'Qui a regardé quoi, et où',
        admin: true,
        builder: (_) => const ActivityPage(),
      ),
    if (p.manageUsers)
      _Category(
        id: SettingsSections.stats,
        label: 'Statistiques',
        icon: Icons.insights_rounded,
        hint: 'Temps de visionnage, tops, applications',
        admin: true,
        builder: (_) => const StatsPage(),
      ),
    if (p.manageUsers || p.inviteUsers)
      _Category(
        id: SettingsSections.users,
        label: 'Utilisateurs',
        icon: Icons.group_rounded,
        hint: 'Comptes, droits, invitations, demandes',
        admin: true,
        builder: (_) => const UsersPage(),
      ),
    if (p.manageUsers)
      _Category(
        id: SettingsSections.devices,
        label: 'Appareils',
        icon: Icons.important_devices_rounded,
        hint: 'Toutes les sessions ouvertes sur le serveur',
        admin: true,
        builder: (_) => const AdminDevicesPage(),
      ),
    if (p.manageSettings || p.manageLibrary)
      _Category(
        id: SettingsSections.library,
        label: 'Bibliothèque',
        icon: Icons.video_library_rounded,
        hint: 'Dossiers, analyse, maintenance',
        admin: true,
        builder: (_) => const LibraryPage(),
      ),
    if (p.manageSettings)
      _Category(
        id: SettingsSections.integrations,
        label: 'Métadonnées',
        icon: Icons.extension_rounded,
        hint: 'TMDB et MediaHub',
        admin: true,
        builder: (_) => const IntegrationsPage(),
      ),
    if (p.manageSettings)
      _Category(
        id: SettingsSections.linkedServers,
        label: 'Serveurs liés',
        icon: Icons.hub_rounded,
        hint: 'Progression partagée entre serveurs',
        admin: true,
        builder: (_) => const LinkedServersPage(),
      ),
  ];
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialSection});

  /// La catégorie ouverte d'emblée (une entrée du menu du compte, par exemple).
  final String? initialSection;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _wideBreakpoint = 840.0;

  late String _selected = widget.initialSection ?? SettingsSections.account;
  bool _pushedInitial = false;

  void _open(BuildContext context, List<_Category> categories, String id,
      {required bool wide}) {
    final category = categories.where((c) => c.id == id).firstOrNull;
    if (category == null) return;
    if (wide) {
      setState(() => _selected = id);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SectionRoute(
        category: category,
        openSection: (next) => _open(context, categories, next, wide: false),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final categories = _categoriesFor(auth.permissions);

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= _wideBreakpoint;
      if (!categories.any((c) => c.id == _selected)) {
        _selected = categories.first.id;
      }

      if (!wide && widget.initialSection != null && !_pushedInitial) {
        _pushedInitial = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _open(context, categories, widget.initialSection!, wide: false);
          }
        });
      }

      return wide
          ? _WideSettings(
              categories: categories,
              selected: _selected,
              onSelect: (id) => _open(context, categories, id, wide: true),
            )
          : _CompactSettings(
              categories: categories,
              onSelect: (id) => _open(context, categories, id, wide: false),
            );
    });
  }
}

class _WideSettings extends StatelessWidget {
  const _WideSettings({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<_Category> categories;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final category = categories.firstWhere((c) => c.id == selected);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Sidebar(
              categories: categories,
              selected: selected,
              onSelect: onSelect,
            ),
            Expanded(
              child: DecoratedBox(
                decoration: const BoxDecoration(color: AppColors.background),
                child: SettingsLayout(
                  isWide: true,
                  openSection: onSelect,
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.012),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(category.id),
                      child: category.builder(context),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<_Category> categories;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final user = categories.where((c) => !c.admin).toList();
    final admin = categories.where((c) => c.admin).toList();
    final isTv = TvScope.of(context);

    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: const Color(0xFF0E0E0F),
        border: Border(
          right: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 24, 16, 12),
            child: Row(
              children: [
                if (Navigator.of(context).canPop())
                  IconButton(
                    tooltip: 'Retour',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                const SizedBox(width: 4),
                const Text(
                  'Paramètres',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 8, 14, 10),
            child: _AccountCard(compact: true),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
              children: [
                const _NavHeader('Mon espace'),
                for (final c in user)
                  _NavItem(
                    category: c,
                    selected: c.id == selected,
                    autofocus: isTv && c.id == selected,
                    onTap: () => onSelect(c.id),
                  ),
                if (admin.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const _NavHeader('Administration'),
                  for (final c in admin)
                    _NavItem(
                      category: c,
                      selected: c.id == selected,
                      autofocus: isTv && c.id == selected,
                      onTap: () => onSelect(c.id),
                    ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 16),
            child: Text(
              'Onyx ${ClientIdentity.version} · ${ClientIdentity.platform}',
              style:
                  const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavHeader extends StatelessWidget {
  const _NavHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 12, 8),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.category,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  final _Category category;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final background = selected
        ? Colors.white.withValues(alpha: 0.08)
        : _hovered || _focused
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onTap,
          onHover: (value) => setState(() => _hovered = value),
          onFocusChange: (value) {
            setState(() => _focused = value);
            // À la télécommande, parcourir la liste ouvre ce qu'on survole,
            // comme les réglages d'un téléviseur.
            if (value && TvScope.of(context) && !selected) widget.onTap();
          },
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _focused
                    ? AppColors.primary.withValues(alpha: 0.8)
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: Icon(
                    widget.category.icon,
                    size: 20,
                    color: selected
                        ? AppColors.accentMuted
                        : AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.category.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Qui est connecté, et à quel serveur.
class _AccountCard extends StatelessWidget {
  const _AccountCard({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.currentUser;
    final name = user?.username ?? '';
    final role = auth.isOwner
        ? 'Propriétaire'
        : auth.permissions.isAdmin
            ? 'Administrateur'
            : 'Membre';
    final server = auth.activeServer?.displayName ?? '';

    return Container(
      padding: EdgeInsets.all(compact ? 12 : 16),
      decoration: BoxDecoration(
        color: compact ? Colors.transparent : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          UserAvatar(name, size: compact ? 38 : 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: compact ? 14.5 : 17,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  server.isEmpty ? role : '$role · $server',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactSettings extends StatelessWidget {
  const _CompactSettings({required this.categories, required this.onSelect});

  final List<_Category> categories;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final user = categories.where((c) => !c.admin).toList();
    final admin = categories.where((c) => c.admin).toList();

    SettingsTile tile(_Category c) => SettingsTile(
          icon: c.icon,
          title: c.label,
          subtitle: c.hint,
          onTap: () => onSelect(c.id),
        );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Paramètres')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          const _AccountCard(),
          const SizedBox(height: 24),
          SettingsGroup(
            title: 'Mon espace',
            children: [for (final c in user) tile(c)],
          ),
          if (admin.isNotEmpty)
            SettingsGroup(
              title: 'Administration',
              children: [for (final c in admin) tile(c)],
            ),
          Center(
            child: Text(
              'Onyx ${ClientIdentity.version} · ${ClientIdentity.platform}',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionRoute extends StatelessWidget {
  const _SectionRoute({required this.category, required this.openSection});

  final _Category category;
  final ValueChanged<String> openSection;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(category.label)),
      body: SettingsLayout(
        isWide: false,
        openSection: openSection,
        child: category.builder(context),
      ),
    );
  }
}
