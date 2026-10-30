import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_motion.dart';
import '../../../theme/app_type.dart';
import '../../../widgets/global/season_bubbles.dart';
import '../../../l10n/tr.dart';
import 'request_season_panel.dart';
import 'season_frame.dart';

/// Les saisons d'une demande : les bulles ([SeasonBubbleRow]) et un panneau
/// d'épisodes dessous. Toucher une bulle ouvre le panneau de sa saison, une
/// seule à la fois ; retoucher la saison ouverte replie le tout. C'est dans ce
/// panneau, et seulement là, qu'une saison se demande.
class RequestSeasonList extends StatefulWidget {
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
  State<RequestSeasonList> createState() => _RequestSeasonListState();
}

class _RequestSeasonListState extends State<RequestSeasonList> {
  int? _selected;

  /// Sens du dernier changement de saison (+1 vers la droite) : le contenu
  /// entrant glisse depuis ce côté.
  double _direction = 1;

  final _frameKey = GlobalKey();

  /// Abscisse, dans le cadre du panneau, du centre de la bulle ouverte.
  final _beamX = ValueNotifier<double?>(null);

  /// Épisodes déjà chargés par numéro de saison : passer d'une saison à
  /// l'autre ne refait pas d'appel réseau.
  final Map<int, List<RequestEpisode>> _cache = {};

  @override
  void dispose() {
    _beamX.dispose();
    super.dispose();
  }

  void _select(int number) {
    final previous = _selected;
    setState(() {
      if (previous != null && previous != number) {
        _direction = number > previous ? 1 : -1;
      }
      _selected = previous == number ? null : number;
    });
  }

  /// Tout ce que MediaHub attend encore, même en partie : le sablier.
  static bool _isRequested(RequestMediaStatus status) =>
      status == RequestMediaStatus.pending ||
      status == RequestMediaStatus.processing ||
      status == RequestMediaStatus.partial;

  SeasonBubbleEntry _entry(RequestSeason season) {
    final title = seasonTitle(season);
    final count = tr('{0} épisodes', [season.episodeCount]);
    final year = season.year;
    return SeasonBubbleEntry(
      id: season.number,
      code: season.number == 0 ? 'SP' : '${season.number}',
      title: title,
      detail: year == null ? count : '$count · $year',
      semanticLabel: '$title, $count',
      posterUrl: season.posterUrl,
      requested: _isRequested(season.status),
      missing: season.status.canRequest,
      missingBadge: true,
      tooltip: '$title · $count',
    );
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.seasons]
      ..sort((a, b) => a.number.compareTo(b.number));
    final selected = sorted.where((s) => s.number == _selected).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Saisons'),
          style: TextStyle(
            fontSize: AppType.title2,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 10),
        SeasonBubbleRow(
          entries: [for (final season in sorted) _entry(season)],
          selected: _selected,
          onTap: _select,
          frameKey: _frameKey,
          beamX: _beamX,
        ),
        const SizedBox(height: 4),
        SeasonSizeTween(
          duration: AppMotion.emphasis,
          curve: AppMotion.curve,
          alignment: Alignment.topCenter,
          child: selected == null
              ? const SizedBox(width: double.infinity)
              : SeasonFrame(
                  key: _frameKey,
                  beamX: _beamX,
                  direction: _direction,
                  child: RequestSeasonPanel(
                    key: ValueKey(selected.number),
                    tmdbId: widget.tmdbId,
                    showItem: widget.showItem,
                    season: selected,
                    cache: _cache,
                  ),
                ),
        ),
      ],
    );
  }
}
