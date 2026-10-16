import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../navigation/search_route_observer.dart';
import '../../providers/home_provider.dart';
import '../../providers/library_provider.dart';
import '../player/player_screen.dart';

/// Ce qu'on fait d'un épisode depuis la fiche d'une série ou la page d'une
/// saison : le lancer, le cocher vu. Les deux pages font le même geste, avec
/// les mêmes relectures derrière.

/// Lance [episode], en demandant d'abord laquelle quand il en existe plusieurs
/// versions. [siblings] est la liste affichée : un épisode venu du bouton de
/// reprise n'y porte pas ses versions, la ligne de la liste si.
Future<void> playShowEpisode(
  BuildContext context,
  HomeMediaItem episode, {
  required List<HomeMediaItem> siblings,
  int? seasonNumber,
}) async {
  var versions = episode.media.versions;
  if (versions.isEmpty) {
    for (final item in siblings) {
      if (item.media.id == episode.media.id ||
          item.media.versions.any((v) => v.item.media.id == episode.media.id)) {
        versions = item.media.versions;
        break;
      }
    }
  }
  if (versions.length > 1) {
    final chosen = await _pickVersion(context, versions);
    if (chosen == null || !context.mounted) return;
    episode = chosen.item;
  }
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(
      settings: const RouteSettings(
        name: SearchRouteObserver.playerRouteName,
      ),
      builder: (_) => PlayerScreen(
        media: episode,
        seasonNumber: seasonNumber,
      ),
    ),
  );
}

Future<MediaVersion?> _pickVersion(
  BuildContext context,
  List<MediaVersion> versions,
) {
  var selected = versions.first;
  return showDialog<MediaVersion>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(tr('Choisir une version')),
        content: SizedBox(
          width: 480,
          child: DropdownButtonFormField<int>(
            initialValue: selected.item.media.id,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('Version')),
            items: versions
                .map((v) => DropdownMenuItem(
                      value: v.item.media.id,
                      child: Text(v.label, overflow: TextOverflow.ellipsis),
                    ))
                .toList(),
            onChanged: (id) => update(() {
              selected = versions.firstWhere((v) => v.item.media.id == id);
            }),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: Text(tr('Lecture'))),
        ],
      ),
    ),
  );
}

/// Coche ou décoche un épisode. Faux en cas d'échec, déjà dit à l'écran.
Future<bool> setEpisodeWatched(
  BuildContext context,
  HomeMediaItem episode,
  bool watched,
) async {
  final library = Provider.of<LibraryProvider>(context, listen: false);
  final home = Provider.of<HomeProvider>(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  try {
    await library.setMediaWatched(episode.media.id, watched);
    await home.loadHome(silent: true);
    // La pastille de la grille des séries compte les épisodes vus côté
    // serveur : elle ne bouge que si la liste est relue.
    await library.loadShows(silent: true);
    return true;
  } catch (_) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('Impossible de mettre à jour le statut'))),
    );
    return false;
  }
}

/// Toute la saison d'un coup, dans un sens ou dans l'autre.
///
/// Le serveur tranche en une requête, puis l'accueil et la grille des séries
/// sont relus une seule fois : vingt rafraîchissements pour un seul geste ne
/// montreraient rien de plus. Faux en cas d'échec, déjà dit à l'écran.
Future<bool> setSeasonEpisodesWatched(
  BuildContext context,
  List<HomeMediaItem> episodes,
  bool watched,
) async {
  final library = Provider.of<LibraryProvider>(context, listen: false);
  final home = Provider.of<HomeProvider>(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final changed = await library.setMediasWatched(
      [for (final episode in episodes) episode.media.id],
      watched,
    );
    await home.loadHome(silent: true);
    await library.loadShows(silent: true);
    final plural = changed > 1 ? 's' : '';
    messenger.showSnackBar(SnackBar(
      content: Text(watched
          ? tr('{0} épisode{1} marqué{2} vu{3}', [changed, plural, plural, plural])
          : tr('Saison marquée non vue')),
    ));
    return true;
  } catch (_) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('Impossible de mettre à jour la saison'))),
    );
    return false;
  }
}
