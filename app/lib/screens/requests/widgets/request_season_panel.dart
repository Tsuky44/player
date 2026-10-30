import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/media_request.dart';
import '../../../models/request_release.dart';
import '../../../providers/media_requests_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_type.dart';
import '../../../utils/format.dart';
import '../../../widgets/global/app_network_image.dart';
import '../../../l10n/tr.dart';
import '../../../widgets/global/detail_hero.dart';
import 'request_release_sheet.dart';
import 'season_cascade.dart';
import 'request_status_badge.dart';

/// Le contenu du panneau sous les bulles de saisons, comme OnyxHub
/// (`SeasonEpisodes`) : l'en-tête de la saison ouverte (nom, nombre
/// d'épisodes et année, statut, « Demander »), puis ses épisodes, chargés à la
/// demande depuis TMDB. Le [cache] appartient à la liste : une saison déjà vue
/// s'affiche aussitôt quand on y revient.
class RequestSeasonPanel extends StatefulWidget {
  final int tmdbId;
  final RequestMediaItem showItem;
  final RequestSeason season;
  final Map<int, List<RequestEpisode>> cache;

  const RequestSeasonPanel({
    super.key,
    required this.tmdbId,
    required this.showItem,
    required this.season,
    required this.cache,
  });

  @override
  State<RequestSeasonPanel> createState() => _RequestSeasonPanelState();
}

class _RequestSeasonPanelState extends State<RequestSeasonPanel>
    with TickerProviderStateMixin {
  /// L'en-tête arrive à l'ouverture, les épisodes quand ils sont là : deux
  /// horloges, parce que le réseau peut les séparer de plusieurs secondes.
  late final SeasonCascade _head;
  late final SeasonCascade _list;
  bool _arrived = false;
  bool _loading = false;
  bool _requesting = false;
  String? _error;

  /// Le compagnon accorde la recherche interactive à ce compte (ADR-0098).
  bool _canSearch = false;

  List<RequestEpisode>? get _episodes => widget.cache[widget.season.number];

  @override
  void initState() {
    super.initState();
    _head = SeasonCascade(this);
    _list = SeasonCascade(this);
    if (_episodes == null) _load();
    _loadAccess();
  }

  Future<void> _loadAccess() async {
    final access = await context.read<MediaRequestsProvider>().loadAccess();
    if (mounted && access.canInteractiveSearch) {
      setState(() => _canSearch = true);
    }
  }

  /// Ouvre la recherche de la saison, ou de l'épisode [episode].
  void _search({RequestEpisode? episode}) {
    final season = widget.season.number;
    RequestReleaseSheet.show(
      context,
      target: RequestReleaseTarget(
        tmdbId: widget.tmdbId,
        season: season,
        episode: episode?.number,
      ),
      heading: episode == null
          ? seasonTitle(widget.season)
          : tr('Saison {0} · Épisode {1}', [season, episode.number]),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_arrived) return;
    _arrived = true;
    // Avant la première image, pour qu'aucun texte ne s'affiche en entier
    // avant de monter.
    _head.play(context);
    if (_episodes != null) _list.play(context);
  }

  @override
  void dispose() {
    _head.dispose();
    _list.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final episodes = await context
          .read<MediaRequestsProvider>()
          .loadSeasonEpisodes(widget.tmdbId, widget.season.number);
      widget.cache[widget.season.number] = episodes;
      if (!mounted) return;
      _list.play(context);
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = tr('Impossible de charger les épisodes.');
      });
    }
  }

  Future<void> _requestThisSeason() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      await context.read<MediaRequestsProvider>().request(
        widget.showItem,
        seasons: [widget.season.number],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('Demande envoyée pour la saison {0}.', [widget.season.number]),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('Impossible d’envoyer la demande.'))),
      );
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pas de fond ici : le verre du cadre est posé par la liste, derrière le
    // panneau et la lumière qui glisse sous la bulle ouverte.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _head.item(0, _header()),
        const SizedBox(height: 14),
        _body(),
      ],
    );
  }

  Widget _header() {
    final season = widget.season;
    final year = season.year;
    final count = tr('{0} épisodes', [season.episodeCount]);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            seasonTitle(season),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: AppType.headline,
            ),
          ),
          Text(
            year == null ? count : '$count · $year',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: AppType.subhead,
            ),
          ),
          if (season.status.canRequest)
            HeroPill(
              label: tr('Demander'),
              icon: AppIcons.download,
              style: HeroPillStyle.request,
              dense: true,
              loading: _requesting,
              onPressed: _requesting ? null : _requestThisSeason,
            )
          // Une saison là n'a rien à dire de plus que ses épisodes.
          else if (season.status != RequestMediaStatus.available)
            RequestStatusBadge(
              status: season.status,
              remaining: season.remainingEpisodes,
            ),
          if (_canSearch)
            HeroPill(
              label: tr('Recherche interactive'),
              icon: AppIcons.search,
              style: HeroPillStyle.glass,
              dense: true,
              onPressed: _search,
            ),
        ],
      ),
    );
  }

  Widget _body() {
    final episodes = _episodes;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                style: TextStyle(color: AppColors.error.withValues(alpha: 0.9)),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _load,
                child: Text(tr('Réessayer')),
              ),
            ],
          ),
        ),
      );
    }
    if (episodes == null || episodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            tr('Aucun épisode trouvé.'),
            style: TextStyle(color: Colors.white.withValues(alpha: 0.45)),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < episodes.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _list.item(
            i,
            _EpisodeCard(
              episode: episodes[i],
              onSearch: _canSearch ? () => _search(episode: episodes[i]) : null,
            ),
          ),
        ],
      ],
    );
  }
}

/// Le nom d'une saison : celui de TMDB, ou « Saison N » quand il manque.
String seasonTitle(RequestSeason season) =>
    season.name.isNotEmpty ? season.name : tr('Saison {0}', [season.number]);

class _EpisodeCard extends StatelessWidget {
  final RequestEpisode episode;

  /// Ouvre la recherche interactive de l'épisode ; nul quand le compte n'y a
  /// pas droit.
  final VoidCallback? onSearch;

  const _EpisodeCard({required this.episode, this.onSearch});

  @override
  Widget build(BuildContext context) {
    final airDate = formatAirDate(episode.airDate);
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                episode.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: AppType.callout,
                ),
              ),
            ),
            if (airDate != null) ...[
              const SizedBox(width: 10),
              Text(
                airDate,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: AppType.footnote,
                ),
              ),
            ],
            if (onSearch != null)
              IconButton(
                tooltip: tr('Recherche interactive'),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 32, height: 24),
                padding: EdgeInsets.zero,
                iconSize: 18,
                icon: Icon(AppIcons.search,
                    color: Colors.white.withValues(alpha: 0.7)),
                onPressed: onSearch,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          episode.overview.isEmpty
              ? tr('Aucun résumé disponible.')
              : episode.overview,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: AppType.subhead,
            height: 1.45,
          ),
        ),
        if (episode.runtime > 0 || episode.rating > 0) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            children: [
              if (episode.runtime > 0)
                Text(
                  '${episode.runtime} min',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: AppType.footnote,
                  ),
                ),
              if (episode.rating > 0)
                Text(
                  '★ ${episode.rating.toStringAsFixed(1)}',
                  style: const TextStyle(
                    color: Color(0xFFF5C518),
                    fontSize: AppType.footnote,
                  ),
                ),
            ],
          ),
        ],
      ],
    );

    // Verre léger plutôt qu'un aplat : les cartes posent sur le cadre du
    // panneau, comme les cartes d'OnyxHub (blanc à 3 %, arête à 6 %).
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      padding: const EdgeInsets.all(12),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _still(),
                const SizedBox(width: 14),
                Expanded(child: details),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _still(),
                const SizedBox(height: 12),
                details,
              ],
            ),
    );
  }

  Widget _still() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 200,
        height: 112,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppNetworkImage(
              url: episode.stillUrl,
              fit: BoxFit.cover,
              errorWidget: _stillPlaceholder(),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'E${episode.number}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stillPlaceholder() {
    return ColoredBox(
      color: AppColors.background,
      child: Center(
        child: Icon(
          AppIcons.movie,
          color: Colors.white.withValues(alpha: 0.2),
          size: 28,
        ),
      ),
    );
  }
}
