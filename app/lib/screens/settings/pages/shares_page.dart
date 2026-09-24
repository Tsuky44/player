import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/media_share.dart';
import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../widgets/media_thumb.dart';
import '../widgets/settings_ui.dart';

/// Les liens de partage publics créés par ce compte (ADR-0037) : ce qu'ils
/// sont devenus, et de quoi les couper.
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

  Future<void> _load() async {
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
          settingsErrorText(e, 'Impossible de charger vos liens de partage.'));
    }
  }

  Future<void> _delete(MediaShare share) async {
    final confirmed = await confirmSettingsAction(
      context,
      title: share.isActive ? 'Couper ce lien ?' : 'Retirer ce lien ?',
      message: share.isActive
          ? 'Le lien vers « ${share.title} » ne s’ouvrira plus, et une lecture '
              'en cours s’arrêtera tout de suite.'
          : 'Il disparaîtra de cette liste.',
      confirmLabel: share.isActive ? 'Couper' : 'Retirer',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = share.id);
    try {
      await context.read<ApiClient>().deleteMediaShare(share.id);
      if (mounted) {
        showSettingsSnack(
            context, share.isActive ? 'Lien coupé.' : 'Lien retiré.');
      }
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, 'Échec de la suppression.'),
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

    return SettingsPage(
      title: 'Liens de partage',
      description:
          'Les films et épisodes que vous avez partagés par lien public. '
          'Pour en créer un, utilisez le bouton lien sur la fiche du média.',
      onRefresh: _load,
      actions: [
        IconButton(
          tooltip: 'Actualiser',
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: [
        if (_error != null) SettingsBanner(_error!, tone: BannerTone.error),
        if (shares == null && _error == null)
          const SettingsLoading()
        else if (shares != null) ...[
          if (shares.isEmpty)
            const SettingsGroup(children: [
              SettingsEmptyNote(
                'Aucun lien pour l’instant.',
                icon: Icons.link_off_rounded,
              ),
            ]),
          if (active.isNotEmpty)
            SettingsGroup(
              title: 'Actifs',
              children: [for (final share in active) _tile(share)],
            ),
          if (ended.isNotEmpty)
            SettingsGroup(
              title: 'Terminés',
              footer: 'Un lien vu ou expiré ne s’ouvre plus.',
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
        isShow: share.mediaType == 'episode',
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
              tooltip: share.isActive ? 'Couper le lien' : 'Retirer',
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
      parts.add(at == null ? 'Vu' : 'Vu ${relativeTime(at, now: reference)}');
    case 'expired':
      parts.add('Expiré');
    default:
      if (share.singleUse) {
        parts.add(
            share.claimed ? 'Ouvert, pas encore vu' : 'Détruit après lecture');
      } else {
        parts.add(
            share.views == 0 ? 'Jamais ouvert' : 'Ouvert ${share.views} fois');
      }
      final expires = share.expiresAt;
      parts.add(expires == null
          ? 'Sans limite'
          : 'Expire le ${formatFrenchDay(expires)}');
  }
  if (share.hasPassword) parts.add('Mot de passe');
  return parts.join(' · ');
}
