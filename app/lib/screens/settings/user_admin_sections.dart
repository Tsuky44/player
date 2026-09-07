import 'package:dio/dio.dart';
import '../../tv/tv_deferred_keyboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';

/// Human labels for the six administration rights, in the order they are shown.
const permissionLabels = <(String, String)>[
  ('manage_settings', 'Gérer les paramètres du serveur'),
  ('manage_library', 'Gérer la bibliothèque (scans, métadonnées)'),
  ('manage_users', 'Gérer les utilisateurs'),
  ('delete_media', 'Supprimer des médias'),
  ('invite_users', 'Créer des invitations'),
  ('request_media', 'Demander des médias'),
];

bool readPermission(Permissions p, String key) => p.toJson()[key] == true;

Permissions writePermission(Permissions p, String key, bool value) {
  switch (key) {
    case 'manage_settings':
      return p.copyWith(manageSettings: value);
    case 'manage_library':
      return p.copyWith(manageLibrary: value);
    case 'manage_users':
      return p.copyWith(manageUsers: value);
    case 'delete_media':
      return p.copyWith(deleteMedia: value);
    case 'invite_users':
      return p.copyWith(inviteUsers: value);
    case 'request_media':
      return p.copyWith(requestMedia: value);
  }
  return p;
}

String _summary(Permissions p) {
  if (p.isAdmin) return 'Administrateur';
  final granted = permissionLabels
      .where((entry) => readPermission(p, entry.$1))
      .map((entry) => entry.$2)
      .toList();
  if (granted.isEmpty) return 'Aucun droit';
  if (granted.length <= 2) return granted.join(' · ');
  return '${granted.length} droits';
}

/// Accounts list with their rights. Only rendered for holders of manage_users.
class UsersSection extends StatefulWidget {
  const UsersSection({super.key});

  @override
  State<UsersSection> createState() => _UsersSectionState();
}

class _UsersSectionState extends State<UsersSection> {
  List<User> _users = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await context.read<ApiClient>().getUsers();
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _errorText(e);
      });
      // Rights may have been taken away while this screen was open.
      context.read<AuthProvider>().refreshProfile();
    }
  }

  Future<void> _editPermissions(User user) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      builder: (_) => _PermissionsSheet(user: user),
    );
    if (saved == true) _load();
  }

  Future<void> _resetPassword(User user) async {
    final password = await _promptPassword(
      context,
      title: 'Réinitialiser le mot de passe de ${user.username}',
      // Reset is a recovery, so it logs that account out everywhere.
      hint: 'Les sessions ouvertes de ce compte seront fermées.',
    );
    if (password == null || !mounted) return;
    try {
      await context.read<ApiClient>().resetUserPassword(user.id, password);
      if (!mounted) return;
      _toast('Mot de passe réinitialisé.');
    } catch (e) {
      _toast(_errorText(e), error: true);
    }
  }

  Future<void> _delete(User user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Supprimer ${user.username} ?'),
        content: const Text(
          'Le compte et toutes ses données (progressions, playeurs, sessions) '
          'seront supprimés définitivement.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<ApiClient>().deleteUser(user.id);
      _load();
    } catch (e) {
      _toast(_errorText(e), error: true);
    }
  }

  Future<void> _transferOwnership(User user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Transférer la propriété à ${user.username} ?'),
        content: const Text(
          'Vous ne serez plus propriétaire : ce compte pourra alors modifier '
          'vos droits, et vous ne pourrez plus modifier les siens.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Transférer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<ApiClient>().transferOwnership(user.id);
      if (!mounted) return;
      await context.read<AuthProvider>().refreshProfile();
      _load();
    } catch (e) {
      _toast(_errorText(e), error: true);
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.error : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Text(_error!, style: const TextStyle(color: AppColors.error));
    }

    final auth = context.watch<AuthProvider>();
    final me = auth.currentUser;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final user in _users)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: AppColors.primary.withValues(alpha: 0.15),
              child: Text(user.username.isEmpty
                  ? '?'
                  : user.username.substring(0, 1).toUpperCase()),
            ),
            title: Row(
              children: [
                Flexible(child: Text(user.username)),
                if (user.isOwner) ...[
                  const SizedBox(width: 8),
                  const _Chip(label: 'Propriétaire'),
                ],
                if (user.id == me?.id) ...[
                  const SizedBox(width: 8),
                  const _Chip(label: 'Vous'),
                ],
              ],
            ),
            subtitle: Text(
              _summary(user.permissions),
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'permissions':
                    _editPermissions(user);
                  case 'password':
                    _resetPassword(user);
                  case 'delete':
                    _delete(user);
                  case 'transfer':
                    _transferOwnership(user);
                }
              },
              itemBuilder: (_) => [
                // The owner is asymmetric: only the owner touches the owner.
                if (!user.isOwner || auth.isOwner)
                  const PopupMenuItem(
                    value: 'permissions',
                    child: Text('Modifier les droits'),
                  ),
                if (!user.isOwner || auth.isOwner)
                  const PopupMenuItem(
                    value: 'password',
                    child: Text('Réinitialiser le mot de passe'),
                  ),
                if (auth.isOwner && !user.isOwner)
                  const PopupMenuItem(
                    value: 'transfer',
                    child: Text('Transférer la propriété'),
                  ),
                if (!user.isOwner && user.id != me?.id)
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Supprimer le compte'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Editor for one account's rights, plus the invitation template that goes with
/// `invite_users`.
class _PermissionsSheet extends StatefulWidget {
  const _PermissionsSheet({required this.user});

  final User user;

  @override
  State<_PermissionsSheet> createState() => _PermissionsSheetState();
}

class _PermissionsSheetState extends State<_PermissionsSheet> {
  late Permissions _permissions = widget.user.permissions;
  late Permissions _inviteGrants = widget.user.inviteGrants;
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<ApiClient>().updateUserPermissions(
            widget.user.id,
            _permissions,
            inviteGrants: _inviteGrants,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Droits de ${widget.user.username}',
                  style: textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Le raccourci « Administrateur » coche tout.',
                style: textTheme.bodySmall
                    ?.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Administrateur'),
                value: _permissions.isAdmin,
                onChanged: (value) => setState(() {
                  _permissions = value
                      ? Permissions.all
                      : const Permissions(requestMedia: true);
                  if (!value) _inviteGrants = const Permissions();
                }),
              ),
              const Divider(),
              for (final entry in permissionLabels)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(entry.$2),
                  value: readPermission(_permissions, entry.$1),
                  onChanged: (value) => setState(() {
                    _permissions =
                        writePermission(_permissions, entry.$1, value ?? false);
                    if (entry.$1 == 'invite_users' && value != true) {
                      _inviteGrants = const Permissions();
                    }
                  }),
                ),
              if (_permissions.inviteUsers) ...[
                const SizedBox(height: 12),
                Text('Droits accordés par ses invitations',
                    style: textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'C’est vous qui décidez ce que ses liens accordent : la '
                  'personne qui invite ne choisit rien, elle ne peut donc pas '
                  'se fabriquer un compte administrateur.',
                  style: textTheme.bodySmall
                      ?.copyWith(color: AppColors.textSecondary),
                ),
                for (final entry in permissionLabels)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(entry.$2),
                    // An invitation that hands out manage_users would turn the
                    // right to invite into the right to do everything.
                    enabled: entry.$1 != 'manage_users',
                    value: entry.$1 == 'manage_users'
                        ? false
                        : readPermission(_inviteGrants, entry.$1),
                    onChanged: entry.$1 == 'manage_users'
                        ? null
                        : (value) => setState(() {
                              _inviteGrants = writePermission(
                                  _inviteGrants, entry.$1, value ?? false);
                            }),
                  ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.error)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Invitation links. Visible to anyone holding invite_users; an administrator
/// sees every link, an inviter sees only their own.
class InvitationsSection extends StatefulWidget {
  const InvitationsSection({super.key});

  @override
  State<InvitationsSection> createState() => _InvitationsSectionState();
}

class _InvitationsSectionState extends State<InvitationsSection> {
  List<Invitation> _invitations = const [];
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final invitations = await context.read<ApiClient>().getInvitations();
      if (!mounted) return;
      setState(() {
        _invitations = invitations;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _errorText(e);
      });
      context.read<AuthProvider>().refreshProfile();
    }
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    try {
      final invitation = await context.read<ApiClient>().createInvitation();
      if (!mounted) return;
      setState(() => _creating = false);
      _showLink(invitation);
      _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      _toast(_errorText(e), error: true);
    }
  }

  /// Shows the link and the raw code together. The link is built from the
  /// address this client uses, which may be LAN-only; the code always works,
  /// and on the native apps it is the only way in.
  void _showLink(Invitation invitation) {
    final link = context.read<ApiClient>().invitationLink(invitation);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Invitation créée'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Lien (navigateur, même réseau que cette adresse) :'),
            const SizedBox(height: 4),
            SelectableText(link, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 16),
            const Text('Code (à saisir dans l’app) :'),
            const SizedBox(height: 4),
            SelectableText(invitation.token,
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 16),
            const Text(
              'Valable 7 jours, utilisable une seule fois.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: invitation.token));
              Navigator.of(ctx).pop();
              _toast('Code copié.');
            },
            child: const Text('Copier le code'),
          ),
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              Navigator.of(ctx).pop();
              _toast('Lien copié.');
            },
            child: const Text('Copier le lien'),
          ),
        ],
      ),
    );
  }

  Future<void> _revoke(Invitation invitation) async {
    try {
      await context.read<ApiClient>().revokeInvitation(invitation.token);
      _load();
    } catch (e) {
      _toast(_errorText(e), error: true);
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.error : null,
    ));
  }

  String _statusLabel(Invitation invitation) {
    switch (invitation.status) {
      case 'used':
        return invitation.usedBy.isEmpty
            ? 'Utilisée'
            : 'Utilisée par ${invitation.usedBy}';
      case 'revoked':
        return 'Révoquée';
      case 'expired':
        return 'Expirée';
      default:
        final expires = invitation.expiresAt;
        if (expires == null) return 'En attente';
        final days = expires.difference(DateTime.now()).inDays;
        return days <= 0 ? 'Expire aujourd’hui' : 'Expire dans $days j';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final isAdmin = context.watch<AuthProvider>().permissions.manageUsers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: AppColors.error)),
          const SizedBox(height: 12),
        ],
        if (_invitations.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Aucune invitation pour le moment.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        for (final invitation in _invitations)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              invitation.token.length >= 8
                  ? invitation.token.substring(0, 8).toUpperCase()
                  : invitation.token.toUpperCase(),
            ),
            subtitle: Text(
              isAdmin
                  ? '${_statusLabel(invitation)} · créée par ${invitation.inviter}'
                  : _statusLabel(invitation),
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            trailing: invitation.isPending
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Revoir le lien',
                        icon: const Icon(Icons.link_rounded),
                        onPressed: () => _showLink(invitation),
                      ),
                      IconButton(
                        tooltip: 'Révoquer',
                        icon: const Icon(Icons.block_rounded),
                        onPressed: () => _revoke(invitation),
                      ),
                    ],
                  )
                : null,
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: _creating ? null : _create,
            child: Text(_creating ? 'Création…' : 'Générer une invitation'),
          ),
        ),
      ],
    );
  }
}

/// Small "Propriétaire" / "Vous" badge.
class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
    );
  }
}

/// Password prompt shared by the admin reset and the self-service change.
Future<String?> promptPassword(
  BuildContext context, {
  required String title,
  String? hint,
  String label = 'Nouveau mot de passe',
}) =>
    _promptPassword(context, title: title, hint: hint, label: label);

Future<String?> _promptPassword(BuildContext context,
    {required String title,
    String? hint,
    String label = 'Nouveau mot de passe'}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hint != null) ...[
            Text(hint,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 12),
          ],
          TvDeferredKeyboard(
            builder: (context, focusNode, canRequestFocus) => TextField(
              focusNode: focusNode,
              canRequestFocus: canRequestFocus,
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(labelText: label),
                      ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () {
            final value = controller.text;
            if (value.length < 4) return;
            Navigator.of(ctx).pop(value);
          },
          child: const Text('Valider'),
        ),
      ],
    ),
  );
}

/// Surfaces the server's own message — notably "Droits insuffisants" — rather
/// than a generic failure.
String _errorText(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
  }
  return 'Action impossible.';
}
