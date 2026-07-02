import 'package:flutter/material.dart';

import '../models/models.dart';
import '../screens/library/collection_screen.dart';
import '../screens/library/movie_detail_screen.dart';
import '../screens/library/person_detail_screen.dart';
import '../screens/library/show_detail_screen.dart';

/// Opens the actor/crew profile page for a TMDB person id.
void openPerson(BuildContext context, int? personTmdbId, {String? name}) {
  if (personTmdbId == null || personTmdbId <= 0) return;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PersonDetailScreen(personTmdbId: personTmdbId, initialName: name),
    ),
  );
}

/// Opens the saga/collection page.
void openCollection(BuildContext context, CollectionInfo collection) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => CollectionScreen(
        collectionId: collection.id,
        initialName: collection.name,
        initialBackdropUrl: collection.backdropUrl,
      ),
    ),
  );
}

/// Opens the detail page for a catalog item when it is owned; otherwise notifies
/// the user that the title is not in the library.
void openCatalogItem(BuildContext context, CatalogItem item) {
  if (!item.isOwned) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('« ${item.title} » n’est pas dans ta bibliothèque'),
        duration: const Duration(seconds: 2),
      ),
    );
    return;
  }

  final media = item.toLocalMedia();
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => item.mediaType == MediaType.show
          ? ShowDetailScreen(show: media)
          : MovieDetailScreen(movie: media),
    ),
  );
}
