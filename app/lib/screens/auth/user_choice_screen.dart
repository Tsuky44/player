import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/server_account.dart';
import '../../providers/auth_provider.dart';
import '../../services/tv_link_host.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_focus.dart';
import '../../tv/tv_mode.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/overlay_back_button.dart';
import '../../l10n/tr.dart';
import '../settings/servers_screen.dart';
import 'tv_login_screen.dart';

/// « Qui regarde ? » : les personnes de cet appareil sur le serveur actif.
///
/// Au lancement ([atStartup]), aucune session n'est encore ouverte : le choix
/// décide de celle qui s'ouvre, pour que l'accueil de l'un ne se charge pas
/// sous les yeux de l'autre. Depuis le menu du compte, il bascule. Dans les
/// deux cas, chaque compte a déjà son jeton : rien à retaper. Voir ADR-0078.
class UserChoiceScreen extends StatefulWidget {
  const UserChoiceScreen({super.key, this.atStartup = false});

  final bool atStartup;

  @override
  State<UserChoiceScreen> createState() => _UserChoiceScreenState();
}

class _UserChoiceScreenState extends State<UserChoiceScreen> {
  Future<void> _choose(ServerAccount account) async {
    final auth = context.read<AuthProvider>();
    if (widget.atStartup) {
      await auth.chooseUser(account.id);
      return;
    }
    final ok = await auth.switchServer(account.id);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(auth.errorMessage ?? tr('Bascule impossible.')),
      backgroundColor: AppColors.error,
    ));
  }

  /// Ajoute quelqu'un sur ce serveur, puis passe sur son compte : c'est pour
  /// lui qu'on vient d'ouvrir la session.
  ///
  /// Sur une télévision, c'est son téléphone qui la lui ouvre (ADR-0003) ;
  /// ailleurs, son mot de passe, l'adresse étant déjà remplie.
  Future<void> _addUser() async {
    final auth = context.read<AuthProvider>();
    final server = auth.activeServer;
    final known = {for (final account in auth.servers) account.id};
    final byPhone = TvScope.of(context) && TvLinkHost.isSupported;

    await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => byPhone
          ? const TvLoginScreen(addingUser: true)
          : AddServerScreen(initialUrl: server?.url, signIn: true),
    ));
    if (!mounted) return;

    // Au lancement, une session ouverte par l'ajout a déjà remplacé cet écran.
    final added = auth.usersOnActiveServer
        .where((account) => !known.contains(account.id))
        .firstOrNull;
    if (widget.atStartup) {
      if (added != null) await auth.chooseUser(added.id);
      return;
    }
    // Le téléphone ouvre la session et la rend active ; le mot de passe
    // l'ajoute sans basculer, pour ne pas déplacer un écran qu'on regarde.
    final switched = auth.activeServer?.id != server?.id;
    if (!switched && (added == null || !await auth.switchServer(added.id))) {
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final users = auth.usersOnActiveServer;
    final activeId = auth.activeServer?.id;
    final compact = AppLayout.isCompact(context);
    final busy = auth.isLoading;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('Qui regarde ?'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: compact ? AppType.title1 : AppType.largeTitle,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (auth.activeServer != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        auth.activeServer!.displayName,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppType.body,
                        ),
                      ),
                    ],
                    SizedBox(height: compact ? 28 : 40),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: compact ? 16 : 28,
                      runSpacing: compact ? 20 : 28,
                      children: [
                        for (final (index, account) in users.indexed)
                          _ProfileTile(
                            name: account.username,
                            tint: _tintFor(account),
                            current: !widget.atStartup && account.id == activeId,
                            // Le premier au lancement, la personne en cours
                            // depuis le menu : au D-pad, on part de là.
                            autofocus: widget.atStartup
                                ? index == 0
                                : account.id == activeId,
                            compact: compact,
                            enabled: !busy,
                            onSelect: () => _choose(account),
                          ),
                        _AddProfileTile(
                          compact: compact,
                          enabled: !busy,
                          onSelect: _addUser,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (!widget.atStartup)
              const Positioned(top: 0, left: 0, child: OverlayBackButton()),
          ],
        ),
      ),
    );
  }
}

/// Une teinte stable par compte : la même personne garde sa couleur d'un
/// lancement à l'autre, quel que soit l'ordre du carnet.
Color _tintFor(ServerAccount account) {
  final seed = account.id.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
  return AppColors.profileTints[seed % AppColors.profileTints.length];
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.name,
    required this.tint,
    required this.current,
    required this.autofocus,
    required this.compact,
    required this.enabled,
    required this.onSelect,
  });

  final String name;
  final Color tint;
  final bool current;
  final bool autofocus;
  final bool compact;
  final bool enabled;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return _TileFrame(
      label: tr('Regarder en tant que {0}', [name]),
      caption: name,
      note: current ? tr('En cours') : null,
      autofocus: autofocus,
      compact: compact,
      enabled: enabled,
      onSelect: onSelect,
      disc: DecoratedBox(
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(compact ? 18 : 22),
          border: current
              ? Border.all(color: AppColors.textPrimary, width: 2)
              : null,
        ),
        child: Center(
          child: Text(
            initial,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: compact ? AppType.largeTitle : AppType.hero,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _AddProfileTile extends StatelessWidget {
  const _AddProfileTile({
    required this.compact,
    required this.enabled,
    required this.onSelect,
  });

  final bool compact;
  final bool enabled;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return _TileFrame(
      label: tr('Ajouter un utilisateur'),
      caption: tr('Ajouter'),
      autofocus: false,
      compact: compact,
      enabled: enabled,
      onSelect: onSelect,
      disc: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(compact ? 18 : 22),
          border: Border.all(color: AppColors.border),
        ),
        child: Center(
          child: Icon(
            AppIcons.add,
            size: compact ? 32 : 40,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Ce que partagent une personne et « Ajouter » : la pastille, le nom dessous,
/// la cible du D-pad et le libellé lu par les lecteurs d'écran.
class _TileFrame extends StatelessWidget {
  const _TileFrame({
    required this.label,
    required this.caption,
    required this.disc,
    required this.autofocus,
    required this.compact,
    required this.enabled,
    required this.onSelect,
    this.note,
  });

  final String label;
  final String caption;
  final String? note;
  final Widget disc;
  final bool autofocus;
  final bool compact;
  final bool enabled;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 92.0 : 120.0;
    final radius = BorderRadius.circular(compact ? 18 : 22);
    return SizedBox(
      width: size + 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: label,
            onTap: enabled ? onSelect : null,
            excludeSemantics: true,
            child: TvFocusable(
              autofocus: autofocus,
              enabled: enabled,
              onSelect: onSelect,
              borderRadius: radius,
              child: Material(
                color: Colors.transparent,
                borderRadius: radius,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: enabled ? onSelect : null,
                  child: SizedBox.square(dimension: size, child: disc),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: AppType.callout,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (note != null)
            Text(
              note!,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: AppType.footnote,
              ),
            ),
        ],
      ),
    );
  }
}
