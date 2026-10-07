import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/media_share.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_deferred_keyboard.dart';
import '../../screens/settings/widgets/settings_ui.dart' show settingsErrorText;
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';

/// Crée un lien public vers un film, un épisode, une saison ou une série, puis
/// montre ce lien.
///
/// Le lien ne se montre qu'une fois : le serveur n'en garde que l'empreinte
/// (ADR-0037). La page « Liens de partage » des réglages ne permet donc que de
/// suivre et de supprimer les liens, pas de les recopier.
Future<void> showShareMediaDialog(
  BuildContext context, {
  required ApiClient api,
  required int mediaId,
  required String title,
  bool collection = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ShareMediaDialog(
      api: api,
      mediaId: mediaId,
      title: title,
      collection: collection,
    ),
  );
}

class ShareMediaDialog extends StatefulWidget {
  const ShareMediaDialog({
    super.key,
    required this.api,
    required this.mediaId,
    required this.title,
    this.collection = false,
  });

  final ApiClient api;
  final int mediaId;
  final String title;

  /// Le lien ouvre une saison ou une série. « Détruire après lecture » n'est
  /// alors pas proposé : le serveur le refuse, une saison n'étant pas « vue »
  /// au premier épisode fini.
  final bool collection;

  @override
  State<ShareMediaDialog> createState() => _ShareMediaDialogState();
}

class _ShareMediaDialogState extends State<ShareMediaDialog> {
  final TextEditingController _password = TextEditingController();

  // Détruire après lecture par défaut : un lien qui circule plus longtemps que
  // son usage est le cas à choisir, pas celui qu'on obtient sans y penser.
  late bool _singleUse = !widget.collection;
  ShareLifetime _lifetime = ShareLifetime.week;
  bool _creating = false;
  String? _error;
  MediaShare? _created;
  bool _copied = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final share = await widget.api.createMediaShare(
        mediaId: widget.mediaId,
        password: _password.text,
        singleUse: _singleUse,
        lifetime: _lifetime,
      );
      if (!mounted) return;
      setState(() {
        _created = share;
        _creating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error =
            settingsErrorText(e, tr('Impossible de créer le lien. Réessayez.'));
      });
    }
  }

  String get _link => widget.api.mediaShareLink(_created!.code ?? '');

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _link));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final created = _created;
    return AlertDialog(
      backgroundColor: AppColors.surfaceElevated,
      title: Text(created == null ? tr('Partager par lien') : tr('Lien créé')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: created == null ? _buildForm() : _buildResult(created),
        ),
      ),
      actions: created == null
          ? [
              TextButton(
                onPressed: _creating ? null : () => Navigator.of(context).pop(),
                child: Text(tr('Annuler')),
              ),
              FilledButton(
                onPressed: _creating ? null : _create,
                child: _creating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(tr('Créer le lien')),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr('Terminé')),
              ),
              FilledButton.icon(
                autofocus: true,
                onPressed: _copy,
                icon: Icon(_copied ? AppIcons.check : AppIcons.copy,
                    size: 18),
                label: Text(_copied ? tr('Copié') : tr('Copier le lien')),
              ),
            ],
    );
  }

  Widget _buildForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.collection
              ? tr('Toute personne qui a le lien peut regarder les épisodes '
                  'de « {0} » dans son navigateur ou dans l’app Onyx, sans '
                  'compte, jusqu’à l’expiration du lien.', [widget.title])
              : tr('Toute personne qui a le lien peut regarder « {0} » dans '
                  'son navigateur ou dans l’app Onyx, sans compte.', [widget.title]),
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 12),
        if (!widget.collection) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _singleUse,
            onChanged:
                _creating ? null : (v) => setState(() => _singleUse = v),
            title: Text(tr('Détruire après lecture')),
            subtitle: Text(
              _singleUse
                  ? tr('Le lien ne s’ouvre que sur un appareil, et disparaît '
                      'une fois le média vu.')
                  : tr('Le lien reste utilisable, par plusieurs personnes, '
                      'jusqu’à son expiration.'),
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: AppType.subhead),
            ),
          ),
          const SizedBox(height: 12),
        ],
        TvDeferredKeyboard(
          builder: (context, focusNode, canRequestFocus) => TextField(
            controller: _password,
            focusNode: focusNode,
            canRequestFocus: canRequestFocus,
            enabled: !_creating,
            obscureText: true,
            maxLength: 72,
            decoration: InputDecoration(
              labelText: tr('Mot de passe (facultatif)'),
              helperText: tr('À transmettre à part, pas avec le lien.'),
              counterText: '',
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          tr('Valable'),
          style: TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final lifetime in ShareLifetime.values)
              ChoiceChip(
                label: Text(lifetime.label),
                selected: _lifetime == lifetime,
                onSelected: _creating
                    ? null
                    : (_) => setState(() => _lifetime = lifetime),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: AppColors.error)),
        ],
      ],
    );
  }

  Widget _buildResult(MediaShare share) {
    final details = [
      share.singleUse ? tr('Détruit après lecture') : tr('Réutilisable'),
      if (share.hasPassword) tr('Protégé par mot de passe'),
      share.expiresAt == null
          ? tr('Sans limite de durée')
          : tr('Valable {0}', [_lifetime.label]),
    ];
    final localOnly = isLocalOnlyAddress(Uri.tryParse(_link));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: SelectableText(
            _link,
            style: const TextStyle(fontSize: AppType.subhead, color: AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          details.join(' · '),
          style: const TextStyle(color: AppColors.textSecondary, fontSize: AppType.subhead),
        ),
        const SizedBox(height: 12),
        Text(
          tr('Copiez-le maintenant : il ne sera plus affiché. Vous pourrez '
              'le suivre ou le supprimer dans Paramètres › Liens de partage. '
              'Dans l’app Onyx, il se colle sur l’écran de connexion, sous « '
              'Ouvrir un lien de partage ».'),
          style: TextStyle(color: AppColors.textMuted, fontSize: AppType.subhead),
        ),
        if (localOnly) ...[
          const SizedBox(height: 12),
          Text(
            tr('Cette adresse n’est joignable que depuis votre réseau '
                'local. Pour un envoi à l’extérieur, connectez l’app au '
                'serveur par son adresse publique avant de créer le lien.'),
            style: TextStyle(color: AppColors.warning, fontSize: AppType.subhead),
          ),
        ],
      ],
    );
  }
}

/// Dit si [uri] désigne une machine que seul le réseau local peut joindre :
/// localhost, une adresse privée ou un nom en `.local`. Un lien de partage
/// composé sur une telle adresse ne marchera pas chez un ami.
bool isLocalOnlyAddress(Uri? uri) {
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.local') || host == '::1') {
    return true;
  }
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList();
  if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
  final a = octets[0]!, b = octets[1]!;
  return a == 10 ||
      a == 127 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254);
}
