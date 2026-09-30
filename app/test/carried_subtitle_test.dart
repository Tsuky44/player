import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/playback/carried_subtitle.dart';

/// Le sous-titre choisi dans un épisode doit être le même dans le suivant. Les
/// clés (`fr`, `fr2`) suivent l'ordre de chaque fichier : un épisode réglé en
/// « French Forced » repassait en French complet dès que l'ordre changeait, ou
/// simplement parce que la piste complète était préférée d'office.
void main() {
  MediaSubtitleTrack sub(
    String lang, {
    String language = 'fr',
    bool forced = false,
    bool image = false,
  }) =>
      MediaSubtitleTrack(
        lang: lang,
        name: lang,
        language: language,
        forced: forced,
        image: image,
      );

  final fullFr = sub('fr');
  final forcedFr = sub('fr2', forced: true);

  test('une piste forcée choisie reste forcée à l\'épisode suivant', () {
    final wanted = CarriedSubtitle.of(forcedFr);
    final next = [sub('fr'), sub('fr2', forced: true), sub('en', language: 'en')];

    expect(wanted.matchIn(next)?.lang, 'fr2');
  });

  test('la piste forcée est retrouvée même quand l\'ordre du fichier change',
      () {
    final wanted = CarriedSubtitle.of(forcedFr);
    final next = [sub('fr', forced: true), sub('fr2')];

    expect(wanted.matchIn(next)?.lang, 'fr');
  });

  test('une piste complète choisie ne devient pas la forcée', () {
    final wanted = CarriedSubtitle.of(fullFr);
    final next = [sub('fr', forced: true), sub('fr2')];

    expect(wanted.matchIn(next)?.lang, 'fr2');
  });

  test('sans piste forcée dans l\'épisode, rien plutôt que la complète', () {
    final wanted = CarriedSubtitle.of(forcedFr);

    expect(wanted.matchIn([sub('fr'), sub('en', language: 'en')]), isNull);
  });

  test('une piste image se retrouve par sa langue, pas par son rang', () {
    final wanted = CarriedSubtitle.of(
        sub('img3', language: 'fr', forced: true, image: true));
    final next = [
      sub('img1', language: 'en', forced: true, image: true),
      sub('img2', language: 'fr', image: true),
      sub('img4', language: 'fr', forced: true, image: true),
    ];

    expect(wanted.matchIn(next)?.lang, 'img4');
  });

  test('à langue et type égaux, la même clé l\'emporte', () {
    final wanted = CarriedSubtitle.of(sub('fr2'));
    final next = [sub('fr'), sub('fr2')];

    expect(wanted.matchIn(next)?.lang, 'fr2');
  });

  test('un serveur sans langue : elle se déduit de la clé d\'une piste texte',
      () {
    final wanted = CarriedSubtitle.fromKey('fr2');
    final next = [
      MediaSubtitleTrack(lang: 'en', name: 'en'),
      MediaSubtitleTrack(lang: 'fr', name: 'fr'),
    ];

    expect(wanted.language, 'fr');
    expect(wanted.matchIn(next)?.lang, 'fr');
  });
}
