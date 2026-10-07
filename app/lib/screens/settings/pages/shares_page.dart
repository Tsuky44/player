import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/media_share.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../tv/tv_mode.dart';
import '../../shared_link/shared_link_guest.dart';
import '../widgets/media_thumb.dart';
import '../widgets/settings_ui.dart';
import '../../../l10n/tr.dart';

/// Les liens de partage publics (ADR-0037) : ouvrir celui qu'on a reçu, et,
/// pour un compte qui a le droit d'en créer, voir ce que les siens sont
/// devenus et les couper.
///
/// Un lien ne se recopie pas d'ici : le serveur n'en garde que l'empreinte.
class SharesPage extends StatefulWidget {
  const SharesPage({super.key});

  @override
  State<SharesPage> createState() => _SharesPageState();
}

class _SharesPageState extends State<SharesPage> {
  List<MediaShare>? _shares;
  String? _error;
  int? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Sans le droit `share_media` la page n'a aucun lien à lister : ne pas
  /// le demander évite un 403.
  bool get _canShare => context.read<AuthProvider>().permissions.shareMedia;

  Future<void> _load() async {
    if (!_canShare) return;
    try {
      final shares = await context.read<ApiClient>().listMediaShares();
      if (!mounted) return;
      setState(() {
        _shares = shares;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          settingsErrorText(e, tr('Impossible de charger vos liens de partage.')));
    }
  }

  Future<void> _delete(MediaShare share) async {
    final confirmed = await confirmSettingsAction(
      context,
      title: share.isActive ? tr('Couper ce lien ?') : tr('Retirer ce lien ?'),
      message: share.isActive
          ? tr('Le lien vers « {0} » ne s’ouvrira plus, et une lecture en '
              'cours s’arrêtera tout de suite.', [share.title])
          : tr('Il disparaîtra de cette liste.'),
      confirmLabel: share.isActive ? tr('Couper') : tr('Retirer'),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = share.id);
    try {
      await context.read<ApiClient>().deleteMediaShare(share.id);
      if (mounted) {
        showSettingsSnack(
            context, share.isActive ? tr('Lien coupé.') : tr('Lien retiré.'));
      }
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, tr('Échec de la suppression.')),
            error: true);
      }
    }
    if (!mounted) return;
    setState(() => _busy = null);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final shares = _shares;
    final active = shares?.where((s) => s.isActive).toList() ?? const [];
    final ended = shares?.where((s) => !s.isActive).toList() ?? const [];
    final canShare = context.watch<AuthProvider>().permissions.shareMedia;

    return SettingsPage(
      title: tr('Liens de partage'),
      description: canShare
          ? tr('Les films, épisodes et séries que vous avez partagés par lien '
              'public. Pour en créer un, utilisez le bouton lien sur la '
              'fiche du média.')
          : tr('Un lien de partage se regarde sans compte sur le serveur qui '
              'l’a créé.'),
      onRefresh: canShare ? _load : null,
      actions: [
        if (canShare)
          IconButton(
            tooltip: tr('Actualiser'),
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
      ],
      children: [
        // Un lien reçu s'ouvre en invité même connecté : il peut venir d'un
        // autre serveur, et ne doit rien écrire dans l'historique de ce
        // compte (ADR-0037 §11). Pas sur un téléviseur, qui n'a pas de
        // presse-papiers où le recevoir.
        if (!TvMode.isTv)
          SettingsGroup(
            title: tr('Lien reçu'),
            footer: tr('Il se regarde en invité : rien ne s’ajoute à votre '
                'historique, et votre compte n’est pas montré au serveur du '
                'lien.'),
            children: [
              SettingsTile(
                icon: Icons.link_rounded,
                title: tr('Ouvrir un lien de partage'),
                subtitle: tr('Collez le lien qu’on vous a envoyé'),
                onTap: () => showOpenSharedLinkDialog(context),
              ),
            ],
          ),
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (!canShare)
          const SizedBox.shrink()
        else if (shares == null && _error == null)
          const SettingsLoading()
        else if (shares != null) ...[
          if (shares.isEmpty)
            SettingsGroup(children: [
              SettingsEmptyNote(
                tr('Aucun lien pour l’instant.'),
                icon: Icons.link_off_rounded,
              ),
            ]),
          if (active.isNotEmpty)
            SettingsGroup(
              title: tr('Actifs'),
              children: [for (final share in active) _tile(share)],
            ),
          if (ended.isNotEmpty)
            SettingsGroup(
              title: tr('Terminés'),
              footer: tr('Un lien vu ou expiré ne s’ouvre plus.'),
              children: [for (final share in ended) _tile(share)],
            ),
        ],
      ],
    );
  }

  Widget _tile(MediaShare share) {
    final title = share.subtitle.isEmpty
        ? share.title
        : '${share.title} · ${share.subtitle}';
    return SettingsTile(
      leading: MediaThumb(
        posterUrl: share.posterUrl ?? '',
        width: 36,
        isShow: share.mediaType != 'movie',
      ),
      title: title,
      subtitle: mediaShareSummary(share),
      trailing: _busy == share.id
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: share.isActive ? tr('Couper le lien') : tr('Retirer'),
              onPressed: () => _delete(share),
              icon: Icon(
                share.isActive
                    ? Icons.link_off_rounded
                    : Icons.delete_outline_rounded,
                color: AppColors.textSecondary,
              ),
            ),
    );
  }
}

/// Une ligne qui dit ce qu'un lien est devenu : « Détruit après lecture ·
/// Expire le jeudi 1 octobre · Mot de passe », « Vu aujourd’hui à 21:04 »…
String mediaShareSummary(MediaShare share, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final parts = <String>[];
  switch (share.status) {
    case 'watched':
      final at = share.consumedAt;
      parts.add(at == null ? tr('Vu') : tr('Vu {0}', [relativeTime(at, now: reference)]));
    case 'expired':
      parts.add(tr('Expiré'));
    default:
      if (share.singleUse) {
        parts.add(
            share.claimed ? tr('Ouvert, pas encore vu') : tr('Détruit après lecture'));
      } else {
        parts.add(
            share.views == 0 ? tr('Jamais ouvert') : tr('Ouvert {0} fois', [share.views]));
      }
      final expires = share.expiresAt;
      parts.add(expires == null
          ? tr('Sans limite')
          : tr('Expire le {0}', [formatFrenchDay(expires)]));
  }
  if (share.hasPassword) parts.add(tr('Mot de passe'));
  return parts.join(' · ');
}
