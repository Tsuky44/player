import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../models/models.dart';
import '../../../services/hls_session.dart';
import 'subtitle_overlay.dart';
import 'vtt_cues.dart';

/// Ce qu'une lecture du WebVTT a rapporté : le statut HTTP, et les octets qui
/// suivent ceux qu'on avait déjà.
typedef LiveSubtitleChunk = ({int status, List<int> bytes});

/// Lit [url] à partir de l'octet [from].
typedef LiveSubtitleFetch = Future<LiveSubtitleChunk> Function(
    String url, int from);

/// Les sous-titres texte d'une session HLS, lus pendant que le serveur les
/// écrit. Voir ADR-0031.
///
/// Le transcodeur écrit chaque piste texte dans un WebVTT qui grandit avec la
/// session, sur l'horloge de ses segments. Ce flux en relit la suite à
/// intervalle régulier — seulement ce qui s'est ajouté, par `Range` — et donne
/// les lignes à afficher à la position du moteur.
///
/// Il remplace l'injection du fichier dans le moteur, qui n'allait pas avec un
/// fichier qui grandit : ExoPlayer rouvre le média à chaque sous-titre externe
/// posé, mpv ne relit pas une piste ajoutée, et le navigateur ne recharge pas
/// un `<track>`. Les lignes sont donc peintes par Flutter ([LiveSubtitleLayer]),
/// avec l'habillage de [SubtitleOverlay] que les moteurs partagent déjà — le
/// même sur toutes les plateformes, web compris.
class LiveSubtitleFeed {
  LiveSubtitleFeed({
    LiveSubtitleFetch? fetch,
    this.pollInterval = const Duration(seconds: 4),
  }) : _fetch = fetch ?? _httpFetch;

  final LiveSubtitleFetch _fetch;

  /// Assez court devant l'avance du transcodeur, qui produit une trentaine de
  /// secondes devant la tête de lecture avant de se mettre en pause.
  final Duration pollInterval;

  /// Les lignes à l'écran maintenant.
  final ValueNotifier<List<String>> lines = ValueNotifier(const []);

  /// De combien les remonter au-dessus de la barre de progression.
  final ValueNotifier<({EdgeInsets padding, Duration duration})> inset =
      ValueNotifier((
    padding: SubtitleOverlay.defaultPadding,
    duration: Duration.zero,
  ));

  String? _url;
  Timer? _timer;
  StreamSubscription<Duration>? _positions;
  Duration _position = Duration.zero;

  /// Change à chaque [follow] et [stop] : une réponse d'une piste qu'on a
  /// quittée arrive parfois après, et ne doit rien écrire.
  int _generation = 0;

  /// La génération dont un relevé est en route. Deux relevés d'une même piste
  /// en même temps demanderaient la même suite et l'ajouteraient deux fois ;
  /// celui d'une piste quittée, lui, ne doit pas bloquer la nouvelle.
  int? _inFlight;

  int _received = 0;
  List<int> _pending = const [];
  final StringBuffer _complete = StringBuffer();
  VttCues _cues = VttCues.empty;

  /// La piste suivie, ou null.
  String? get url => _url;

  /// Suit la piste servie à [url], et affiche ses lignes au rythme de
  /// [positions] — la position du moteur, qui est celle de la session.
  void follow(String url, {required Stream<Duration> positions}) {
    if (url == _url) return;
    stop();
    _url = url;
    final generation = _generation;
    _positions = positions.listen((position) {
      _position = position;
      _refreshLines();
    });
    unawaited(_poll(generation));
    _timer = Timer.periodic(pollInterval, (_) => _poll(generation));
  }

  /// Arrête de suivre et efface ce qui est à l'écran.
  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    unawaited(_positions?.cancel());
    _positions = null;
    _url = null;
    _received = 0;
    _pending = const [];
    _complete.clear();
    _cues = VttCues.empty;
    _position = Duration.zero;
    lines.value = const [];
  }

  void setPadding(EdgeInsets padding, {Duration duration = Duration.zero}) {
    inset.value = (padding: padding, duration: duration);
  }

  void dispose() {
    stop();
    lines.dispose();
    inset.dispose();
  }

  /// Un relevé tout de suite, hors du rythme régulier.
  @visibleForTesting
  Future<void> pollNow() => _poll(_generation);

  Future<void> _poll(int generation) async {
    final url = _url;
    if (url == null || _inFlight == generation) return;
    _inFlight = generation;
    try {
      final chunk = await _fetch(url, _received);
      if (generation != _generation) return;
      _accept(chunk);
    } catch (e) {
      // Un relevé manqué se rattrape au suivant : le fichier ne fait que
      // grandir, et la suite demandée repart de ce qui a été reçu.
      debugPrint('LiveSubtitles: relevé manqué ($e)');
    } finally {
      if (_inFlight == generation) _inFlight = null;
    }
  }

  void _accept(LiveSubtitleChunk chunk) {
    switch (chunk.status) {
      case 204: // pas encore de réplique
      case 416: // rien de neuf
        return;
      case 200: // le fichier entier, d'un serveur qui a ignoré le Range
        _received = 0;
        _pending = const [];
        _complete.clear();
      case 206:
        break;
      case 401:
      case 403:
      case 404:
        // Session détruite ou ticket révoqué : rien ne viendra plus.
        _timer?.cancel();
        _timer = null;
        return;
      default:
        return;
    }
    if (chunk.bytes.isEmpty) return;
    _received += chunk.bytes.length;
    final pending = [..._pending, ...chunk.bytes];

    // FFmpeg écrit réplique par réplique, et une lecture peut tomber au milieu
    // d'une : seuls les blocs terminés par une ligne vide sont gardés, le reste
    // attend la suite. Couper sur des octets, pas sur du texte, garde aussi
    // entier un caractère UTF-8 à cheval sur deux lectures.
    final cut = completeBlocksEnd(pending);
    if (cut == 0) {
      _pending = pending;
      return;
    }
    _complete.write(utf8.decode(pending.sublist(0, cut), allowMalformed: true));
    _pending = pending.sublist(cut);
    _cues = VttCues.parse(_complete.toString());
    _refreshLines();
  }

  void _refreshLines() {
    final next = _cues.linesAt(_position);
    if (!listEquals(next, lines.value)) lines.value = next;
  }

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.bytes,
    // 204 et 416 sont des réponses normales ici, pas des erreurs.
    validateStatus: (status) => status != null && status < 500,
  ));

  static Future<LiveSubtitleChunk> _httpFetch(String url, int from) async {
    final response = await _dio.get<List<int>>(
      url,
      options: Options(headers: from > 0 ? {'Range': 'bytes=$from-'} : null),
    );
    return (status: response.statusCode ?? 0, bytes: response.data ?? const []);
  }
}

/// La position qui suit le dernier bloc complet de [bytes] — une ligne vide,
/// `\n\n` — ou 0 s'il n'y en a pas encore.
@visibleForTesting
int completeBlocksEnd(List<int> bytes) {
  for (var i = bytes.length - 1; i > 0; i--) {
    if (bytes[i] == 0x0A && bytes[i - 1] == 0x0A) return i + 1;
    // Une fin de ligne Windows : \r\n\r\n.
    if (i > 2 &&
        bytes[i] == 0x0A &&
        bytes[i - 1] == 0x0D &&
        bytes[i - 2] == 0x0A &&
        bytes[i - 3] == 0x0D) {
      return i + 1;
    }
  }
  return 0;
}

/// La source vivante qui correspond à une piste du catalogue, ou null.
///
/// Le catalogue et la session nomment la piste de la même façon : sa place
/// parmi les sous-titres du conteneur.
LiveSubtitleSource? liveSourceFor(
  List<LiveSubtitleSource> sources,
  MediaSubtitleTrack? track,
) {
  if (track == null || track.image || track.typedIndex < 0) return null;
  for (final source in sources) {
    if (source.typedIndex == track.typedIndex) return source;
  }
  return null;
}

/// [tracks], avec les pistes que la session écrit marquées prêtes.
///
/// « Prête » voulait dire « extraite » ; une piste que la session écrit l'est
/// d'emblée. Les marquer ici plutôt que partout où on lit le drapeau est ce qui
/// éteint, pour elles, toute la mécanique d'extraction — bouton, attente,
/// relevés — sans la toucher.
MediaTracks withLiveSubtitles(
  MediaTracks tracks,
  List<LiveSubtitleSource> sources,
) {
  final live = {for (final s in sources) s.typedIndex};
  return MediaTracks(
    video: tracks.video,
    audio: tracks.audio,
    qualities: tracks.qualities,
    subtitles: [
      for (final s in tracks.subtitles)
        if (!s.image && live.contains(s.typedIndex))
          MediaSubtitleTrack(
            lang: s.lang,
            name: s.name,
            ready: true,
            typedIndex: s.typedIndex,
            forced: s.forced,
            isDefault: s.isDefault,
          )
        else
          s,
    ],
  );
}

/// La surface vidéo, avec par-dessus les lignes de [feed].
class LiveSubtitleLayer extends StatelessWidget {
  const LiveSubtitleLayer({super.key, required this.feed, required this.child});

  final LiveSubtitleFeed feed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        SubtitleOverlay(cues: feed.lines, inset: feed.inset),
      ],
    );
  }
}
