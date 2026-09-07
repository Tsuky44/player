import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../models/server_account.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import 'user_admin_sections.dart';

/// Les gens qui ont sonné à la porte de ce serveur.
///
/// C'est l'autre bout du mouvement décrit par ADR-0013 : l'invitation part
/// d'ici, la demande d'accès arrive ici. Accepter crée le compte et ouvre la
/// session du demandeur d'un seul geste — il n'a rien de plus à taper.
class AccessRequestsSection extends StatefulWidget {
  const AccessRequestsSection({super.key});

  @override
  State<AccessRequestsSection> createState() => _AccessRequestsSectionState();
}

class _AccessRequestsSectionState extends State<AccessRequestsSection> {
  List<AccessRequest> _requests = const [];
  bool _loading = true;
  String? _error;
  int? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final requests = await context.read<ApiClient>().getAccessRequests();
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _errorText(e);
      });
      // Les droits ont pu être retirés pendant que l'écran était ouvert.
      context.read<AuthProvider>().refreshProfile();
    }
  }

  Future<void> _approve(AccessRequest request, {Permissions? grants}) async {
    setState(() => _busyId = request.id);
    try {
      final user = await context
          .read<ApiClient>()
          .approveAccessRequest(request.id, permissions: grants);
      if (!mounted) return;
      _toast('${user.username} a maintenant un compte sur ce serveur.');
      setState(() => _busyId = null);
      _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      _toast(_errorText(e), error: true);
    }
  }

  /// Le choix fin des droits n'est proposé qu'aux titulaires de `manage_users`.
  /// Un simple inviteur accorde son gabarit quoi qu'il arrive — le serveur
  /// ignore ce qu'il enverrait —, donc lui montrer des cases serait mentir.
  Future<void> _approveWithGrants(AccessRequest request) async {
    final grants = await showModalBottomSheet<Permissions>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      builder: (_) => _GrantsSheet(username: request.username),
    );
    if (grants == null || !mounted) return;
    await _approve(request, grants: grants);
  }

  Future<void> _deny(AccessRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Refuser ${request.username} ?'),
        content: const Text(
          'La personne en sera informée à sa prochaine tentative. Aucun compte '
          'n’est créé.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Refuser'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyId = request.id);
    try {
      await context.read<ApiClient>().denyAccessRequest(request.id);
      if (!mounted) return;
      setState(() => _busyId = null);
      _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
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

  String _waitingFor(AccessRequest request) {
    final since = request.createdAt;
    if (since == null) return 'En attente';
    final elapsed = DateTime.now().difference(since);
    if (elapsed.inMinutes < 1) return 'À l’instant';
    if (elapsed.inHours < 1) return 'Il y a ${elapsed.inMinutes} min';
    if (elapsed.inDays < 1) return 'Il y a ${elapsed.inHours} h';
    return 'Il y a ${elapsed.inDays} j';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final canChooseGrants =
        context.watch<AuthProvider>().permissions.manageUsers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: AppColors.error)),
          const SizedBox(height: 12),
        ],
        if (_requests.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Aucune demande en attente.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        for (final request in _requests)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: AppColors.primary.withValues(alpha: 0.15),
              child: Text(request.username.isEmpty
                  ? '?'
                  : request.username.substring(0, 1).toUpperCase()),
            ),
            title: Text(request.username),
            subtitle: Text(
              [
                _waitingFor(request),
                if (request.deviceName.isNotEmpty) request.deviceName,
                if (request.message.isNotEmpty) '« ${request.message} »',
              ].join(' · '),
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            isThreeLine: request.message.isNotEmpty,
            trailing: _busyId == request.id
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Refuser',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => _deny(request),
                      ),
                      IconButton(
                        tooltip: 'Accepter',
                        icon: const Icon(Icons.check_rounded),
                        onPressed: () => _approve(request),
                      ),
                      if (canChooseGrants)
                        IconButton(
                          tooltip: 'Accepter avec des droits précis',
                          icon: const Icon(Icons.tune_rounded),
                          onPressed: () => _approveWithGrants(request),
                        ),
                    ],
                  ),
          ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Actualiser'),
          ),
        ),
      ],
    );
  }
}

/// Les droits accordés à la personne acceptée. Par défaut ceux d'un compte
/// ordinaire : demander des médias, rien d'autre.
class _GrantsSheet extends StatefulWidget {
  const _GrantsSheet({required this.username});

  final String username;

  @override
  State<_GrantsSheet> createState() => _GrantsSheetState();
}

class _GrantsSheetState extends State<_GrantsSheet> {
  Permissions _grants = const Permissions(requestMedia: true);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Droits de ${widget.username}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final entry in permissionLabels)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(entry.$2),
                value: readPermission(_grants, entry.$1),
                onChanged: (value) => setState(() {
                  _grants = writePermission(_grants, entry.$1, value ?? false);
                }),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_grants),
              child: const Text('Accepter'),
            ),
          ],
        ),
      ),
    );
  }
}

String _errorText(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
  }
  return 'Une erreur est survenue : $error';
}
