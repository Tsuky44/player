import 'package:flutter/widgets.dart';

import '../playback_profile.dart';

/// Une piste audio ou de sous-titres, telle que le moteur de lecture la voit.
///
/// Distincte du modèle de pistes du serveur ([MediaTracks]), qui est la liste
/// canonique affichée à l'utilisateur : celle-ci décrit ce que le moteur a
/// réellement chargé, et sert à savoir laquelle est active et à lui en demander
/// une autre.
class PlaybackTrack {
  const PlaybackTrack({required this.id, this.title, this.language});

  final String id;
  final String? title;
  final String? language;

  @override
  bool operator ==(Object other) =>
      other is PlaybackTrack &&
      other.id == id &&
      other.title == title &&
      other.language == language;

  @override
  int get hashCode => Object.hash(id, title, language);

  @override
  String toString() => 'PlaybackTrack($id, $language, $title)';
}

/// Ce qu'on demande au moteur d'afficher comme sous-titres.
///
/// Trois formes, parce que l'app en utilise trois : aucune, une piste que le
/// moteur a déjà chargée, et un fichier WebVTT que le serveur a produit — ce
/// dernier étant le chemin normal, voir la « Unified Strategy » du contrôleur.
sealed class SubtitleSelection {
  const SubtitleSelection();

  /// Rien à l'écran.
  const factory SubtitleSelection.none() = SubtitleNone;

  /// Une piste interne au média, choisie dans ce que le moteur a énuméré.
  const factory SubtitleSelection.track(PlaybackTrack track) = SubtitleFromTrack;

  /// Un WebVTT servi par le backend, passé par son contenu.
  const factory SubtitleSelection.vtt(
    String content, {
    String? title,
    String? language,
  }) = SubtitleFromVtt;
}

class SubtitleNone extends SubtitleSelection {
  const SubtitleNone();
}

class SubtitleFromTrack extends SubtitleSelection {
  const SubtitleFromTrack(this.track);
  final PlaybackTrack track;
}

class SubtitleFromVtt extends SubtitleSelection {
  const SubtitleFromVtt(this.content, {this.title, this.language});
  final String content;
  final String? title;
  final String? language;
}

/// Ce que le décodeur a annoncé de l'image.
class PlaybackVideoParams {
  const PlaybackVideoParams({this.width, this.height, this.aspect});

  final int? width;
  final int? height;

  /// Rapport d'image tenant compte des pixels non carrés, quand le moteur le
  /// calcule. Null tant qu'il ne sait pas.
  final double? aspect;

  static const PlaybackVideoParams unknown = PlaybackVideoParams();
}

/// Ce que le moteur peut dire de la lecture en cours, pour la ligne de
/// diagnostic. Tout est optionnel : chaque moteur en connaît une partie.
class PlaybackDiagnostics {
  const PlaybackDiagnostics({
    this.videoCodec,
    this.hardwareDecoder,
    this.containerFps,
    this.droppedByDisplay,
    this.droppedByDecoder,
    this.sourceChannels,
    this.outputChannels,
    this.audioCodec,
  });

  final String? videoCodec;
  final String? hardwareDecoder;
  final double? containerFps;
  final int? droppedByDisplay;
  final int? droppedByDecoder;
  final String? sourceChannels;
  final String? outputChannels;
  final String? audioCodec;

  static const PlaybackDiagnostics none = PlaybackDiagnostics();
}

/// Le moteur de lecture, vu par le reste de l'application.
///
/// C'est la seule frontière entre le contrôleur — reprise, sessions HLS,
/// heartbeat, modèle de pistes, préférences, bascule de qualité, soit
/// l'essentiel de la logique — et le moteur qui décode réellement. mpv la
/// remplit sur macOS, Windows et le web ; ExoPlayer sur Android.
///
/// Elle est délibérément mince. Sur 2052 lignes de contrôleur, 118 touchaient
/// mpv : ce sont celles-ci, et rien de plus n'a de raison de descendre ici.
/// Tout ce qui pourrait s'écrire une fois pour les deux moteurs doit s'écrire
/// au-dessus.
abstract interface class PlaybackSession {
  /// La surface où l'image est rendue.
  ///
  /// Elle appartient au moteur : mpv dessine dans une texture, ExoPlayer dans
  /// une `SurfaceView` composée par le plan vidéo de l'écran. Ce sont deux
  /// widgets différents, et l'appelant n'a pas à savoir lequel.
  Widget buildSurface({
    Key? key,
    required BoxFit fit,
    double? aspectRatio,
  });

  /// Remonte les sous-titres au-dessus de la barre de progression.
  ///
  /// Le rendu des sous-titres appartient au moteur — sa propre vue, calée sur
  /// sa propre surface — donc le décalage aussi. Ce qu'il faut décaler, en
  /// revanche, se calcule au-dessus : voir `SubtitlePaddingCalculator`.
  void setSubtitlePadding(EdgeInsets padding, {Duration duration});

  // --- Commandes ---------------------------------------------------------

  /// Charge [url] en se plaçant à [start] dans le même geste : ouvrir puis
  /// chercher ferait payer deux fois la mise en mémoire tampon.
  Future<void> open(String url, {Duration? start, bool play = false});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setRate(double rate);
  Future<void> setAudioTrack(PlaybackTrack track);
  Future<void> setSubtitles(SubtitleSelection selection);

  /// Décharge le média sans détruire le moteur. Ce qui reste chargé garde sa
  /// connexion réseau ouverte et continue de lire le flux.
  Future<void> stop();

  // --- État --------------------------------------------------------------

  bool get isPlaying;
  bool get isBuffering;
  Duration get position;
  Duration get duration;

  /// De combien la mise en mémoire tampon devance la tête de lecture.
  Duration get bufferedAhead;

  double get volume;
  PlaybackVideoParams get videoParams;

  List<PlaybackTrack> get audioTracks;
  List<PlaybackTrack> get subtitleTracks;
  PlaybackTrack? get currentAudioTrack;
  PlaybackTrack? get currentSubtitleTrack;

  // --- Flux --------------------------------------------------------------

  Stream<Duration> get positions;
  Stream<Duration> get durations;
  Stream<bool> get playingChanges;
  Stream<bool> get bufferingChanges;
  Stream<void> get completions;
  Stream<void> get trackChanges;
  Stream<PlaybackVideoParams> get videoParamChanges;

  // --- Réglages propres au moteur ----------------------------------------

  /// Prépare le moteur pour une lecture directe du fichier. Chaque moteur
  /// traduit [profile] dans ses propres unités — octets et secondes pour mpv,
  /// millisecondes pour ExoPlayer.
  Future<void> applyDirectPlayTuning(PlaybackProfile profile);

  /// Idem pour une session transcodée : les tampons y sont plus courts, le
  /// serveur produisant les segments au fil de l'eau.
  Future<void> applyStreamingTuning(PlaybackProfile profile);

  /// Ce que le moteur sait dire de la lecture en cours. Pour la journalisation
  /// seule — rien ne doit en dépendre.
  Future<PlaybackDiagnostics> readDiagnostics();

  /// Quelle langue audio charger d'emblée.
  ///
  /// Posé **avant** l'ouverture : attendre la liste de pistes du serveur ferait
  /// démarrer la lecture sur ce que le conteneur a marqué par défaut, puis
  /// changer une seconde plus tard — et changer d'audio en cours de lecture
  /// fait recharger le tampon, ce qui s'entend.
  ///
  /// [priorities] est une liste d'orthographes de la même langue, de la plus
  /// probable à la moins : un fichier Matroska porte tantôt `fr`, tantôt `fre`,
  /// tantôt `french`. Vide veut dire « laisse le fichier décider », et doit
  /// quand même être écrit : sur un moteur réutilisé, se taire reviendrait à
  /// hériter du choix du média précédent.
  Future<void> setPreferredAudioLanguages(List<String> priorities);

  /// Cherche à l'image près, ou au point-clé le plus proche.
  ///
  /// Pendant qu'on fait glisser la tête de lecture, l'exactitude coûte un
  /// décodage depuis le point-clé précédent à chaque position traversée : on
  /// s'en passe le temps du geste, et on la rétablit au relâchement.
  Future<void> setExactSeek(bool exact);

  /// Impose la durée totale du média au moteur.
  ///
  /// En transcodage, le moteur ne voit que les segments déjà produits et
  /// annonce une durée qui grandit au fil de l'eau : la barre de progression
  /// s'étirerait pendant tout le film. C'est l'app qui connaît la vraie durée.
  Future<void> overrideDuration(Duration total);

  /// La première image est à l'écran.
  ///
  /// Le moment où un moteur peut enfin constater ce qu'il a réellement fait —
  /// et se corriger. mpv s'en sert pour rattraper un décodage matériel qui n'a
  /// pas pris : il se rabat sur le logiciel sans un mot, ce qui, sur un fichier
  /// 4K, donne deux images par seconde.
  Future<void> onPictureLive();
}
