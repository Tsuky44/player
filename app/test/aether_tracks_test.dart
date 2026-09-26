import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/aether_tracks.dart';
import 'package:onyx/screens/player/playback/playback_session.dart';
import 'package:onyx_player_apple/onyx_player_apple.dart';

/// Le contrôleur retrouve la langue d'un sous-titre du fichier par `id - 1`,
/// l'index typé que le serveur publie, et désigne l'audio par sa position.
/// AetherEngine numérote tout par index de flux FFmpeg : si la traduction
/// dérape, un film réglé en français s'affiche avec les sous-titres d'une autre
/// langue, sans la moindre erreur.
void main() {
  OnyxAppleTrack track(
    String id, {
    String? language,
    bool container = true,
    bool bitmap = false,
  }) =>
      OnyxAppleTrack(
        id: id,
        language: language,
        codec: bitmap ? 'hdmv_pgs_subtitle' : 'subrip',
        channels: 0,
        isDefault: false,
        isForced: false,
        isAtmos: false,
        isBitmap: bitmap,
        isContainerStream: container,
      );

  OnyxApplePlayerStatus status({
    List<OnyxAppleTrack> audio = const [],
    List<OnyxAppleTrack> subtitles = const [],
    String? selectedAudio,
    String? selectedSubtitle,
  }) =>
      OnyxApplePlayerStatus(
        playerId: 1,
        state: OnyxApplePlaybackState.ready,
        isPlaying: true,
        positionMs: 0,
        durationMs: 0,
        bufferedPositionMs: 0,
        audioTracks: audio,
        subtitleTracks: subtitles,
        selectedAudioTrackId: selectedAudio,
        selectedSubtitleTrackId: selectedSubtitle,
        videoFormat: 'sdr',
      );

  test('les sous-titres du fichier sont numérotés de 1 à N, dans l’ordre du '
      'conteneur', () {
    // Flux 0 : vidéo, 1-2 : audio, 3-5 : sous-titres, listés dans le désordre.
    final tracks = AetherTracks.of(status(subtitles: [
      track('5', language: 'eng'),
      track('3', language: 'fre'),
      track('4', language: 'ger', bitmap: true),
    ]));

    expect(tracks.subtitles.map((t) => (t.id, t.language)), [
      ('1', 'fre'),
      ('2', 'ger'),
      ('3', 'eng'),
    ]);
    expect(tracks.nativeSubtitleId(tracks.subtitles[1]), '4');
  });

  test('un sous-titre posé par l’app ou tiré de l’image ne décale rien', () {
    final tracks = AetherTracks.of(status(subtitles: [
      track('100000', language: 'fre', container: false), // WebVTT du serveur
      track('3', language: 'eng'),
      track('99608', container: false), // CEA-608
      track('4', language: 'spa'),
    ]));

    expect(tracks.subtitles.map((t) => t.language), ['eng', 'spa']);
  });

  test('la piste active se lit dans la numérotation de l’app', () {
    final tracks = AetherTracks.of(status(
      subtitles: [track('3'), track('4')],
      selectedSubtitle: '4',
    ));
    expect(tracks.currentSubtitle, const PlaybackTrack(id: '2'));
  });

  test('le WebVTT du serveur n’est pas une piste du fichier', () {
    final tracks = AetherTracks.of(status(
      subtitles: [track('3'), track('100000', container: false)],
      selectedSubtitle: '100000',
    ));
    expect(tracks.currentSubtitle, isNull);
  });

  test('l’audio garde l’ordre du conteneur et ses index natifs', () {
    // Le contrôleur désigne l'audio par position : la position doit être
    // celle du fichier, et l'id celui que le moteur attend en retour.
    final tracks = AetherTracks.of(status(
      audio: [track('2', language: 'eng'), track('1', language: 'fre')],
      selectedAudio: '1',
    ));
    expect(tracks.audio.map((t) => (t.id, t.language)), [
      ('1', 'fre'),
      ('2', 'eng'),
    ]);
    expect(tracks.currentAudio?.language, 'fre');
  });
}
