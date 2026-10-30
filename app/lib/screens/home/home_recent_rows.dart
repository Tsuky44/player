import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../widgets/global/interface_tour/tour_anchor.dart';
import '../../widgets/global/media_row.dart';

/// Une rangée de derniers ajouts de l'accueil.
typedef _RecentRow = ({String title, List<Media> items, VoidCallback? onSeeAll});

/// Les rangées de derniers ajouts de l'accueil, en slivers.
///
/// Une par bibliothèque, sous le nom que son administrateur lui a donné
/// (ADR-0058) : l'app n'écrit plus le titre d'aucune rangée. « Tout voir »
/// ouvre l'onglet de la bibliothèque.
///
/// Un serveur d'avant les bibliothèques ne les envoie pas : il garde ses deux
/// rangées, films et séries, comme ses deux onglets ([MediaLibrary.legacy]).
List<Widget> homeRecentSlivers({
  required HomeResponse data,
  required bool isTv,
  required void Function(int libraryId)? onOpenLibrary,
  required VoidCallback? onSeeAllMovies,
  required VoidCallback? onSeeAllShows,
}) {
  final List<_RecentRow> rows = data.libraries.isNotEmpty
      ? [
          for (final library in data.libraries)
            (
              title: tr('Derniers ajouts · {0}', [library.name]),
              items: library.items,
              onSeeAll: onOpenLibrary == null
                  ? null
                  : () => onOpenLibrary(library.id),
            ),
        ]
      : [
          (
            title: tr('Films récents'),
            items: data.recentMovies,
            onSeeAll: onSeeAllMovies,
          ),
          (
            title: tr('Séries récentes'),
            items: data.recentShows,
            onSeeAll: onSeeAllShows,
          ),
        ];

  final slivers = <Widget>[];
  var first = true;
  for (final row in rows) {
    if (row.items.isEmpty) continue;
    // La première rangée de l'écran, quand il n'y a rien à reprendre : c'est
    // elle qui reçoit la télécommande et que la présentation montre. Sinon
    // c'est « Reprendre » qui dit ce qu'il y a à dire des rangées.
    final leads = first && data.continueWatching.isEmpty;
    first = false;
    final mediaRow = MediaRow(
      title: row.title,
      items: row.items,
      autofocusFirstItem: !isTv && leads,
      onSeeAll: row.onSeeAll,
    );
    slivers
      ..add(const SliverToBoxAdapter(child: SizedBox(height: 32)))
      ..add(SliverToBoxAdapter(
        child: leads
            ? TourTarget(anchor: TourAnchor.recent, child: mediaRow)
            : mediaRow,
      ));
  }
  return slivers;
}
