import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../models/models.dart';
import '../../../screens/player/playback/timeline_previews.dart';
import '../../../services/api_client.dart';
import '../../../services/playback_access.dart';

/// Les secondes montrées par l'aperçu d'une carte « Reprendre » : les deux
/// minutes et demie qui précèdent l'arrêt, la dernière image étant celle où
/// l'on s'est arrêté. C'est ce qui rafraîchit la mémoire avant de reprendre.
///
/// Un média à peine commencé (l'épisode suivant d'une série, à 0) montrerait
/// sinon le noir du début : la fenêtre glisse alors jusqu'à l'ouverture, après
/// les logos des studios.
List<int> resumeStillSeconds(int position, int duration, {int count = 6}) {
  const span = 150;
  const lead = 30;
  if (duration <= 0 || count <= 0) return const [];
  final last = duration - 1;
  var end = position.clamp(0, last);
  if (end < lead + span) end = math.min(lead + span, last);
  final start = math.max(math.min(lead, end), end - span);
  if (count == 1 || end <= start) return [end];
  return [
    for (var i = 0; i < count; i++)
      start + ((end - start) * i / (count - 1)).round(),
  ];
}

/// Les images de l'aperçu d'une carte, tirées des images de la barre de
/// lecture que le serveur sait déjà extraire à la demande (une image clé, de
/// 40 à 170 ms selon le fichier).
///
/// Une seule requête à la fois, dans l'ordre chronologique : la première image
/// s'affiche dès qu'elle arrive, les suivantes rejoignent le diaporama. Un
/// échec arrête la suite sans bruit — la carte garde alors son affiche, ce qui
/// est exactement ce qu'elle montrait avant.
class ResumePreviewStills extends ChangeNotifier {
  ResumePreviewStills({
    required this.cacheKey,
    required List<int> seconds,
    required Future<Map<String, dynamic>> Function() open,
    required Future<Uint8List> Function(int index) fetch,
    Future<void> Function()? close,
  })  : _seconds = seconds,
        _open = open,
        _fetch = fetch,
        _close = close;

  /// L'aperçu d'un élément de « Reprendre », servi par [api]. Le ticket de
  /// lecture n'est demandé qu'au premier survol qui dure, et rendu à la
  /// fermeture : un survol ne laisse rien derrière lui sur le serveur.
  factory ResumePreviewStills.forItem(ApiClient api, HomeMediaItem item) {
    final mediaId = item.media.id;
    PlaybackAccess? lease;
    var closed = false;
    return ResumePreviewStills(
      cacheKey: '${api.baseUrl}#$mediaId@${item.currentPositionSeconds}',
      seconds: resumeStillSeconds(
          item.currentPositionSeconds, item.effectiveDuration),
      open: () async {
        final access = await api.openPlaybackAccess(mediaId);
        // La souris est partie pendant que le ticket arrivait : il est rendu
        // tout de suite plutôt que d'attendre son expiration.
        if (closed) {
          await access.close();
          throw StateError('Aperçu fermé');
        }
        lease = access;
        return api.openTimelinePreviews(mediaId, access: access, warm: false);
      },
      fetch: (index) =>
          api.fetchTimelinePreview(mediaId, index, access: lease!),
      close: () async {
        closed = true;
        await lease?.close();
      },
    );
  }

  /// Ce qui identifie un aperçu entre deux survols : le serveur, le média et
  /// la position. Une reprise plus loin change la clé, donc les images.
  final String cacheKey;

  final List<int> _seconds;
  final Future<Map<String, dynamic>> Function() _open;
  final Future<Uint8List> Function(int index) _fetch;
  final Future<void> Function()? _close;

  /// Les aperçus des derniers survols, pour qu'un retour sur une carte
  /// reparte sans aller-retour. Quelques centaines de Ko au plus.
  static final LinkedHashMap<String, List<ImageProvider>> _recent =
      LinkedHashMap();
  static const _recentCapacity = 12;

  final List<ImageProvider> _images = [];
  bool _started = false;
  bool _disposed = false;

  /// Les images arrivées, dans l'ordre chronologique.
  List<ImageProvider> get images => List.unmodifiable(_images);

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    final cached = _recent.remove(cacheKey);
    if (cached != null) {
      _recent[cacheKey] = cached;
      _images.addAll(cached);
      notifyListeners();
      return;
    }
    try {
      final manifest = TimelinePreviewManifest.fromJson(await _open());
      if (_disposed || !manifest.isUsable) return;
      final indices = <int>{
        for (final s in _seconds) manifest.indexFor(Duration(seconds: s)),
      };
      for (final index in indices) {
        final bytes = await _fetch(index);
        if (_disposed) return;
        _images.add(MemoryImage(bytes));
        notifyListeners();
      }
      _remember();
    } catch (e) {
      // Serveur sans images de barre, fichier illisible, ticket refusé :
      // l'aperçu garde ce qu'il a, l'affiche à défaut.
      debugPrint('ResumePreviewStills: stopped (${e.runtimeType})');
    }
  }

  void _remember() {
    _recent[cacheKey] = List.of(_images);
    while (_recent.length > _recentCapacity) {
      _recent.remove(_recent.keys.first);
    }
  }

  @visibleForTesting
  static void clearCacheForTest() => _recent.clear();

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final close = _close;
    if (close != null) unawaited(close());
    super.dispose();
  }
}
