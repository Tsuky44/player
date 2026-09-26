import 'package:onyx_player_apple/onyx_player_apple.dart';

import 'playback_session.dart';

/// Les pistes d'AetherEngine, dans la numérotation que le contrôleur attend.
///
/// Le contrôleur a été écrit contre mpv, et il en garde deux conventions :
///
/// - **L'audio se désigne par sa position** dans la liste du moteur, qui en
///   Direct Play est l'ordre du conteneur (`_playerAudioPosition`).
/// - **Les sous-titres se numérotent de 1 à N** dans l'ordre du conteneur,
///   si bien que `id - 1` est l'index typé (`0:s:N`) par lequel le serveur
///   donne leur langue (`_canonicalLangForEmbedded`).
///
/// AetherEngine, lui, désigne chaque piste par son index de flux FFmpeg, tous
/// types confondus. La traduction se fait ici, une fois, plutôt que d'apprendre
/// au contrôleur un troisième vocabulaire.
class AetherTracks {
  const AetherTracks._({
    required this.audio,
    required this.subtitles,
    required this.currentAudio,
    required this.currentSubtitle,
    required Map<String, String> subtitleNativeIds,
  }) : _subtitleNativeIds = subtitleNativeIds;

  factory AetherTracks.of(OnyxApplePlayerStatus status) {
    final audio = _containerOrder(status.audioTracks)
        .map((t) => PlaybackTrack(id: t.id, title: t.title, language: t.language))
        .toList(growable: false);

    final nativeIds = <String, String>{};
    final subtitles = <PlaybackTrack>[];
    PlaybackTrack? currentSubtitle;
    for (final t in _containerOrder(status.subtitleTracks)) {
      final track = PlaybackTrack(
        id: '${subtitles.length + 1}',
        title: t.title,
        language: t.language,
      );
      subtitles.add(track);
      nativeIds[track.id] = t.id;
      if (t.id == status.selectedSubtitleTrackId) currentSubtitle = track;
    }

    PlaybackTrack? currentAudio;
    for (final track in audio) {
      if (track.id == status.selectedAudioTrackId) currentAudio = track;
    }

    return AetherTracks._(
      audio: audio,
      subtitles: List.unmodifiable(subtitles),
      currentAudio: currentAudio,
      currentSubtitle: currentSubtitle,
      subtitleNativeIds: Map.unmodifiable(nativeIds),
    );
  }

  static const empty = AetherTracks._(
    audio: [],
    subtitles: [],
    currentAudio: null,
    currentSubtitle: null,
    subtitleNativeIds: {},
  );

  final List<PlaybackTrack> audio;
  final List<PlaybackTrack> subtitles;
  final PlaybackTrack? currentAudio;

  /// Null aussi quand c'est le WebVTT du serveur qui s'affiche : il n'a pas de
  /// place dans la numérotation du fichier.
  final PlaybackTrack? currentSubtitle;

  final Map<String, String> _subtitleNativeIds;

  /// L'index de flux FFmpeg d'une piste de [subtitles], à rendre au moteur.
  String? nativeSubtitleId(PlaybackTrack track) => _subtitleNativeIds[track.id];

  /// Les vrais flux du fichier, dans l'ordre du conteneur. Un sous-titre posé
  /// par l'app ou extrait de l'image décalerait toute la numérotation.
  static List<OnyxAppleTrack> _containerOrder(List<OnyxAppleTrack> tracks) {
    final streams = tracks.where((t) => t.isContainerStream).toList();
    streams.sort((a, b) =>
        (int.tryParse(a.id) ?? 0).compareTo(int.tryParse(b.id) ?? 0));
    return streams;
  }
}
