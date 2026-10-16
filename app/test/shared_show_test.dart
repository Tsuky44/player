import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_share.dart';
import 'package:onyx/models/shared_show.dart';
import 'package:onyx/services/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_doubles.dart';

/// Une série de deux saisons, telle qu'un lien la décrit.
const _show = SharedMediaInfo(
  mediaType: 'show',
  title: 'Lioness',
  subtitle: 'Série entière',
  posterUrl: '/show.jpg',
  episodes: [
    SharedEpisode(
        id: 11, seasonId: 2, seasonNumber: 1, episodeNumber: 1, duration: 3000),
    SharedEpisode(
        id: 12,
        seasonId: 2,
        seasonNumber: 1,
        episodeNumber: 2,
        duration: 3000,
        stillUrl: '/still.jpg',
        introStart: 30,
        introEnd: 90),
    SharedEpisode(
        id: 21, seasonId: 5, seasonNumber: 2, episodeNumber: 1, duration: 3000),
  ],
);

ResponseBody _json(Object body) => ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  // Comme sur la fiche d'un compte : on reprend l'épisode entamé, on passe au
  // suivant quand il est fini, et une série jamais ouverte part du premier.
  test('le bouton principal reprend là où le visiteur en est', () {
    int? resume(SharedLinkProgress progress) =>
        SharedShow(_show, progress).resumeEpisode?.media.id;

    expect(resume(const SharedLinkProgress()), 11, reason: 'jamais commencée');
    expect(SharedShow(_show).isResuming, isFalse);

    final started = SharedShow(
        _show,
        const SharedLinkProgress(
            positions: {12: 600}, finished: {11}, lastEpisodeId: 12));
    expect(started.resumeEpisode?.media.id, 12);
    expect(started.isResuming, isTrue);
    expect(started.resumeEpisode?.currentPositionSeconds, 600);

    expect(
        resume(const SharedLinkProgress(finished: {11, 12}, lastEpisodeId: 12)),
        21,
        reason: 'la saison finie mène à la suivante');
    expect(
        resume(const SharedLinkProgress(
            finished: {11, 12, 21}, lastEpisodeId: 21)),
        11,
        reason: 'tout est vu : on repart du début');
    expect(resume(const SharedLinkProgress(lastEpisodeId: 99)), 11,
        reason: 'un épisode disparu du lien ne bloque pas la reprise');
  });

  test('les épisodes sont rangés par saison et s’enchaînent de l’une à l’autre',
      () {
    final show = SharedShow(_show);
    expect(show.seasons.map((s) => s.id), [2, 5]);
    expect(show.seasons.map((s) => s.seasonNumber), [1, 2]);
    expect(show.episodesOf(2).map((e) => e.media.id), [11, 12]);
    expect(show.after(11)?.media.id, 12);
    expect(show.after(12)?.media.id, 21, reason: 'd’une saison à la suivante');
    expect(show.after(21), isNull);

    final second = show.episode(12)!;
    expect(second.media.posterUrl, '/still.jpg');
    expect(show.episode(11)!.media.posterUrl, '/show.jpg',
        reason: 'sans image propre, l’épisode montre l’affiche de la série');
    expect(second.showTitle, 'Lioness');
    expect(second.introEnd, 90);
  });

  // Un serveur plus ancien ne dit pas la saison d'un épisode.
  test('sans identifiant de saison, les épisodes se rangent par numéro', () {
    final show = SharedShow(const SharedMediaInfo(
      mediaType: 'show',
      title: 'Lioness',
      episodes: [
        SharedEpisode(id: 11, seasonNumber: 1, episodeNumber: 1),
        SharedEpisode(id: 21, seasonNumber: 2, episodeNumber: 1),
      ],
    ));
    expect(show.seasons, hasLength(2));
    expect(show.episodesOf(show.seasons.last.id).single.media.id, 21);
  });

  test('l’avancement du serveur se lit, et la lecture le fait avancer', () {
    var progress = SharedLinkProgress.fromJson({
      'name': 'Marie',
      'positions': {'12': 600},
      'finished': [11],
      'last_media_id': 12,
    });
    expect(progress.positions, {12: 600});
    expect(progress.finished, {11});
    expect(progress.lastEpisodeId, 12);

    progress = progress.recorded(12, positionSeconds: 2950, finished: true);
    expect(progress.positions, isEmpty,
        reason: 'un épisode fini perd sa position');
    expect(progress.finished, {11, 12});

    // Relancer un épisode vu le remet « en cours ».
    progress = progress.recorded(11, positionSeconds: 40, finished: false);
    expect(progress.finished, {12});
    expect(progress.positions, {11: 40});
    expect(progress.lastEpisodeId, 11);

    expect(SharedLinkProgress.fromJson(const {}).lastEpisodeId, isNull,
        reason: 'un spectateur qui n’a rien regardé');
  });

  // Le lecteur demande l'épisode suivant et son ticket au client du lien comme
  // il les demanderait à un compte (ADR-0037 §10).
  test('le lecteur invité enchaîne sur l’épisode suivant du lien', () async {
    SharedPreferences.setMockInitialValues({'onyx-share-name:AbC': 'Marie'});
    final opened = <int?>[];
    final progressed = <Map<String, dynamic>>[];
    final resumed = <String?>[];
    final dio = Dio()
      ..httpClientAdapter = Adapter((r) {
        final body = r.data as Map<String, dynamic>;
        expect(body['code'], 'AbC');
        switch (r.uri.path) {
          case '/api/shared/open':
            final id = body['media_id'] as int?;
            opened.add(id);
            return _json({
              'media': {'media_type': 'episode', 'title': 'Lioness'},
              'media_id': id,
              'ticket': 'ticket-$id',
              'expires_at': DateTime.now()
                  .add(const Duration(minutes: 15))
                  .toIso8601String(),
              'viewer': 'v',
            });
          case '/api/shared/progress':
            progressed.add(body);
            return _json({'consumed': false});
          case '/api/shared/resume':
            resumed.add(body['name'] as String?);
            return _json({'name': 'Marie', 'positions': {}, 'finished': []});
        }
        fail('route inattendue : ${r.uri.path}');
      });
    final api =
        SharedLinkApiClient('AbC', origin: 'https://ami.test', httpClient: dio);
    await api.describe(_show);

    final next = await api.getNextEpisode(11);
    expect(next.hasNext, isTrue);
    expect(next.episode?.media.id, 12);
    expect((await api.getNextEpisode(21)).hasNext, isFalse);
    expect((await api.getEpisodeTimestamps(12)).introEnd, 90);
    expect((await api.getShowSeasons(0)).map((s) => s.id), [2, 5]);
    expect((await api.getSeasonEpisodes(5)).single.media.id, 21);

    // La page ouvre le premier épisode ; le lecteur prend ce ticket-là.
    await api.open('', episodeId: 11);
    await api.openPlaybackAccess(11);
    expect(opened, [11]);

    // L'épisode suivant n'a pas de ticket : le client rouvre le lien pour lui.
    await api.openPlaybackAccess(12);
    expect(opened, [11, 12]);

    // L'ancien lecteur envoie encore sa dernière position pendant que le
    // nouveau démarre : chacun parle avec le ticket de son épisode.
    await api.sendProgress(
        mediaId: 11,
        currentPositionSeconds: 2900,
        duration: 3000,
        isFinished: true);
    await api.sendProgress(
        mediaId: 12,
        currentPositionSeconds: 5,
        duration: 3000,
        isFinished: false);
    expect(progressed.map((p) => (p['media_id'], p['ticket'], p['name'])),
        [(11, 'ticket-11', 'Marie'), (12, 'ticket-12', 'Marie')],
        reason: 'la position est rangée sous le prénom du spectateur');
    expect(resumed, ['Marie']);

    // Le lecteur suit la lecture sans redemander l'avancement au serveur.
    expect((await api.getProgress(11))['is_finished'], isTrue);
    expect((await api.getProgress(12))['current_position_seconds'], 5);
    expect(resumed, ['Marie']);
  });
}
