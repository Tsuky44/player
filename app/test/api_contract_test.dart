import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/announcement.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/watch_list.dart';
import 'package:onyx/models/server_capabilities.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/models/my_request.dart';
import 'package:onyx/models/request_feed.dart';
import 'package:onyx/services/api_types.dart';

/// Le contrat entre le serveur et l'app, vu de l'app.
///
/// Les fichiers de `contract/`, à la racine du dépôt, sont ce que le serveur
/// écrit pour chaque réponse, tous champs remplis — `server/handlers/
/// contract_test.go` les tient à jour et échoue s'ils s'écartent du Go. Ici,
/// les `fromJson` de l'app les relisent : une clé renommée côté serveur, ou
/// un champ que l'app lit sous un autre nom, se voit dans ce test au lieu de
/// se lire `null` en silence sur un écran.
///
/// Les valeurs attendues viennent du générateur : un texte vaut
/// `<clé>-value`, sauf les énumérations et les dates.
Map<String, dynamic> _contract(String name) {
  final file = File('../contract/$name.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  test('accueil : chaque rangée et les champs d\'une fiche', () {
    final home = HomeResponse.fromJson(_contract('home'));

    expect(home.continueWatching, hasLength(1));
    expect(home.recentMovies, hasLength(1));
    expect(home.recentShows, hasLength(1));
    expect(home.discoveryMovies, hasLength(1));
    expect(home.discoveryShows, hasLength(1));

    final item = home.continueWatching.single;
    expect(item.media.id, greaterThan(0));
    expect(item.media.title, 'title-value');
    expect(item.media.type, MediaType.episode);
    expect(item.media.posterUrl, 'poster_url-value');
    expect(item.media.overview, 'overview-value');
    expect(item.media.seasonNumber, greaterThan(0));
    expect(item.media.episodeNumber, greaterThan(0));
    expect(item.currentPositionSeconds, greaterThan(0));
    expect(item.duration, greaterThan(0));
    expect(item.isFinished, isTrue);
    expect(item.showTitle, 'show_title-value');
    expect(item.showPosterUrl, 'show_poster_url-value');
    expect(item.showId, greaterThan(0));
    expect(item.episodeTitle, 'episode_title-value');
    expect(item.updatedAt, isNotNull);
    expect(item.hasNewEpisode, isTrue);
    expect(item.outroStart, greaterThan(0));

    expect(home.recentMovies.single.title, 'title-value');

    // La rangée d'une bibliothèque, sous le nom que le serveur lui donne.
    final row = home.libraries.single;
    expect(row.id, greaterThan(0));
    expect(row.name, 'name-value');
    expect(row.kind, LibraryKind.shows);
    expect(row.items.single.title, 'title-value');
  });

  test('fiche détaillée', () {
    final details = MediaDetails.fromJson(_contract('media_details'));

    expect(details.id, greaterThan(0));
    expect(details.tmdbId, greaterThan(0));
    expect(details.title, 'title-value');
    expect(details.originalTitle, 'original_title-value');
    expect(details.tagline, 'tagline-value');
    expect(details.overview, 'overview-value');
    expect(details.posterUrl, 'poster_url-value');
    expect(details.backdropUrl, 'backdrop_url-value');
    expect(details.logoUrl, 'logo_url-value');
    expect(details.releaseDate, '2020-01-02');
    expect(details.runtime, greaterThan(0));
    expect(details.duration, greaterThan(0));
    expect(details.voteAverage, greaterThan(0));
    expect(details.genres, ['genres-value']);
    expect(details.studios, ['studios-value']);
    expect(details.countries, ['countries-value']);
    expect(details.originalLanguage, 'original_language-value');
    expect(details.versions, hasLength(1));
    expect(details.versions.single.label, 'label-value');
  });

  test('épisode suivant, avec ses deux cartes de fin', () {
    final next = NextEpisodeResponse.fromJson(_contract('next_episode'));

    expect(next.hasNext, isTrue);
    expect(next.episode?.media.title, 'title-value');
    expect(next.episodeAudioLangs, ['episode_audio_langs-value']);
    expect(next.nextSeason, isNotNull);
    expect(next.upcomingEpisode, isNotNull);

    final none = NextEpisodeResponse.fromJson(_contract('next_episode_none'));
    expect(none.hasNext, isFalse);
    expect(none.episode, isNull);
    expect(none.nextSeason, isNull);
    expect(none.upcomingEpisode, isNull);
  });

  test('épisode à reprendre', () {
    final resume = ShowResumeResponse.fromJson(_contract('show_resume'));
    expect(resume.hasEpisode, isTrue);
    expect(resume.seasonId, greaterThan(0));
    expect(resume.episode?.media.title, 'title-value');

    final none = ShowResumeResponse.fromJson(_contract('show_resume_none'));
    expect(none.hasEpisode, isFalse);
    expect(none.seasonId, isNull);
    expect(none.episode, isNull);
  });

  test('repères d\'intro et de générique', () {
    final stamps = EpisodeTimestamps.fromJson(_contract('episode_timestamps'));
    expect(stamps.introStart, greaterThan(0));
    expect(stamps.introEnd, greaterThan(0));
    expect(stamps.outroStart, greaterThan(0));
    expect(stamps.outroEnd, greaterThan(0));
  });

  test('pistes et échelle de qualité', () {
    final tracks = MediaTracks.fromJson(_contract('media_tracks'));
    expect(tracks.video, isNotNull);
    expect(tracks.audio, hasLength(1));
    expect(tracks.subtitles, hasLength(1));
    expect(tracks.qualities, hasLength(1),
        reason: 'une marche sans `key` ni `label` est écartée par l\'app');
    expect(tracks.sourceBitrateBps, greaterThan(0),
        reason: 'la qualité automatique choisit ses barreaux contre ce débit');
    expect(tracks.activeArea, isNotNull,
        reason: 'les modes d\'affichage zooment sur la zone utile (ADR-0067)');
  });

  test('ce que le serveur annonce de lui-même', () {
    final info = ServerCapabilities.tryParse(_contract('ping'));
    expect(info, isNotNull);
    expect(info!.version, isNotEmpty);
    expect(info.playbackTicketVersion, 1);
    expect(info.supports(ServerCapabilities.progressLongPoll), isTrue);
    expect(info.supports(ServerCapabilities.mediaLanguage), isTrue);
    expect(info.supports(ServerCapabilities.watchedByCredits), isTrue);
    expect(info.supports(ServerCapabilities.libraries), isTrue);
    expect(info.supports(ServerCapabilities.announcements), isTrue);
    expect(info.supports('une_capacite_inconnue'), isFalse);

    // Un serveur d'avant cette annonce : il répond, sans rien promettre.
    final legacy =
        ServerCapabilities.tryParse({'status': 'ok', 'message': 'x'});
    expect(legacy!.version, isNull);
    expect(legacy.playbackTicketVersion, isNull);
    expect(legacy.capabilities, isEmpty);

    expect(ServerCapabilities.tryParse('<html>'), isNull);
    expect(ServerCapabilities.tryParse({'status': 'down'}), isNull);
  });

  test('message de l’administrateur, et son absence', () {
    final announcement =
        ServerAnnouncement.fromEnvelope(_contract('announcement'));
    expect(announcement, isNotNull);
    expect(announcement!.id, isPositive);
    expect(announcement.title, 'title-value');
    expect(announcement.message, 'message-value');
    expect(announcement.createdAt, isNotNull);

    expect(ServerAnnouncement.fromEnvelope(_contract('announcement_none')),
        isNull);
  });

  test('affiches proposées pour une fiche', () {
    expect(
      ServerCapabilities.tryParse(_contract('ping'))!
          .supports(ServerCapabilities.posterPicker),
      isTrue,
    );

    final posters = RemotePosters.fromJson(_contract('remote_posters'));
    expect(posters.current, 'current-value');
    expect(posters.locked, isTrue);
    expect(posters.fanartEnabled, isTrue);
    final poster = posters.images.single;
    expect(poster.url, 'url-value');
    expect(poster.thumbUrl, 'thumb_url-value');
    expect(poster.source, 'source-value');
    expect(poster.language, 'language-value');
    expect(poster.width, isPositive);
    expect(poster.height, isPositive);
    expect(poster.rating, isPositive);
    expect(poster.votes, isPositive);
  });

  test('listes : les miennes, celles des autres, et leur contenu', () {
    expect(
      ServerCapabilities.tryParse(_contract('ping'))!
          .supports(ServerCapabilities.watchLists),
      isTrue,
    );

    final overview = WatchListsOverview.fromJson(_contract('watch_lists'));
    final later = overview.mine.single;
    expect(later.kind, WatchListKind.watchLater);
    expect(later.name, 'name-value');
    expect(later.description, 'description-value');
    expect(later.isShared, isTrue);
    expect(later.isMine, isTrue);
    expect(later.owner.id, isPositive);
    expect(later.owner.username, 'username-value');
    expect(later.itemCount, isPositive);
    expect(later.posters, ['posters-value']);
    expect(later.updatedAt, isNotNull);
    expect(later.containsItemId, isPositive);
    expect(overview.shared.single.kind, WatchListKind.custom);

    final detail = WatchListDetail.fromJson(_contract('watch_list'));
    expect(detail.list.kind, WatchListKind.custom);
    final item = detail.items.single;
    expect(item.id, isPositive);
    expect(item.mediaType, WatchListMediaType.show);
    expect(item.tmdbId, isPositive);
    expect(item.title, 'title-value');
    expect(item.posterUrl, 'poster_url-value');
    expect(item.releaseDate, '2020-01-02');
    expect(item.addedAt, isNotNull);
    expect(item.mediaId, isPositive);
    expect(item.media, isNotNull);
    expect(item.media!.media.id, isPositive);

    final added = WatchListItem.fromJson(_contract('watch_list_item'));
    expect(added.mediaType, WatchListMediaType.movie);
    expect(added.isOnServer, isTrue);
  });

  // Ces deux réponses sont lues à la main, sans modèle : la clé est tout le
  // contrat.
  test('progression et jeton de révision', () {
    final progress = _contract('progress');
    expect(progress['current_position_seconds'], isA<int>());
    expect(progress['is_finished'], isA<bool>());

    expect(_contract('progress_revision')['revision'], isA<String>());
  });

  // Les réponses d'OnyxHub que l'app lit, relayées par le serveur (ADR-0075).
  // OnyxHub relit les mêmes fichiers : un format qui change d'un côté casse
  // l'autre test.
  test('OnyxHub : mes demandes et le test de liaison', () {
    final requests = (_contract('onyxhub/my_requests')['requests'] as List)
        .map((e) => MyRequest.fromJson(e as Map<String, dynamic>))
        .toList();
    expect(requests, hasLength(2));
    expect(requests.first.mediaType, RequestMediaType.tv);
    expect(requests.first.seasons, [1, 2]);
    expect(requests.first.status, MyRequestStatus.processing);
    expect(requests.first.progress, 42.5);
    expect(requests.first.requestedAt, isNotNull);
    expect(requests.last.status, MyRequestStatus.available);
    expect(requests.last.progress, isNull);

    final link =
        MediaHubLinkTest.fromJson(_contract('onyxhub/mediahub_link_test'));
    expect(link.ok, isTrue);
    expect(link.message, contains('OnyxHub'));

    final feed = RequestFeed.fromJson(_contract('onyxhub/request_feed'));
    expect(feed.cursor, 42);
    expect(feed.requests.map((e) => e.mediaType),
        [RequestMediaType.movie, RequestMediaType.tv]);
    expect(feed.requests.last.seasons, [1, 2]);
    expect(feed.requests.last.requester, 'hugo');
    expect(feed.requests.first.requestedAt, isNotNull);
  });

  // Ce que le serveur rend à l'app depuis MediaHub (ADR-0087) : des lots de
  // demandes, le flux des nouvelles demandes et les droits du compte.
  test('MediaHub : lots de demandes, flux, droits et test de liaison', () {
    final lot = MyRequest.fromJson(
        (_contract('requests_mine')['requests'] as List).single
            as Map<String, dynamic>);
    expect(lot.requestIds, isNotEmpty);
    expect(lot.mediaType, RequestMediaType.tv);
    expect(lot.status, MyRequestStatus.partial);
    expect(lot.seasonStatuses.single.status, MyRequestStatus.available);
    expect(lot.waitingMessage, isNotNull);
    expect(lot.note, isNotNull);
    expect(lot.requester, isNotNull);
    expect(lot.progress, isNotNull);

    final feed = RequestFeed.fromJson(_contract('requests_feed'));
    expect(feed.requests.single.mediaType, RequestMediaType.tv);
    expect(feed.requests.single.requester, isNotEmpty);

    final access = RequestAccess.fromJson(_contract('requests_access'));
    expect(access.service, 'mediahub');
    expect(access.linked, isTrue);
    expect(access.canModerate && access.canReadAll && access.canDelete, isTrue);

    final link = MediaHubLinkTest.fromJson(_contract('mediahub_link_test'));
    expect(link.ok, isTrue);
    expect(link.notes, isNotEmpty);

    // Ouvrir MediaHub déjà connecté (ADR-0088).
    expect(
        ServerCapabilities.tryParse(_contract('ping'))!
            .supports(ServerCapabilities.mediaHubSso),
        isTrue);
    final ticket = MediaHubTicket.fromJson(_contract('mediahub_sso'));
    expect(ticket.url, isNotEmpty);
    expect(ticket.expiresIn, greaterThan(0));
  });
}
