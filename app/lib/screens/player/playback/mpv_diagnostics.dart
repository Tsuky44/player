import 'playback_session.dart';

/// Ce que mpv sait dire de la lecture en cours, lu propriété par propriété.
///
/// [read] rend la valeur d'une propriété mpv, ou null quand il ne l'a pas.
Future<PlaybackDiagnostics> readMpvDiagnostics(
    Future<String?> Function(String name) read) async {
  return PlaybackDiagnostics(
    videoCodec: await read('video-codec'),
    // `hwdec-current` est la réponse de mpv, pas ce qu'on lui a demandé : un
    // décodeur qui n'a pas démarré se rabat en silence.
    hardwareDecoder: await read('hwdec-current'),
    containerFps: double.tryParse(await read('container-fps') ?? ''),
    droppedByDisplay: int.tryParse(await read('frame-drop-count') ?? ''),
    droppedByDecoder:
        int.tryParse(await read('decoder-frame-drop-count') ?? ''),
    sourceChannels: await read('audio-params/channel-count'),
    outputChannels: await read('audio-out-params/channel-count'),
    audioCodec: await read('audio-codec-name'),
    renderedFrames: int.tryParse(await read('frame-count') ?? ''),
    // La cadence telle qu'elle sort, pas telle qu'elle est annoncée. mpv la
    // moyenne lui-même sur les dernières images, ce qui évite d'avoir à
    // dériver un compteur sur deux relevés.
    estimatedFps: double.tryParse(await read('estimated-vf-fps') ?? ''),
    videoBitrate: double.tryParse(await read('video-bitrate') ?? ''),
    audioBitrate: double.tryParse(await read('audio-bitrate') ?? ''),
    bytesLoaded:
        int.tryParse(await read('demuxer-cache-state/total-bytes') ?? ''),
  );
}
