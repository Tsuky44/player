import 'package:flutter/material.dart';

import '../../navigation/search_route_observer.dart';
import '../../models/media_share.dart';
import '../../models/models.dart';
import '../../models/shared_show.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../tv/tv_deferred_keyboard.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import '../../widgets/global/app_network_image.dart';
import '../player/player_screen.dart';
import 'shared_link_show.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';

/// La page d'un lien de partage : ce qu'il ouvre, son mot de passe s'il en a
/// un, et le bouton qui lance le lecteur Onyx (ADR-0037).
class SharedLinkScreen extends StatefulWidget {
  const SharedLinkScreen({super.key, required this.api, this.onClose});

  final SharedLinkApiClient api;

  /// Ferme la page, dans l'app installée (ADR-0037 §9). Nul sur le web, où
  /// la page est toute l'app : il n'y a rien derrière elle.
  final VoidCallback? onClose;

  @override
  State<SharedLinkScreen> createState() => _SharedLinkScreenState();
}

class _SharedLinkScreenState extends State<SharedLinkScreen> {
  final TextEditingController _password = TextEditingController();

  SharedMediaInfo? _info;

  /// La saison ou la série du lien, avec l'avancement gardé sur l'appareil ;
  /// nulle pour un film ou un épisode.
  SharedShow? _show;
  bool _loading = true;
  bool _opening = false;

  /// Une erreur qui ferme le lien (inconnu, expiré, ouvert ailleurs).
  String? _fatal;

  /// Une erreur qu'on peut corriger : mauvais mot de passe, réseau.
  String? _error;
  int _resumeAt = 0;

  /// L'épisode d'une saison ou d'une série en train de s'ouvrir.
  int? _openingEpisode;

  /// Le lien attend encore son mot de passe : le serveur n'a pas dit ce qu'il
  /// ouvre.
  static bool _locked(SharedMediaInfo info) =>
      info.needsPassword && info.title.isEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.api.code.isEmpty) {
      setState(() {
        _loading = false;
        _fatal = tr('Il manque la fin de l’adresse. Demandez à la personne qui vous '
            'l’a envoyée de la copier à nouveau.');
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fresh = await widget.api.info();
      // Une fois le mot de passe donné, garder ce que l'ouverture a appris :
      // la description anonyme ne nomme plus le média.
      final info = fresh.title.isEmpty && (_info?.title.isNotEmpty ?? false)
          ? _info!
          : fresh;
      // Relu à chaque retour du lecteur : c'est là que la reprise avance.
      final show = info.isCollection ? await widget.api.describe(info) : null;
      final resumeAt = await widget.api.savedPosition();
      if (!mounted) return;
      setState(() {
        _info = info;
        _show = show;
        _resumeAt = resumeAt;
        _fatal = null;
        _loading = false;
      });
    } on SharedLinkException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (e.status == 0) {
          _error = e.message;
        } else {
          _fatal = e.message;
        }
      });
    }
  }

  /// Ouvre le lecteur sur le média du lien, ou sur [episode] quand le lien est
  /// celui d'une saison ou d'une série.
  Future<void> _watch({HomeMediaItem? episode}) async {
    final info = _info;
    if (info == null || _opening) return;
    setState(() {
      _opening = true;
      _openingEpisode = episode?.media.id;
      _error = null;
    });
    try {
      if (episode == null && _locked(info)) {
        // Tant que le mot de passe manque, le serveur ne dit pas ce que le
        // lien ouvre : c'est lui qui révèle une saison ou une série, dont il
        // reste à choisir l'épisode.
        final contents = await widget.api.contents(_password.text);
        if (!mounted) return;
        if (contents.isCollection) {
          final show = await widget.api.describe(contents);
          if (!mounted) return;
          setState(() {
            _info = contents;
            _show = show;
            _opening = false;
          });
          return;
        }
      }
      final opened =
          await widget.api.open(_password.text, episodeId: episode?.media.id);
      if (!mounted) return;
      setState(() {
        // La liste des épisodes reste : c'est d'elle qu'on choisit le suivant.
        if (episode == null) _info = opened.media;
        _opening = false;
        _openingEpisode = null;
      });
      await Navigator.of(context).push(MaterialPageRoute<void>(
        settings:
            const RouteSettings(name: SearchRouteObserver.playerRouteName),
        builder: (_) => episode != null
            // L'épisode d'une série part avec sa saison et sa série, comme
            // depuis la fiche d'un compte : le lecteur sait alors enchaîner
            // sur le suivant et lister les autres.
            ? PlayerScreen(
                media: episode,
                seasonNumber: episode.media.seasonNumber,
                resumeAtSeconds: episode.currentPositionSeconds,
              )
            : PlayerScreen(
                media: Media(
                  id: opened.mediaId,
                  type: opened.media.mediaType == 'episode'
                      ? MediaType.episode
                      : MediaType.movie,
                  title: opened.media.subtitle.isEmpty
                      ? opened.media.title
                      : '${opened.media.title} · ${opened.media.subtitle}',
                  duration: opened.media.duration,
                  posterUrl: opened.media.posterUrl,
                  createdAt: DateTime.now(),
                ),
                resumeAtSeconds: _resumeAt,
              ),
      ));
      if (mounted) await _load();
    } on SharedLinkException catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _openingEpisode = null;
        if (e.status == 401 || e.status == 429 || e.status == 0) {
          _error = e.message;
        } else {
          _fatal = e.message;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final show = _show;
    // Une saison ou une série a sa propre page, celle d'un compte ; un lien
    // qui vient de se fermer (expiré, supprimé) revient à la carte, qui le dit.
    if (show != null && _fatal == null) {
      return SharedLinkShowView(
        show: show,
        openingId: _openingEpisode,
        error: _error,
        onPlay: _opening ? null : (episode) => _watch(episode: episode),
        onClose: widget.onClose,
      );
    }
    final poster =
        resolvePosterUrl(info?.posterUrl, serverBaseUrl: widget.api.baseUrl);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: widget.onClose == null
          ? null
          : AppBar(
              backgroundColor: AppColors.background,
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: IconButton(
                tooltip: tr('Fermer'),
                onPressed: widget.onClose,
                icon: const Icon(AppIcons.close),
              ),
            ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: LayoutBuilder(builder: (context, constraints) {
                final narrow = constraints.maxWidth < 560;
                final cover = _Poster(url: poster, width: narrow ? 150 : 200);
                final details = _buildDetails(info, centered: narrow);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(narrow ? 20 : 28),
                    child: narrow
                        ? Column(children: [
                            cover,
                            const SizedBox(height: 20),
                            details,
                          ])
                        : Row(
                            children: [
                              cover,
                              const SizedBox(width: 28),
                              Expanded(child: details),
                            ],
                          ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetails(SharedMediaInfo? info, {required bool centered}) {
    final align =
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final textAlign = centered ? TextAlign.center : TextAlign.start;
    final title = _fatal != null
        ? tr('Lien indisponible')
        : info == null
            ? (_loading ? tr('Chargement…') : tr('Lien indisponible'))
            : info.title.isNotEmpty
                ? info.title
                : tr('Contenu protégé');
    final badges = [
      if (info != null && info.duration > 0) formatDuration(info.duration),
      if (info != null && info.singleUse) tr('Lien à usage unique'),
    ];
    final needsPassword = info?.needsPassword ?? false;

    return Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr('Onyx · Partagé avec vous'),
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: AppType.subhead,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          textAlign: textAlign,
          style: const TextStyle(fontSize: AppType.display, fontWeight: FontWeight.w700),
        ),
        if (info != null && info.subtitle.isNotEmpty && _fatal == null) ...[
          const SizedBox(height: 8),
          Text(
            info.subtitle,
            textAlign: textAlign,
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: AppType.headline),
          ),
        ],
        if (badges.isNotEmpty && _fatal == null) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: centered ? WrapAlignment.center : WrapAlignment.start,
            children: [for (final label in badges) _Badge(label)],
          ),
        ],
        const SizedBox(height: 22),
        if (_fatal != null)
          Text(_fatal!,
              textAlign: textAlign,
              style: const TextStyle(color: AppColors.textSecondary))
        else if (info != null) ...[
          if (needsPassword) ...[
            TvDeferredKeyboard(
              builder: (context, focusNode, canRequestFocus) => TextField(
                controller: _password,
                focusNode: focusNode,
                canRequestFocus: canRequestFocus,
                autofocus: true,
                obscureText: true,
                enabled: !_opening,
                maxLength: 72,
                decoration: InputDecoration(
                  labelText: tr('Mot de passe'),
                  helperText: tr('Ce lien est protégé par un mot de passe.'),
                  counterText: '',
                ),
                onSubmitted: (_) => _watch(),
              ),
            ),
            const SizedBox(height: 16),
          ],
          SizedBox(
            width: centered ? double.infinity : null,
            height: 48,
            child: FilledButton.icon(
              autofocus: !needsPassword,
              onPressed: _opening ? null : _watch,
              icon: _opening
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              // Verrouillé, le lien peut encore être une série : « Ouvrir »
              // ne promet pas une lecture.
              label: Text(_locked(info)
                  ? tr('Ouvrir')
                  : _resumeAt > 30
                      ? tr('Reprendre à {0}', [formatPlaybackTime(_resumeAt)])
                      : tr('Regarder')),
            ),
          ),
        ] else if (_loading)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: textAlign,
              style: const TextStyle(color: AppColors.error)),
          if (info == null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: Text(tr('Réessayer'))),
          ],
        ],
      ],
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.url, required this.width});

  final String? url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: AppColors.surfaceElevated,
      alignment: Alignment.center,
      child: Icon(Icons.movie_outlined,
          size: width * 0.35, color: AppColors.textMuted),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: width * 1.5,
        child: url == null
            ? fallback
            : AppNetworkImage(
                url: url!,
                placeholder: fallback,
                errorWidget: fallback,
              ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: AppType.footnote,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
