part of 'use_player_controller.dart';

/// Le Dolby Vision profil 5 face à un moteur qui n'applique pas la couche RPU
/// (ADR-0060) : la lecture passe par le serveur, et le fichier lui-même
/// s'annonce avec ses couleurs fausses.
extension PlayerControllerDolbyVision on PlayerController {
  /// Si le fichier, ouvert tel quel, sortirait rose et vert.
  ///
  /// Un profil 5 s'ouvre et se décode sans erreur partout — c'est du HEVC —
  /// mais sa couche de base n'est pas du YCbCr : sans la RPU, les visages sont
  /// roses et verts. Un fichier téléchargé reste lu tel quel : hors ligne, il
  /// n'y a pas de serveur pour le convertir.
  bool get _dolbyVisionNeedsServer =>
      !_hlsOnly &&
      _localFilePath == null &&
      (mediaTracks?.video?.needsDolbyVision ?? false) &&
      !PlaybackCapabilitiesResolver.current.dolbyVisionInDirectPlay;

  /// Si le menu Qualité doit prévenir que le fichier d'origine sort avec des
  /// couleurs fausses.
  ///
  /// La ligne reste : sur un serveur trop petit pour ce transcodage, une image
  /// rose est tout ce qui se regarde. Mais elle le dit — vu sous Windows, la
  /// choisir sans le savoir ramenait l'image que le transcodage venait de
  /// corriger. L'Auto, lui, n'y revient jamais.
  bool get directPlayHasWrongColours => _dolbyVisionNeedsServer;

  bool _directPlayCannotShowDolbyVision() =>
      currentQuality == null && _dolbyVisionNeedsServer;

  /// Passe en HLS pour que le serveur applique la couche RPU.
  ///
  /// Au plus en 1080p, contrairement à [_transcodeForUndecodableAudio] :
  /// l'image est ré-encodée de toute façon, donc la résolution d'origine ne
  /// sauve aucune recopie, et un serveur sans GPU ne tient pas ce tone mapping
  /// en 4K.
  Future<void> _transcodeForDolbyVision() async {
    final height = mediaTracks?.video?.height ?? 0;
    final quality = qualityForSourceHeight(height > 1080 ? 1080 : height);
    debugPrint('Player: Dolby Vision profil 5 illisible en Direct Play '
        '(${PlaybackCapabilitiesResolver.current.label}) — HLS $quality');
    // L'Auto ne ramènera pas la lecture sur une image rose et verte.
    _directPlayRuledOut = true;
    _autoCeilingKey = quality;
    await switchToQuality(quality);
  }
}
