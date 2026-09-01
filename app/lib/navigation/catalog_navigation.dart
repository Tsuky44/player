import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_request.dart';
import '../models/models.dart';
import '../providers/auth_provider.dart';
import '../screens/library/collection_screen.dart';
import '../screens/library/movie_detail_screen.dart';
import '../screens/library/person_detail_screen.dart';
import '../screens/library/show_detail_screen.dart';
import '../screens/requests/request_detail_screen.dart';
import '../utils/poster_url.dart';

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

/// Opens the detail page for a catalog item when it is owned; otherwise sends
/// the user to the request page for that title.
void openCatalogItem(BuildContext context, CatalogItem item) {
  if (!item.isOwned) {
    _openRequestFor(context, item);
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

/// A filmography or saga entry the library does not have opens the MediaHub
/// request page, so a missing title can be asked for where it was spotted.
/// Without the request permission — or without a TMDB id to look it up with —
/// it falls back to telling the user the title is absent.
void _openRequestFor(BuildContext context, CatalogItem item) {
  final canRequest =
      context.read<AuthProvider>().permissions.requestMedia;
  if (!canRequest || item.tmdbId <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('« ${item.title} » n’est pas dans ta bibliothèque'),
        duration: const Duration(seconds: 2),
      ),
    );
    return;
  }

  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => RequestDetailScreen(item: _asRequestItem(item)),
    ),
  );
}

/// The request page reloads everything from TMDB by id and media type; the
/// other fields only matter for the request payload the season list sends.
RequestMediaItem _asRequestItem(CatalogItem item) {
  return RequestMediaItem(
    id: item.tmdbId,
    mediaType: item.mediaType == MediaType.show
        ? RequestMediaType.tv
        : RequestMediaType.movie,
    title: item.title,
    overview: '',
    posterPath: _tmdbImagePath(item.posterUrl),
    backdropPath: _tmdbImagePath(item.backdropUrl),
    releaseDate: item.year,
    rating: item.rating,
    status: RequestMediaStatus.unknown,
  );
}

final RegExp _tmdbImagePathPattern =
    RegExp(r'/t/p/(?:original|[wh]\d+)(/[^/?]+)');

/// Catalog artwork arrives as a full TMDB URL, the request API wants the bare
/// path. Artwork served by our own host has no TMDB path and is dropped.
String? _tmdbImagePath(String? url) {
  if (url == null || url.isEmpty || !isTmdbImageUrl(url)) return null;
  return _tmdbImagePathPattern.firstMatch(url)?.group(1);
}
