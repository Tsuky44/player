import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../navigation/search_route_observer.dart';
import '../../providers/auth_provider.dart';
import '../../screens/player/player_screen.dart';
import '../../services/watch_party.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_deferred_keyboard.dart';

/// Demande le code d'une séance « Regarder ensemble », la rejoint sur le
/// serveur actif et ouvre le lecteur là où en sont les autres.
Future<void> showJoinWatchPartyDialog(
  BuildContext context, {
  required AuthProvider authProvider,
}) async {
  final session = await showDialog<WatchPartySession>(
    context: context,
    builder: (_) => _JoinWatchPartyDialog(authProvider: authProvider),
  );
  if (session == null || !context.mounted) return;

  final snapshot = session.snapshot;
  final media = snapshot.media;
  if (media == null) {
    // Le média de la séance n'est pas lisible sur ce compte : inutile d'y
    // rester, on ne pourrait rien y voir.
    await session.leave();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Ce média n’est pas disponible sur votre compte.'),
    ));
    return;
  }
  // Le lecteur se recale à sa première image : partir d'ici suffit.
  final position = snapshot.position;
  await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
    settings: const RouteSettings(name: SearchRouteObserver.playerRouteName),
    builder: (_) => PlayerScreen(
      media: media,
      resumeAtSeconds: position.inSeconds,
      startPaused: !snapshot.playing,
    ),
  ));
}

class _JoinWatchPartyDialog extends StatefulWidget {
  const _JoinWatchPartyDialog({required this.authProvider});

  final AuthProvider authProvider;

  @override
  State<_JoinWatchPartyDialog> createState() => _JoinWatchPartyDialogState();
}

class _JoinWatchPartyDialogState extends State<_JoinWatchPartyDialog> {
  final TextEditingController _code = TextEditingController();
  bool _joining = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = WatchPartySession.normalizeCode(_code.text);
    if (code.isEmpty) {
      setState(() => _error = 'Entrez le code affiché chez l’hôte.');
      return;
    }
    // Le même compte que celui sur lequel le lecteur s'ouvrira.
    final shared = widget.authProvider.apiClient;
    final accountId = shared.accountId;
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final api =
          accountId == null ? shared : await shared.pinToAccount(accountId);
      final session = await WatchPartySession.join(
        api: api,
        accountId: accountId ?? WatchPartySession.defaultAccountKey,
        code: code,
      );
      if (!mounted) {
        await session.leave();
        return;
      }
      Navigator.of(context).pop(session);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = switch (e.response?.statusCode) {
          404 => 'Aucune séance avec ce code sur ce serveur.',
          409 => 'Cette séance est complète.',
          _ => 'Impossible de rejoindre la séance. Réessayez.',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = 'Impossible de rejoindre la séance. Réessayez.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.authProvider.activeServer?.displayName;
    return AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: const Text('Rejoindre une séance'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              server == null
                  ? 'Entrez le code affiché dans le lecteur de l’hôte.'
                  : 'Entrez le code affiché dans le lecteur de l’hôte, sur '
                      '$server.',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            TvDeferredKeyboard(
              builder: (context, focusNode, canRequestFocus) => TextField(
                controller: _code,
                focusNode: focusNode,
                canRequestFocus: canRequestFocus,
                autofocus: true,
                enabled: !_joining,
                textCapitalization: TextCapitalization.characters,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 6,
                ),
                decoration: InputDecoration(
                  hintText: 'ABC123',
                  errorText: _error,
                ),
                onSubmitted: (_) => _join(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _joining ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _joining ? null : _join,
          child: _joining
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Rejoindre'),
        ),
      ],
    );
  }
}
