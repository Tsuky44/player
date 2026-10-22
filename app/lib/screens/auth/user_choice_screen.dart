import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/server_account.dart';
import '../../providers/auth_provider.dart';
import '../../services/server_registry.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/overlay_back_button.dart';
import '../../l10n/tr.dart';
import 'add_user_screen.dart';
import 'avatar_picker_screen.dart';
import 'widgets/profile_tile.dart';

/// « Qui regarde ? » : les personnes de cet appareil sur un serveur.
///
/// Au lancement ([atStartup]), aucune session n'est encore ouverte : le choix
/// décide de celle qui s'ouvre, pour que l'accueil de l'un ne se charge pas
/// sous les yeux de l'autre. Depuis le menu du compte, il bascule — sur le
/// serveur actif, ou sur [serverAccountId] quand on change de serveur et
/// qu'il y a plusieurs personnes à l'arrivée. Chaque compte a déjà son jeton :
/// rien à retaper. Voir ADR-0078.
class UserChoiceScreen extends StatefulWidget {
  const UserChoiceScreen({
    super.key,
    this.atStartup = false,
    this.serverAccountId,
  });

  final bool atStartup;

  /// Un compte du serveur à afficher ; le serveur actif quand il est nul.
  final String? serverAccountId;

  @override
  State<UserChoiceScreen> createState() => _UserChoiceScreenState();
}

class _UserChoiceScreenState extends State<UserChoiceScreen> {
  /// « Gérer les profils » : un appui change l'image au lieu d'ouvrir.
  bool _editing = false;

  /// Un compte de ce serveur, qui sert de repère pour lister ses personnes.
  ServerAccount? _anchor(AuthProvider auth) {
    final id = widget.serverAccountId;
    final registry = auth.apiClient.servers;
    return id == null ? auth.activeServer : registry.accountById(id);
  }

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

  Future<void> _editAvatar(ServerAccount account) async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => AvatarPickerScreen(account: account),
    ));
  }

  /// Ajoute quelqu'un sur ce serveur, puis passe sur son compte : c'est pour
  /// lui qu'on vient d'ouvrir la session.
  Future<void> _addUser(ServerAccount server) async {
    final auth = context.read<AuthProvider>();
    final before = auth.activeServer?.id;
    final added = await Navigator.of(context).push<ServerAccount>(
      MaterialPageRoute(builder: (_) => AddUserScreen(server: server)),
    );
    // Au lancement, une session ouverte par l'ajout a déjà remplacé cet écran.
    if (!mounted) return;
    if (widget.atStartup) {
      if (added != null) await auth.chooseUser(added.id);
      return;
    }
    // Le téléphone ouvre la session et la rend active ; le mot de passe
    // l'ajoute sans basculer, pour ne pas déplacer un écran qu'on regarde.
    final switched = auth.activeServer?.id != before;
    if (!switched && (added == null || !await auth.switchServer(added.id))) {
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final anchor = _anchor(auth);
    final users = anchor == null
        ? const <ServerAccount>[]
        : auth.apiClient.servers.usersOf(anchor.id);
    final active = auth.activeServer;
    final compact = AppLayout.isCompact(context);
    final busy = auth.isLoading;
    final size = compact ? 92.0 : 128.0;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _editing ? tr('Gérer les profils') : tr('Qui regarde ?'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: compact ? AppType.title1 : AppType.largeTitle,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (anchor != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        anchor.displayName,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppType.body,
                        ),
                      ),
                    ],
                    SizedBox(height: compact ? 32 : 48),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: compact ? 16 : 32,
                      runSpacing: compact ? 20 : 32,
                      children: [
                        for (final (index, account) in users.indexed)
                          ProfileTile(
                            account: account,
                            size: size,
                            current:
                                !widget.atStartup && account.id == active?.id,
                            editing: _editing,
                            // Le premier au lancement, la personne en cours
                            // depuis le menu : au D-pad, on part de là.
                            autofocus: _autofocus(index, account, active),
                            enabled: !busy,
                            onSelect: () => _choose(account),
                            onEdit: () => _editAvatar(account),
                          ),
                        if (anchor != null && !_editing)
                          AddProfileTile(
                            size: size,
                            enabled: !busy,
                            onSelect: () => _addUser(anchor),
                          ),
                      ],
                    ),
                    SizedBox(height: compact ? 36 : 56),
                    _editing
                        ? FilledButton(
                            onPressed: () => setState(() => _editing = false),
                            child: Text(tr('Terminé')),
                          )
                        : OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => setState(() => _editing = true),
                            child: Text(tr('Gérer les profils')),
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

  bool _autofocus(int index, ServerAccount account, ServerAccount? active) {
    final onActiveServer =
        active != null && ServerRegistry.sameServer(account, active);
    if (widget.atStartup || !onActiveServer) return index == 0;
    return account.id == active.id;
  }
}
