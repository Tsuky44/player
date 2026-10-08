import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/server_capabilities.dart';

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
  });

  test('ce que le serveur annonce de lui-même', () {
    final info = ServerCapabilities.tryParse(_contract('ping'));
    expect(info, isNotNull);
    expect(info!.version, isNotEmpty);
    expect(info.playbackTicketVersion, 1);
    expect(info.supports(ServerCapabilities.progressLongPoll), isTrue);
    expect(info.supports(ServerCapabilities.mediaLanguage), isTrue);
    expect(info.supports(ServerCapabilities.watchedByCredits), isTrue);
    expect(info.supports('une_capacite_inconnue'), isFalse);

    // Un serveur d'avant cette annonce : il répond, sans rien promettre.
    final legacy = ServerCapabilities.tryParse({'status': 'ok', 'message': 'x'});
    expect(legacy!.version, isNull);
    expect(legacy.playbackTicketVersion, isNull);
    expect(legacy.capabilities, isEmpty);

    expect(ServerCapabilities.tryParse('<html>'), isNull);
    expect(ServerCapabilities.tryParse({'status': 'down'}), isNull);
  });

  // Ces deux réponses sont lues à la main, sans modèle : la clé est tout le
  // contrat.
  test('progression et jeton de révision', () {
    final progress = _contract('progress');
    expect(progress['current_position_seconds'], isA<int>());
    expect(progress['is_finished'], isA<bool>());

    expect(_contract('progress_revision')['revision'], isA<String>());
  });
}
