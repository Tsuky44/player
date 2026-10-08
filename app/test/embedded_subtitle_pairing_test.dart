import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/playback/embedded_subtitle_pairing.dart';
import 'package:onyx/screens/player/playback/playback_session.dart';

/// Un sous-titre choisi en Direct Play doit avoir une clé canonique sur chaque
/// moteur : sans elle il n'est ni retenu pour la série (ADR-0044), ni retrouvé
/// à l'épisode suivant. ExoPlayer ne numérote pas ses pistes comme mpv, et
/// c'est ce qui laissait Android sans suivi.
void main() {
  MediaSubtitleTrack sub(String lang, int typedIndex, {String? language}) =>
      MediaSubtitleTrack(
        lang: lang,
        name: lang,
        typedIndex: typedIndex,
        language: language ?? lang.replaceAll(RegExp(r'\d+$'), ''),
      );

  const off = PlaybackTrack(id: 'no');
  final canonical = [sub('fr', 0), sub('fr2', 1), sub('en', 2)];

  test('mpv : le numéro de piste désigne l\'index typé du serveur', () {
    const engine = [
      off,
      PlaybackTrack(id: '1', language: 'fre'),
      PlaybackTrack(id: '2', language: 'fre'),
      PlaybackTrack(id: '3', language: 'eng'),
    ];
    final pairing = EmbeddedSubtitlePairing.of(engine, canonical);

    expect(pairing.keyOf(engine[2]), 'fr2');
    expect(pairing.trackFor('en'), engine[3]);
    expect(pairing.keyOf(off), isNull);
  });

  test('ExoPlayer : une piste désignée par groupe garde sa clé canonique', () {
    const engine = [
      PlaybackTrack(id: '0:0', language: 'fr'),
      PlaybackTrack(id: '1:0', language: 'fr'),
      PlaybackTrack(id: '2:0', language: 'en'),
    ];
    final pairing = EmbeddedSubtitlePairing.of(engine, canonical);

    expect(pairing.keyOf(engine[1]), 'fr2');
    expect(pairing.trackFor('fr2'), engine[1]);
    expect(pairing.trackFor('en'), engine[2]);
  });

  test(
      'ExoPlayer : quand il liste moins de pistes que le serveur, la langue '
      'et son rang désignent la piste', () {
    final withImage = [
      sub('img0', 0, language: 'en'),
      sub('fr', 1),
      sub('fr2', 2),
      sub('de', 3),
    ];
    const engine = [
      PlaybackTrack(id: '0:0', language: 'fr'),
      PlaybackTrack(id: '1:0', language: 'fr'),
      PlaybackTrack(id: '2:0', language: 'de'),
    ];
    final pairing = EmbeddedSubtitlePairing.of(engine, withImage);

    expect(pairing.keyOf(engine[0]), 'fr');
    expect(pairing.keyOf(engine[1]), 'fr2');
    expect(pairing.trackFor('de'), engine[2]);
    expect(pairing.trackFor('img0'), isNull);
  });

  test('une piste que le serveur ne connaît pas n\'a pas de clé', () {
    const engine = [
      PlaybackTrack(id: '1', language: 'fre'),
      PlaybackTrack(id: '9', language: 'jpn'),
    ];
    final pairing = EmbeddedSubtitlePairing.of(engine, canonical);

    expect(pairing.keyOf(engine[1]), isNull);
  });
}
