import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/server_account.dart';
import '../../services/api_client.dart';
import '../../services/media_details_cache.dart';
import '../../services/media_tracks_cache.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_deferred_keyboard.dart';
import 'shared_link_app.dart';
import 'shared_link_screen.dart';

/// Un lien de partage tel que l'app installée le lit : le serveur qui l'a
/// créé, et son code (ADR-0037 §9).
///
/// Sur le web la page vient déjà de ce serveur ; l'app installée, elle, n'en
/// connaît aucun, et le lien collé est le seul à dire où il mène.
class SharedLinkAddress {
  const SharedLinkAddress({required this.origin, required this.code});

  final String origin;
  final String code;

  /// Lit `https://serveur/share#code`, ou nul si [raw] n'est pas un lien de
  /// partage entier. Un message qui entoure le lien est toléré : c'est ainsi
  /// qu'il arrive, copié d'une conversation.
  static SharedLinkAddress? tryParse(String raw) {
    final match = RegExp(r'https?://\S+').firstMatch(raw);
    final uri = match == null ? null : Uri.tryParse(match.group(0)!);
    if (uri == null || uri.host.isEmpty) return null;
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.endsWith('/share')) return null;
    final code = parseSharedLinkCode(uri.replace(path: '/share'));
    if (code == null || code.isEmpty) return null;
    // Un serveur derrière un préfixe (/onyx/share) garde ce préfixe.
    final prefix = path.substring(0, path.length - '/share'.length);
    return SharedLinkAddress(
      origin: ServerAccount.normalizeUrl('${uri.origin}$prefix'),
      code: code,
    );
  }
}

/// Demande un lien de partage et l'ouvre en invité, sans compte ni serveur
/// enregistré (ADR-0037 §9).
Future<void> showOpenSharedLinkDialog(BuildContext context) async {
  final address = await showDialog<SharedLinkAddress>(
    context: context,
    builder: (_) => const _OpenSharedLinkDialog(),
  );
  if (address == null || !context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(
    builder: (_) => SharedLinkGuestScope(
      api: SharedLinkApiClient(address.code, origin: address.origin),
    ),
  ));
}

class _OpenSharedLinkDialog extends StatefulWidget {
  const _OpenSharedLinkDialog();

  @override
  State<_OpenSharedLinkDialog> createState() => _OpenSharedLinkDialogState();
}

class _OpenSharedLinkDialogState extends State<_OpenSharedLinkDialog> {
  final TextEditingController _link = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefillFromClipboard();
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  /// Le lien vient d'être copié dans une conversation : s'il est encore dans
  /// le presse-papiers, il n'y a plus qu'à valider.
  Future<void> _prefillFromClipboard() async {
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      if (!mounted || _link.text.isNotEmpty) return;
      final match = RegExp(r'https?://\S+').firstMatch(text)?.group(0);
      if (match != null && SharedLinkAddress.tryParse(match) != null) {
        _link.text = match;
      }
    } catch (_) {
      // Presse-papiers refusé ou vide : le champ reste à remplir à la main.
    }
  }

  void _open() {
    final address = SharedLinkAddress.tryParse(_link.text);
    if (address == null) {
      setState(() => _error = 'Collez le lien entier, tel que vous l’avez '
          'reçu : https://…/share#…');
      return;
    }
    Navigator.of(context).pop(address);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: const Text('Ouvrir un lien de partage'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Collez le lien qu’on vous a envoyé. Il se regarde ici, sans '
              'compte.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            TvDeferredKeyboard(
              builder: (context, focusNode, canRequestFocus) => TextField(
                controller: _link,
                focusNode: focusNode,
                canRequestFocus: canRequestFocus,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'Lien',
                  hintText: 'https://…/share#…',
                  errorText: _error,
                  errorMaxLines: 3,
                ),
                onSubmitted: (_) => _open(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _open, child: const Text('Ouvrir')),
      ],
    );
  }
}

/// La page d'un lien et son lecteur, en invité, dans l'app installée
/// (ADR-0037 §9).
///
/// Un navigateur à part, sous les fournisseurs du lien : la page et le lecteur
/// qu'elle ouvre y trouvent le [SharedLinkApiClient], pas le client de l'app —
/// qui garde son serveur et ses comptes intacts pour le retour.
class SharedLinkGuestScope extends StatefulWidget {
  const SharedLinkGuestScope({super.key, required this.api});

  final SharedLinkApiClient api;

  @override
  State<SharedLinkGuestScope> createState() => _SharedLinkGuestScopeState();
}

class _SharedLinkGuestScopeState extends State<SharedLinkGuestScope> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _clearMediaCaches();
  }

  @override
  void dispose() {
    _clearMediaCaches();
    super.dispose();
  }

  /// Ces caches sont indexés par identifiant de média, et un identifiant ne
  /// veut rien dire d'un serveur à l'autre : la fiche d'un film d'ici ne doit
  /// pas habiller celui du lien, ni l'inverse au retour.
  void _clearMediaCaches() {
    MediaDetailsCache.clear();
    MediaTracksCache.clear();
  }

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: sharedLinkProviders(widget.api),
      // Retour (Android, souris, clavier) quitte d'abord le lecteur, puis la
      // page du lien.
      child: PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final handled = await _navigator.currentState?.maybePop() ?? false;
          if (!handled && mounted) _close();
        },
        child: Navigator(
          key: _navigator,
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => SharedLinkScreen(api: widget.api, onClose: _close),
          ),
        ),
      ),
    );
  }
}
