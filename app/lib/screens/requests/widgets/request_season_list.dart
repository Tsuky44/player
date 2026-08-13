import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/media_request.dart';
import '../../../providers/media_requests_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/format.dart';
import 'request_status_badge.dart';

/// Expandable season accordion with lazy-loaded TMDB episodes.
class RequestSeasonList extends StatelessWidget {
  final int tmdbId;
  final RequestMediaItem showItem;
  final List<RequestSeason> seasons;

  const RequestSeasonList({
    super.key,
    required this.tmdbId,
    required this.showItem,
    required this.seasons,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = [...seasons]..sort((a, b) => a.number.compareTo(b.number));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Saisons',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 14),
        ...sorted.map(
          (season) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _SeasonAccordion(
              tmdbId: tmdbId,
              showItem: showItem,
              season: season,
            ),
          ),
        ),
      ],
    );
  }
}

class _SeasonAccordion extends StatefulWidget {
  final int tmdbId;
  final RequestMediaItem showItem;
  final RequestSeason season;

  const _SeasonAccordion({
    required this.tmdbId,
    required this.showItem,
    required this.season,
  });

  @override
  State<_SeasonAccordion> createState() => _SeasonAccordionState();
}

class _SeasonAccordionState extends State<_SeasonAccordion> {
  bool _open = false;
  bool _loading = false;
  bool _loaded = false;
  String? _error;
  List<RequestEpisode> _episodes = const [];

  bool _requestingSeason = false;

  Future<void> _requestThisSeason() async {
    if (_requestingSeason) return;
    setState(() => _requestingSeason = true);
    try {
      await context.read<MediaRequestsProvider>().request(
            widget.showItem,
            seasons: [widget.season.number],
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Demande envoyée pour la saison ${widget.season.number}.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d’envoyer la demande.')),
      );
    } finally {
      if (mounted) setState(() => _requestingSeason = false);
    }
  }

  Future<void> _toggle() async {
    final next = !_open;
    setState(() => _open = next);
    if (!next || _loaded || _loading) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final episodes = await context
          .read<MediaRequestsProvider>()
          .loadSeasonEpisodes(widget.tmdbId, widget.season.number);
      if (!mounted) return;
      setState(() {
        _episodes = episodes;
        _loaded = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Impossible de charger les épisodes.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final season = widget.season;
    final title =
        season.name.isNotEmpty ? season.name : 'Saison ${season.number}';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggle,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 44,
                        height: 66,
                        child: season.posterUrl != null
                            ? CachedNetworkImage(
                                imageUrl: season.posterUrl!,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) =>
                                    _posterPlaceholder(),
                              )
                            : _posterPlaceholder(),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              RequestStatusBadge(status: season.status),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${season.episodeCount} épisodes',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (season.status.canRequest) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _requestingSeason ? null : _requestThisSeason,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: _requestingSeason
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text(
                                'Demander',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                      ),
                    ],
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.expand_more_rounded,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open) ...[
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.2),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                child: _body(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _posterPlaceholder() {
    return ColoredBox(
      color: AppColors.background,
      child: Center(
        child: Text(
          'N/A',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 10,
          ),
        ),
      ),
    );
  }

  Widget _body() {
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
                onPressed: () {
                  setState(() {
                    _loaded = false;
                    _error = null;
                  });
                  _toggle();
                },
                child: const Text('Réessayer'),
              ),
            ],
          ),
        ),
      );
    }
    if (_episodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'Aucun épisode trouvé.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.45)),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < _episodes.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _EpisodeCard(episode: _episodes[i]),
        ],
      ],
    );
  }
}

class _EpisodeCard extends StatelessWidget {
  final RequestEpisode episode;

  const _EpisodeCard({required this.episode});

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
                  fontSize: 15,
                ),
              ),
            ),
            if (airDate != null) ...[
              const SizedBox(width: 10),
              Text(
                airDate,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          episode.overview.isEmpty
              ? 'Aucun résumé disponible.'
              : episode.overview,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 13,
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
                    fontSize: 12,
                  ),
                ),
              if (episode.rating > 0)
                Text(
                  '★ ${episode.rating.toStringAsFixed(1)}',
                  style: const TextStyle(
                    color: Color(0xFFF5C518),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ],
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
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
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 200,
        height: 112,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (episode.stillUrl != null)
              CachedNetworkImage(
                imageUrl: episode.stillUrl!,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => _stillPlaceholder(),
              )
            else
              _stillPlaceholder(),
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'E${episode.number}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
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
          Icons.movie_outlined,
          color: Colors.white.withValues(alpha: 0.2),
          size: 28,
        ),
      ),
    );
  }
}
