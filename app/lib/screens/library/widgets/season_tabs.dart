import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../../../utils/poster_url.dart';
import '../../../widgets/global/season_bubbles.dart';
import '../../../l10n/tr.dart';
import 'season_preview.dart';

/// « Saison 1 », « Saison 2 »… tel que la fiche l'écrit partout.
String seasonLabel(Media season) {
  final number = season.effectiveSeasonNumber;
  return number != null && number > 0 ? tr('Saison {0}', [number]) : season.title;
}

/// Les saisons d'une série, en bulles ([SeasonBubbleRow]) comme sur la fiche
/// d'une demande. Une saison demandée porte un sablier orange, une saison là
/// ne porte rien. Une saison absente se reconnaît à son numéro effacé, et se
/// demande en la dépliant.
///
/// Sur un téléviseur, la rangée se souvient de la bulle où était la
/// télécommande.
///
/// Avec [onOpen], la souris laissée sur une bulle ouvre la fiche de la saison
/// ([SeasonHoverPreview]), d'où un clic mène à sa page.
class SeasonTabs extends StatelessWidget {
  final List<Media> seasons;

  /// Nulle : toutes les saisons sont repliées.
  final Media? selected;
  final ValueChanged<Media> onSelected;
  final ValueChanged<Media>? onOpen;

  /// Affiche de la série, pour la fiche d'une saison sans affiche propre.
  final String? fallbackPosterUrl;

  const SeasonTabs({
    super.key,
    required this.seasons,
    required this.selected,
    required this.onSelected,
    this.onOpen,
    this.fallbackPosterUrl,
  });

  @override
  Widget build(BuildContext context) {
    final baseUrl = Provider.of<ApiClient>(context, listen: false).baseUrl;
    final open = onOpen;
    final selectedIndex = seasons.indexWhere((s) => identical(s, selected));
    return SeasonBubbleRow(
      entries: [
        for (var i = 0; i < seasons.length; i++)
          _entry(i, seasons[i], baseUrl),
      ],
      selected: selectedIndex < 0 ? null : selectedIndex,
      onTap: (index) => onSelected(seasons[index]),
      wrap: open == null
          ? null
          : (entry, bubble) => SeasonHoverPreview(
                season: seasons[entry.id],
                fallbackPosterUrl: fallbackPosterUrl,
                onOpen: () => open(seasons[entry.id]),
                child: bubble,
              ),
    );
  }

  SeasonBubbleEntry _entry(int index, Media season, String? baseUrl) {
    final number = season.effectiveSeasonNumber;
    final label = seasonLabel(season);
    final count = season.episodeCount;
    final poster = season.posterUrl;
    final state = season.isAvailable
        ? label
        : season.isRequested
            ? tr('{0} · demandée', [label])
            : '$label · manquante';
    return SeasonBubbleEntry(
      // La place dans la rangée et non l'id : une saison virtuelle a l'id 0.
      id: index,
      code: number != null && number > 0 ? '$number' : 'SP',
      title: label,
      detail: count != null && count > 0 ? tr('{0} épisodes', [count]) : '',
      semanticLabel: state,
      posterUrl: cardPosterUrl(
        poster != null && poster.isNotEmpty ? poster : fallbackPosterUrl,
        serverBaseUrl: baseUrl,
      ),
      requested: season.isRequested,
      missing: !season.isAvailable && !season.isRequested,
      // L'aperçu au survol dit déjà tout ça, quand la rangée en a un.
      tooltip: onOpen != null ? null : state,
    );
  }
}
