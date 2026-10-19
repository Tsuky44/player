import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/widgets/global/poster_picker_sheet.dart';

/// Le choix d'affiche (ADR-0068) : ce que la feuille montre, et ce qu'elle
/// demande au serveur d'enregistrer.
class _PosterApi extends ApiClient {
  _PosterApi(this.posters);

  final RemotePosters? posters;
  String? saved;
  bool reset = false;

  @override
  Future<RemotePosters?> getRemotePosters(int mediaId) async => posters;

  @override
  Future<Media> setMediaPoster(int mediaId, String posterUrl) async {
    saved = posterUrl;
    return _movie.copyWithPoster(posterUrl);
  }

  @override
  Future<Media> resetMediaPoster(int mediaId) async {
    reset = true;
    return _movie;
  }
}

final _movie = Media(
  id: 7,
  type: MediaType.movie,
  title: 'Dune',
  duration: 0,
  createdAt: DateTime(2026),
);

extension on Media {
  Media copyWithPoster(String url) => Media(
        id: id,
        type: type,
        title: title,
        duration: duration,
        posterUrl: url,
        createdAt: createdAt,
      );
}

const _current = 'https://image.tmdb.org/t/p/w500/current.jpg';
const _fanart = 'https://assets.fanart.tv/fanart/movies/1/movieposter/b.jpg';

RemotePosters _offer({bool locked = false, bool fanartEnabled = true}) =>
    RemotePosters(
      current: _current,
      locked: locked,
      fanartEnabled: fanartEnabled,
      images: const [
        RemotePoster(
            url: _current,
            thumbUrl: _current,
            source: 'tmdb',
            language: 'fr'),
        RemotePoster(url: _fanart, thumbUrl: _fanart, source: 'fanart'),
      ],
    );

Future<void> _pump(WidgetTester tester, ApiClient api,
    void Function(Media?) onResult) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => onResult(await PosterPickerSheet.pickAndApply(
              context,
              api: api,
              media: _movie)),
          child: const Text('ouvrir'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('l’affiche actuelle est marquée, et un choix est enregistré',
      (tester) async {
    final api = _PosterApi(_offer());
    Media? result;
    await _pump(tester, api, (m) => result = m);

    expect(find.bySemanticsLabel(RegExp('^Affiche actuelle, TMDB · FR')),
        findsOneWidget);
    // Les deux sources sont présentes : on peut n'en garder qu'une.
    expect(find.text('Fanart.tv'), findsOneWidget);
    // Sans marque posée, il n'y a pas d'affiche par défaut à rétablir.
    expect(find.text('Affiche par défaut'), findsNothing);

    await tester.tap(
        find.bySemanticsLabel(RegExp('^Choisir cette affiche, Fanart.tv')));
    await tester.pumpAndSettle();

    expect(api.saved, _fanart);
    expect(result?.posterUrl, _fanart);
    expect(find.text('Affiche mise à jour'), findsOneWidget);
  });

  testWidgets('une affiche choisie à la main peut revenir à celle de TMDB',
      (tester) async {
    final api = _PosterApi(_offer(locked: true));
    await _pump(tester, api, (_) {});

    await tester.tap(find.text('Affiche par défaut'));
    await tester.pumpAndSettle();

    expect(api.reset, isTrue);
    expect(api.saved, isNull);
  });

  testWidgets('sans clé Fanart.tv, la feuille dit où en ajouter une',
      (tester) async {
    await _pump(tester, _PosterApi(_offer(fanartEnabled: false)), (_) {});
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.textContaining('clé Fanart.tv'), findsOneWidget);
  });

  testWidgets('un serveur trop ancien est dit, sans grille vide',
      (tester) async {
    await _pump(tester, _PosterApi(null), (_) {});
    expect(find.text('Serveur à mettre à jour'), findsOneWidget);
  });
}
