import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/playback/audio_track_pairing.dart';
import 'package:onyx/screens/player/playback/playback_session.dart';

/// Un téléviseur LG liste les pistes audio du fichier dans l'ordre de son
/// pipeline, pas dans celui du conteneur : choisir par le rang du serveur
/// donnait l'anglais à qui avait demandé le français. La langue désigne la
/// piste ; le rang ne sert que quand elle ne dit rien.
void main() {
  MediaAudioTrack audio(int index, String? language) => MediaAudioTrack(
        index: index,
        typedIndex: index,
        codec: 'eac3',
        language: language,
      );

  PlaybackTrack engine(String id, String? language) =>
      PlaybackTrack(id: id, language: language);

  test('un moteur qui inverse deux langues ne change pas la piste choisie', () {
    final catalogue = [audio(0, 'fre'), audio(1, 'eng')];
    final tracks = [engine('0', 'eng'), engine('1', 'fre')];

    expect(engineAudioTrackFor(0, catalogue, tracks), tracks[1]);
    expect(engineAudioTrackFor(1, catalogue, tracks), tracks[0]);
  });

  test('les codes à deux et à trois lettres se rejoignent', () {
    final catalogue = [audio(0, 'fr'), audio(1, 'en')];
    final tracks = [engine('0', 'en'), engine('1', 'fra')];

    expect(engineAudioTrackFor(0, catalogue, tracks), tracks[1]);
  });

  test('deux pistes de la même langue se départagent par leur rang', () {
    final catalogue = [audio(0, 'fre'), audio(1, 'eng'), audio(2, 'fre')];
    final tracks = [engine('0', 'fre'), engine('1', 'fre'), engine('2', 'eng')];

    expect(engineAudioTrackFor(0, catalogue, tracks), tracks[0]);
    expect(engineAudioTrackFor(2, catalogue, tracks), tracks[1]);
    expect(engineAudioTrackFor(1, catalogue, tracks), tracks[2]);
  });

  test('sans langue lisible côté moteur, le rang dans la liste fait foi', () {
    final catalogue = [audio(0, 'fre'), audio(1, 'eng')];
    final tracks = [engine('0', null), engine('1', null)];

    expect(engineAudioTrackFor(1, catalogue, tracks), tracks[1]);
  });

  test('si le moteur en liste moins que le serveur, le rang reste borné', () {
    final catalogue = [audio(0, 'fre'), audio(1, 'eng'), audio(2, 'jpn')];
    final tracks = [engine('0', 'fre'), engine('1', 'eng')];

    expect(engineAudioTrackFor(2, catalogue, tracks), tracks[1]);
  });

  test('rien à choisir : pas de piste, pas d\'exception', () {
    expect(engineAudioTrackFor(0, [audio(0, 'fre')], const []), isNull);
    expect(engineAudioTrackFor(3, [audio(0, 'fre')], [engine('0', 'fre')]),
        isNull);
  });
}
