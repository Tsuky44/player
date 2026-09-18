import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../models/offline_chrome.dart';
import '../models/offline_download.dart';
import '../utils/poster_url.dart';
import 'api_client.dart';
import 'playback_access.dart';
import 'app_image_cache.dart';

/// Le magasin hors ligne : ce qui a été rapatrié sur cet appareil, ce qui est
/// en train de l'être, et ce qui en a été vu sans que le serveur le sache
/// encore.
///
/// Un seul objet tient les trois parce qu'elles ne se séparent pas :
/// l'avancement local n'a de sens que pour un média téléchargé, et la file
/// d'attente n'a de sens qu'au regard de ce qui est déjà sur le disque.
///
/// ## Ce qui atterrit sur le disque
///
/// ```
/// <support applicatif>/onyx_offline/
///   manifest.json          ← la liste, seule source de vérité
///   chromes.json           ← le playeur du compte, par serveur d'origine
///   shows/<showId>/
///     details.json         ← la fiche de la série, partagée par ses épisodes
///     poster.jpg
///     logo.png
///   <mediaId>/
///     video.mkv            ← le fichier d'origine, octet pour octet
///     poster.jpg
///     tracks.json          ← la réponse de /api/media/:id/tracks
///     sub_fr.vtt …
/// ```
///
/// Le manifeste ne garde que des noms de fichiers, jamais des chemins absolus :
/// le conteneur d'application change d'emplacement d'une version à l'autre sur
/// macOS comme sur Android, et un chemin gravé ne survivrait pas à une mise à
/// jour.
///
/// ## Reprise
///
/// Le transfert est un GET `Range:` sur `/stream`, écrit en append. Une app
/// tuée en plein téléchargement laisse donc un fichier partiel parfaitement
/// utilisable : au démarrage suivant l'entrée repasse en file et repart à
/// l'octet où elle s'était arrêtée. Un serveur qui ignorerait le `Range`
/// (réponse 200 au lieu de 206) fait repartir de zéro plutôt que de produire un
/// fichier corrompu.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();

  static final DownloadManager instance = DownloadManager._();

  /// Client dédié aux transferts : celui de l'app impose un `receiveTimeout`
  /// de 30 s taillé pour des réponses JSON, et surtout ses interceptors n'ont
  /// rien à faire dans une réponse en flux.
  final Dio _transferDio = Dio(BaseOptions(
    // Le temps de trouver le serveur ; au-delà c'est qu'il n'est pas là.
    connectTimeout: const Duration(seconds: 15),
    // Compté entre deux morceaux, pas sur la durée du fichier : un film de
    // 8 Go ne doit pas expirer, un lien mort doit lâcher.
    receiveTimeout: const Duration(seconds: 60),
  ));

  ApiClient? _api;
  Directory? _root;
  bool _ready = false;

  final Map<int, OfflineDownload> _entries = {};

  /// Les entrées des **autres** serveurs, gardées de côté telles quelles.
  ///
  /// Une entrée est repérée par son `mediaId`, qui est un numéro propre à un
  /// serveur : le film 42 de l'un n'a rien à voir avec le film 42 de l'autre.
  /// Depuis qu'un même appareil peut tenir plusieurs serveurs (ADR-0013), la
  /// carte en mémoire ne contient donc que le serveur actif — sinon deux
  /// bibliothèques se recouvriraient à la première collision de numéro. Le
  /// manifeste, lui, continue de tout porter : ce qui a été téléchargé ailleurs
  /// est toujours sur le disque, et réapparaît en revenant sur ce serveur.
  final List<OfflineDownload> _otherServers = [];

  /// Adresse normalisée du serveur dont [_entries] tient les téléchargements.
  String _scope = '';
  final Map<int, CancelToken> _cancelTokens = {};

  /// Les fiches rapatriées, indexées par l'identifiant de la série (ou du film
  /// pour un film). Relues d'un bloc au démarrage : l'écran des
  /// téléchargements les lit pendant qu'il construit ses lignes, et une
  /// lecture disque par ligne se verrait.
  final Map<int, MediaDetails> _shows = {};

  /// Le playeur de chaque compte, par serveur d'origine.
  final Map<String, OfflineChrome> _chromes = {};

  int? _activeMediaId;
  bool _pumping = false;

  /// « A-t-on le droit de faire passer des octets maintenant ? »
  ///
  /// Posée à chaque tour de file, et posée dehors : ce qui décide est le
  /// croisement d'un état réseau et d'un réglage utilisateur, deux choses dont
  /// le magasin hors ligne n'a pas à connaître l'existence. Null vaut oui — un
  /// test, ou un appareil qui n'a rien à arbitrer.
  bool Function()? transferGate;

  bool _heldForNetwork = false;

  /// La file est pleine mais rien ne descend : le réseau du moment ne convient
  /// pas. C'est un état à montrer, pas une panne — d'où l'absence de statut
  /// « en pause automatique » sur les entrées, qui restent en file (voir
  /// [DownloadStatus]).
  bool get isHeldForNetwork => _heldForNetwork && queuedCount > 0;

  /// Combien d'entrées attendent leur tour, transfert en cours compris.
  int get queuedCount => _entries.values.where((e) => e.isActive).length;

  /// Les médias que l'utilisateur a effacés sans les avoir vus, sous la forme
  /// `serveur|identifiant`.
  ///
  /// Sans cette liste, le réapprovisionnement automatique reprendrait au tour
  /// suivant exactement l'épisode qu'on vient de supprimer pour faire de la
  /// place — et la place ne se ferait jamais. Un effacement est une réponse à
  /// « celui-ci, non », et elle survit au redémarrage : c'est le lendemain,
  /// disque plein, qu'elle compte le plus.
  ///
  /// Redemander le média explicitement annule la réponse.
  final Set<String> _declined = {};

  String _declineKey(int mediaId, String serverUrl) =>
      '${serverUrl.isEmpty ? _scope : serverUrl}|$mediaId';

  /// Ce média a-t-il été écarté à la main ?
  bool isDeclined(int mediaId) => _declined.contains(_declineKey(mediaId, _scope));

  /// Le manifeste n'est pas réécrit à chaque paquet reçu : on marque, et une
  /// écriture groupée suit.
  bool _manifestDirty = false;
  Timer? _manifestTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isSupported => true;

  /// Vrai une fois le manifeste relu. Avant ça la liste est vide sans que cela
  /// veuille dire « rien n'est téléchargé ».
  bool get isReady => _ready;

  /// Les entrées, du plus récent au plus ancien, les transferts en cours
  /// d'abord — c'est l'ordre dans lequel l'écran les affiche.
  List<OfflineDownload> get downloads {
    final list = _entries.values.toList();
    list.sort((a, b) {
      final rank = _statusRank(a.status).compareTo(_statusRank(b.status));
      if (rank != 0) return rank;
      return b.addedAt.compareTo(a.addedAt);
    });
    return list;
  }

  static int _statusRank(DownloadStatus s) {
    switch (s) {
      case DownloadStatus.downloading:
        return 0;
      case DownloadStatus.queued:
        return 1;
      case DownloadStatus.failed:
        return 2;
      case DownloadStatus.paused:
        return 3;
      case DownloadStatus.completed:
        return 4;
    }
  }

  int get pendingSyncCount => _entries.values.where((e) => e.needsSync).length;

  int get totalBytesOnDisk =>
      _entries.values.fold<int>(0, (sum, e) => sum + e.bytesReceived);

  // ==================== Cycle de vie ====================

  Future<void> initialize(ApiClient api) async {
    _api = api;
    _scope = OfflineChrome.normalizeServerUrl(api.baseUrl);
    if (_ready) return;
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'onyx_offline'));
      if (!await root.exists()) {
        await root.create(recursive: true);
      }
      _root = root;
      await _loadManifest();
      await _loadShows();
      await _loadChromes();
    } catch (e) {
      debugPrint(
          'Downloads: initialisation impossible: ${redactPlaybackDiagnostic(e)}');
    } finally {
      _ready = true;
      notifyListeners();
    }

    // Un transfert interrompu par la fermeture de l'app n'est pas une panne :
    // il reprend tout seul, à l'octet près.
    unawaited(_pump());
  }

  Future<void> _loadManifest() async {
    final file = _manifestFile;
    if (file == null || !await file.exists()) return;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map) {
        for (final key in (raw['declined'] as List?) ?? const []) {
          if (key is String) _declined.add(key);
        }
      }
      final items = (raw is Map ? raw['items'] : raw) as List? ?? const [];
      for (final item in items) {
        final entry = OfflineDownload.fromJson(item as Map<String, dynamic>);
        if (!_inScope(entry)) {
          _otherServers.add(entry);
          continue;
        }
        // « En cours » ne peut pas avoir survécu à l'arrêt du processus : ce
        // qui l'était redevient une entrée de file.
        _entries[entry.mediaId] = entry.status == DownloadStatus.downloading
            ? entry.copyWith(status: DownloadStatus.queued)
            : entry;
      }
    } catch (e) {
      debugPrint(
          'Downloads: manifeste illisible: ${redactPlaybackDiagnostic(e)}');
    }
  }

  /// Relit les fiches de séries écrites à côté des médias.
  ///
  /// Une fiche illisible est ignorée, jamais fatale : elle décore l'écran, elle
  /// ne conditionne pas la lecture.
  Future<void> _loadShows() async {
    final dir = _showsDir;
    if (dir == null || !await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = int.tryParse(p.basename(entity.path));
      if (id == null) continue;
      final file = File(p.join(entity.path, 'details.json'));
      if (!await file.exists()) continue;
      try {
        final raw = jsonDecode(await file.readAsString());
        _shows[id] = MediaDetails.fromJson(raw as Map<String, dynamic>);
      } catch (e) {
        debugPrint(
            'Downloads: fiche $id illisible: ${redactPlaybackDiagnostic(e)}');
      }
    }
  }

  Future<void> _loadChromes() async {
    final file = _chromesFile;
    if (file == null || !await file.exists()) return;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        _chromes[entry.key as String] =
            OfflineChrome.fromJson(Map<String, dynamic>.from(value));
      }
    } catch (e) {
      debugPrint(
          'Downloads: playeurs hors ligne illisibles: ${redactPlaybackDiagnostic(e)}');
    }
  }

  File? get _manifestFile {
    final root = _root;
    if (root == null) return null;
    return File(p.join(root.path, 'manifest.json'));
  }

  File? get _chromesFile {
    final root = _root;
    if (root == null) return null;
    return File(p.join(root.path, 'chromes.json'));
  }

  Directory? get _showsDir {
    final root = _root;
    if (root == null) return null;
    return Directory(p.join(root.path, 'shows'));
  }

  Directory? _showDirFor(int infoId) {
    final dir = _showsDir;
    if (dir == null) return null;
    return Directory(p.join(dir.path, '$infoId'));
  }

  void _markDirty() {
    _manifestDirty = true;
    _manifestTimer ??= Timer(const Duration(seconds: 3), () {
      _manifestTimer = null;
      if (_manifestDirty) unawaited(_saveManifest());
    });
  }

  /// Les écritures du manifeste se suivent à la queue leu leu.
  ///
  /// Elles passent toutes par le même fichier temporaire, et deux suppressions
  /// coup sur coup suffisaient à les faire se croiser : la seconde renommait un
  /// `.tmp` que la première venait d'emporter.
  Future<void> _saving = Future<void>.value();

  Future<void> _saveManifest() {
    _manifestDirty = false;
    _saving = _saving.then((_) => _writeManifest());
    return _saving;
  }

  Future<void> _writeManifest() async {
    final file = _manifestFile;
    if (file == null) return;
    try {
      final payload = jsonEncode({
        'version': 1,
        if (_declined.isNotEmpty) 'declined': _declined.toList()..sort(),
        'items': [
          for (final entry in _entries.values) _stamped(entry).toJson(),
          // Ce qui appartient aux autres serveurs est réécrit intact : le
          // manifeste est commun, la carte en mémoire ne l'est pas.
          for (final entry in _otherServers) entry.toJson(),
        ],
      });
      // Écriture puis renommage : une app tuée pendant la sauvegarde laisse
      // l'ancien manifeste intact plutôt qu'un JSON tronqué.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint(
          'Downloads: écriture du manifeste impossible: ${redactPlaybackDiagnostic(e)}');
    }
  }

  /// Une entrée sans adresse date de l'époque mono-serveur : elle appartient à
  /// celui qui est actif, faute de pouvoir appartenir à quelqu'un d'autre.
  bool _inScope(OfflineDownload entry) =>
      entry.serverUrl.isEmpty || entry.serverUrl == _scope;

  OfflineDownload _stamped(OfflineDownload entry) =>
      entry.serverUrl.isEmpty && _scope.isNotEmpty
          ? entry.copyWith(serverUrl: _scope)
          : entry;

  /// Rebranche la liste sur le serveur qui vient de devenir actif.
  ///
  /// Les transferts en cours sur le serveur qu'on quitte redeviennent des
  /// entrées de file : leur reprise se fera au retour, à l'octet près, et
  /// continuer à télécharger depuis une adresse qu'on n'utilise plus n'aurait
  /// pas de sens.
  Future<void> onServerChanged() async {
    final next = OfflineChrome.normalizeServerUrl(_api?.baseUrl ?? '');
    if (next == _scope) return;

    // Le transfert en cours est coupé net : il tire sur une adresse dont on
    // vient de changer. Il repartira à l'octet près au retour.
    for (final token in _cancelTokens.values) {
      token.cancel('server switched');
    }
    _cancelTokens.clear();
    _activeMediaId = null;

    for (final entry in _entries.values) {
      _otherServers.add(_stamped(entry).status == DownloadStatus.downloading
          ? _stamped(entry).copyWith(status: DownloadStatus.queued)
          : _stamped(entry));
    }
    _entries.clear();
    _scope = next;

    final mine = _otherServers.where(_inScope).toList();
    _otherServers.removeWhere(_inScope);
    for (final entry in mine) {
      _entries[entry.mediaId] = entry;
    }

    notifyListeners();
    unawaited(_pump());
  }

  void _notifyThrottled({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastNotify) < const Duration(milliseconds: 400)) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }

  // ==================== Lecture ====================

  OfflineDownload? entryFor(int mediaId) => _entries[mediaId];

  bool isDownloaded(int mediaId) => _entries[mediaId]?.isCompleted ?? false;

  /// Tout ce qui est sur l'appareil pour cette série, dans l'ordre de lecture.
  ///
  /// C'est la vue dont le réapprovisionnement automatique se sert : ce qu'il
  /// reste d'avance, et jusqu'où on est allé, se lisent tous les deux là-dedans.
  List<OfflineDownload> entriesForShow(int showId) {
    final list =
        _entries.values.where((e) => e.showId == showId).toList()
          ..sort((a, b) {
            final season = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
            if (season != 0) return season;
            return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
          });
    return list;
  }

  /// Les séries dont au moins un épisode est sur l'appareil.
  Set<int> get downloadedShowIds => {
        for (final entry in _entries.values)
          if (entry.type == MediaType.episode &&
              entry.showId != null &&
              entry.showId! > 0)
            entry.showId!,
      };

  /// Chemin du fichier local, ou null si le média n'est pas (entièrement) là.
  ///
  /// C'est ce que le lecteur consulte avant d'aller chercher une URL de flux :
  /// une copie locale est préférée même en ligne, elle démarre plus vite et ne
  /// coûte rien au serveur.
  String? localVideoPath(int mediaId) {
    final entry = _entries[mediaId];
    final root = _root;
    if (entry == null || root == null || !entry.isCompleted) return null;
    final path = p.join(root.path, '$mediaId', entry.fileName);
    return File(path).existsSync() ? path : null;
  }

  String? localPosterPath(int mediaId) {
    final entry = _entries[mediaId];
    final root = _root;
    final name = entry?.posterFileName;
    if (entry == null || root == null || name == null) return null;
    final path = p.join(root.path, '$mediaId', name);
    return File(path).existsSync() ? path : null;
  }

  /// Réponse `/api/media/:id/tracks` mise de côté au téléchargement, pour que
  /// les menus audio et sous-titres existent aussi sans serveur.
  Map<String, dynamic>? offlineTracks(int mediaId) => _entries[mediaId]?.tracks;

  /// La fiche rapatriée avec ce média : celle de sa série pour un épisode,
  /// la sienne pour un film. Null quand rien n'a pu être récupéré.
  ///
  /// C'est tout ce que la page de détail affichait — synopsis, genres, note,
  /// distribution, nombre de saisons — disponible sans serveur.
  MediaDetails? offlineDetails(int mediaId) {
    final infoId = _entries[mediaId]?.infoId;
    return infoId == null ? null : _shows[infoId];
  }

  /// La fiche rangée sous cet identifiant, pour un appelant qui le connaît
  /// déjà (l'en-tête d'une série dans la liste, par exemple).
  MediaDetails? detailsForShow(int infoId) => _shows[infoId];

  String? showPosterPath(int infoId) => _showAsset(infoId, 'poster.jpg');

  /// Logo-titre de la série. C'est lui que le lecteur affiche en haut de
  /// l'écran à la place du titre écrit.
  String? showLogoPath(int infoId) => _showAsset(infoId, 'logo.png');

  String? _showAsset(int infoId, String fileName) {
    final dir = _showDirFor(infoId);
    if (dir == null) return null;
    final path = p.join(dir.path, fileName);
    return File(path).existsSync() ? path : null;
  }

  /// Le playeur à appliquer pour ce média : celui du compte du serveur d'où il
  /// a été téléchargé.
  OfflineChrome? chromeFor(int mediaId) {
    final entry = _entries[mediaId];
    if (entry == null || entry.serverUrl.isEmpty) return null;
    return _chromes[entry.serverUrl];
  }

  /// Fige le playeur actif d'un compte.
  ///
  /// Appelé à chaque fois que l'app sait de source sûre quel playeur le compte
  /// utilise — donc à chaque synchronisation réussie, pas seulement au
  /// téléchargement : changer de playeur en ligne doit se voir hors ligne le
  /// soir même, sans avoir à retélécharger quoi que ce soit.
  Future<void> rememberChrome(OfflineChrome chrome) async {
    if (chrome.serverUrl.isEmpty || _root == null) return;
    final existing = _chromes[chrome.serverUrl];
    if (existing != null &&
        existing.presetId == chrome.presetId &&
        existing.useModular == chrome.useModular &&
        existing.config.encode() == chrome.config.encode()) {
      return; // rien de neuf : pas d'écriture disque
    }
    _chromes[chrome.serverUrl] = chrome;
    await _saveChromes();
  }

  Future<void> _saveChromes() async {
    final file = _chromesFile;
    if (file == null) return;
    try {
      final payload = jsonEncode(
        _chromes.map((key, value) => MapEntry(key, value.toJson())),
      );
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint(
          'Downloads: écriture des playeurs impossible: ${redactPlaybackDiagnostic(e)}');
    }
  }

  /// Contenu WebVTT d'une piste rapatriée, ou null.
  Future<String?> offlineSubtitle(int mediaId, String lang) async {
    final entry = _entries[mediaId];
    final root = _root;
    if (entry == null || root == null) return null;
    for (final sub in entry.subtitles) {
      if (sub.lang != lang) continue;
      final file = File(p.join(root.path, '$mediaId', sub.fileName));
      if (await file.exists()) return file.readAsString();
    }
    return null;
  }

  // ==================== Mise en file ====================

  /// Met un film ou un épisode en file. Sans effet si le média y est déjà.
  ///
  /// [showTitle], [showId] et [showPosterUrl] viennent de la page d'où part le
  /// geste : un épisode ne porte pas le nom de sa série, et l'écran des
  /// téléchargements doit pouvoir grouper sans serveur.
  Future<void> download(
    HomeMediaItem item, {
    String? showTitle,
    int? showId,
    int? seasonNumber,
    String? showPosterUrl,
  }) async {
    final queued = await _enqueue(
      item,
      showTitle: showTitle,
      showId: showId,
      seasonNumber: seasonNumber,
      showPosterUrl: showPosterUrl,
    );
    if (!queued) return;
    _markDirty();
    notifyListeners();
    unawaited(_pump());
  }

  /// Met une fournée en file d'un coup — une saison, le reste d'une série, la
  /// réserve d'avance. Renvoie le nombre d'entrées réellement ajoutées.
  ///
  /// La différence avec [download] appelé en boucle n'est pas cosmétique : une
  /// saison de vingt épisodes produirait vingt notifications, vingt écritures
  /// de manifeste et vingt démarrages de file, chacun recalculant l'ordre de
  /// la file entière. Ici, une seule de chaque, à la fin.
  Future<int> downloadAll(
    Iterable<HomeMediaItem> items, {
    String? showTitle,
    int? showId,
    int? seasonNumber,
    String? showPosterUrl,
    bool automatic = false,
  }) async {
    var queued = 0;
    for (final item in items) {
      final added = await _enqueue(
        item,
        automatic: automatic,
        showTitle: showTitle,
        showId: showId,
        // Un lot peut traverser plusieurs saisons (la réserve d'avance passe la
        // fin d'une saison) : le numéro de l'épisode lui-même l'emporte sur
        // celui du lot, qui n'est qu'un repli.
        seasonNumber: item.media.effectiveSeasonNumber ?? seasonNumber,
        showPosterUrl: showPosterUrl,
      );
      if (added) queued++;
    }
    if (queued == 0) return 0;
    _markDirty();
    notifyListeners();
    unawaited(_pump());
    return queued;
  }

  /// Écrit l'entrée dans la carte, sans rien annoncer ni rien démarrer.
  /// Renvoie vrai quand quelque chose de neuf est entré en file.
  Future<bool> _enqueue(
    HomeMediaItem item, {
    String? showTitle,
    int? showId,
    int? seasonNumber,
    String? showPosterUrl,

    /// Vrai quand la demande vient de la réserve automatique et non d'un geste :
    /// elle s'incline alors devant un effacement précédent.
    bool automatic = false,
  }) async {
    final media = item.media;
    if (media.type != MediaType.movie && media.type != MediaType.episode) {
      return false;
    }
    if (!item.isAvailable) return false;
    if (automatic && isDeclined(media.id)) return false;
    _declined.remove(_declineKey(media.id, _scope));
    final existing = _entries[media.id];
    if (existing != null && existing.status != DownloadStatus.failed) {
      // Déjà là, en cours, ou en pause — reprendre est le seul sens possible.
      if (existing.status == DownloadStatus.paused) await resume(media.id);
      return false;
    }

    final entry = OfflineDownload(
      mediaId: media.id,
      type: media.type,
      title: media.title,
      fileName: 'video${_extensionFor(media.filePath)}',
      addedAt: DateTime.now(),
      showTitle: showTitle ?? item.showTitle,
      showId: showId ?? item.showId,
      seasonNumber: seasonNumber ?? media.effectiveSeasonNumber,
      episodeNumber: media.effectiveEpisodeNumber,
      overview: media.overview,
      releaseDate: media.releaseDate,
      serverUrl: OfflineChrome.normalizeServerUrl(_api?.baseUrl ?? ''),
      posterUrl: media.posterUrl,
      showPosterUrl: showPosterUrl ?? item.showPosterUrl,
      durationSeconds: item.effectiveDuration,
      introStart: item.introStart,
      introEnd: item.introEnd,
      outroStart: item.outroStart,
      outroEnd: item.outroEnd,
      positionSeconds: item.currentPositionSeconds,
      isFinished: item.isFinished,
      status: DownloadStatus.queued,
    );

    _entries[media.id] = entry;
    return true;
  }

  /// Extension du fichier d'origine. Le conteneur compte : mpv comme ExoPlayer
  /// choisissent leur démultiplexeur dessus, et un `.mkv` renommé `.bin` ne
  /// s'ouvre pas partout.
  static String _extensionFor(String? filePath) {
    if (filePath == null || filePath.isEmpty) return '.mkv';
    final ext = p.extension(filePath.replaceAll('\\', '/'));
    if (ext.isEmpty || ext.length > 6) return '.mkv';
    return ext.toLowerCase();
  }

  Future<void> pause(int mediaId) async {
    final entry = _entries[mediaId];
    if (entry == null || entry.isCompleted) return;
    _cancelTokens.remove(mediaId)?.cancel('paused');
    _entries[mediaId] = entry.copyWith(status: DownloadStatus.paused);
    _markDirty();
    notifyListeners();
  }

  Future<void> resume(int mediaId) async {
    final entry = _entries[mediaId];
    if (entry == null || entry.isCompleted) return;
    _entries[mediaId] =
        entry.copyWith(status: DownloadStatus.queued, error: null);
    _markDirty();
    notifyListeners();
    unawaited(_pump());
  }

  /// Supprime le média et tout ce qui l'accompagne.
  ///
  /// L'avancement non synchronisé part avec : le fichier n'existe plus, et une
  /// position dans un média absent n'a nulle part où s'afficher. Un appel à
  /// [syncPending] est tenté avant, pour que ce qui pouvait être sauvé le soit.
  Future<void> delete(int mediaId) async {
    _cancelTokens.remove(mediaId)?.cancel('deleted');
    final entry = _entries.remove(mediaId);
    // Effacer un épisode déjà vu ne dit rien de plus que « c'est vu » ; effacer
    // un épisode qu'on n'a pas regardé dit « pas celui-là », et c'est ce qui
    // doit tenir la réserve automatique à distance.
    if (entry != null && !entry.isFinished) {
      _declined.add(_declineKey(mediaId, entry.serverUrl));
    }
    if (entry != null && entry.needsSync) {
      unawaited(_pushProgress(entry));
    }
    if (_activeMediaId == mediaId) _activeMediaId = null;
    final root = _root;
    if (root != null) {
      try {
        final dir = Directory(p.join(root.path, '$mediaId'));
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (e) {
        debugPrint(
            'Downloads: suppression de $mediaId impossible: ${redactPlaybackDiagnostic(e)}');
      }
    }
    if (entry != null) await _dropOrphanShowInfo(entry.infoId);
    await _saveManifest();
    notifyListeners();
    unawaited(_pump());
  }

  /// Efface la fiche d'une série dont plus aucun épisode n'est là.
  ///
  /// Tant qu'il en reste un, la fiche sert : c'est elle qui donne son nom, son
  /// affiche et son logo à ce qui reste dans la liste.
  Future<void> _dropOrphanShowInfo(int? infoId) async {
    if (infoId == null) return;
    if (_entries.values.any((e) => e.infoId == infoId)) return;
    _shows.remove(infoId);
    final dir = _showDirFor(infoId);
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint(
          'Downloads: suppression de la fiche $infoId impossible: ${redactPlaybackDiagnostic(e)}');
    }
  }

  /// Supprime tout ce qui a été vu. Renvoie le nombre d'entrées effacées.
  Future<int> deleteWatched() async {
    final watched = _entries.values
        .where((e) => e.isCompleted && e.isFinished)
        .map((e) => e.mediaId)
        .toList();
    for (final id in watched) {
      await delete(id);
    }
    return watched.length;
  }

  // ==================== La file ====================

  Future<void> _pump() async {
    if (_pumping || !_ready) return;
    _pumping = true;
    try {
      while (true) {
        final next = _entries.values
            .where((e) => e.status == DownloadStatus.queued)
            .toList()
          ..sort((a, b) => a.addedAt.compareTo(b.addedAt));
        if (next.isEmpty) return;
        // La question est posée ici, entre deux médias, et pas à la mise en
        // file : ce qui a été demandé reste demandé, et part dès que le réseau
        // s'y prête. Passer en 4G au milieu d'une saison arrête la suite sans
        // rien perdre de ce qui était prévu.
        if (!_mayTransfer()) {
          _setHeld(true);
          return;
        }
        _setHeld(false);
        final ok = await _run(next.first);
        // Un échec réseau vide la file d'un coup : insister média après média
        // ne ferait qu'aligner les timeouts. La reprise viendra du retour du
        // serveur, pas d'une nouvelle tentative immédiate.
        if (!ok) return;
      }
    } finally {
      _pumping = false;
      await _saveManifest();
    }
  }

  bool _mayTransfer() {
    final gate = transferGate;
    return gate == null || gate();
  }

  void _setHeld(bool held) {
    if (_heldForNetwork == held) return;
    _heldForNetwork = held;
    notifyListeners();
  }

  /// Le réseau a changé, ou l'utilisateur vient d'autoriser celui-ci : ce qui
  /// attendait repart.
  void onNetworkChanged() {
    if (_heldForNetwork && _mayTransfer()) _setHeld(false);
    unawaited(_pump());
  }

  /// Rapatrie un média. Renvoie false quand l'échec vient du réseau, ce qui
  /// arrête la file.
  Future<bool> _run(OfflineDownload entry) async {
    final api = _api;
    final root = _root;
    if (api == null || root == null) return false;

    final mediaId = entry.mediaId;
    final dir = Directory(p.join(root.path, '$mediaId'));
    if (!await dir.exists()) await dir.create(recursive: true);
    // Le dossier vient d'être créé sur la foi d'une entrée que l'utilisateur a
    // pu supprimer entre-temps : sans ce garde-fou, la suite la ferait
    // ressusciter, dossier compris.
    if (!_entries.containsKey(mediaId)) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      return true;
    }
    final target = File(p.join(dir.path, entry.fileName));

    var received = await target.exists() ? await target.length() : 0;
    _activeMediaId = mediaId;
    _entries[mediaId] = entry.copyWith(
      status: DownloadStatus.downloading,
      bytesReceived: received,
      error: null,
    );
    notifyListeners();

    // Les métadonnées d'abord : l'affiche donne une vignette à la ligne pendant
    // que les octets arrivent, et les pistes ne dépendent pas du transfert.
    await _fetchMetadata(api, mediaId, dir);

    final cancelToken = CancelToken();
    _cancelTokens[mediaId] = cancelToken;

    IOSink? sink;
    PlaybackAccess? access;
    try {
      access = await api.openPlaybackAccess(mediaId);
      final response = await _transferDio.get<ResponseBody>(
        api.getStreamUrl(mediaId, access: access),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: received > 0 ? {'Range': 'bytes=$received-'} : null,
          // 416 signifie « tu as déjà tout » — une réponse à traiter, pas une
          // exception à propager.
          validateStatus: (code) => code != null && code < 500,
        ),
      );

      final status = response.statusCode ?? 0;
      if (status == 416) {
        await _complete(mediaId, api, dir, target);
        return true;
      }
      if (status != 200 && status != 206) {
        throw DioException(
          requestOptions: response.requestOptions,
          message: 'HTTP $status',
        );
      }
      if (received > 0 && status == 200) {
        // Le serveur a ignoré le Range et renvoie le fichier entier : repartir
        // de zéro est la seule façon de ne pas concaténer deux débuts.
        received = 0;
      }

      // Supprimé pendant que la réponse arrivait : réécrire l'entrée ici la
      // ferait revenir dans la liste, et le transfert continuerait pour rien.
      final opened = _entries[mediaId];
      if (opened == null) return true;

      final total = _totalBytesOf(response, alreadyHave: received);
      _entries[mediaId] =
          opened.copyWith(bytesTotal: total, bytesReceived: received);
      notifyListeners();

      final out = target.openWrite(
        mode: received > 0 ? FileMode.append : FileMode.write,
      );
      sink = out;

      await for (final chunk in response.data!.stream) {
        out.add(chunk);
        received += chunk.length;
        final current = _entries[mediaId];
        // L'entrée a disparu (suppression) ou a changé d'état (pause) pendant
        // le transfert : on lâche sans écrire par-dessus la décision.
        if (current == null || current.status != DownloadStatus.downloading) {
          await out.close();
          sink = null;
          return current != null;
        }
        _entries[mediaId] = current.copyWith(bytesReceived: received);
        _notifyThrottled();
        _markDirty();
      }

      await out.flush();
      await out.close();
      sink = null;

      await _complete(mediaId, api, dir, target);
      return true;
    } on DioException catch (e) {
      await sink?.close();
      final paused = CancelToken.isCancel(e);
      final current = _entries[mediaId];
      if (current == null) return true; // supprimé en cours de route
      if (paused) {
        // pause() / delete() ont déjà posé l'état voulu.
        _entries[mediaId] = current.copyWith(bytesReceived: received);
        _markDirty();
        notifyListeners();
        return true;
      }
      _entries[mediaId] = current.copyWith(
        status: DownloadStatus.failed,
        bytesReceived: received,
        error: _humanError(e),
      );
      _markDirty();
      notifyListeners();
      return false;
    } catch (e) {
      await sink?.close();
      final current = _entries[mediaId];
      if (current != null) {
        _entries[mediaId] = current.copyWith(
          status: DownloadStatus.failed,
          bytesReceived: received,
          error: redactPlaybackDiagnostic(e),
        );
        _markDirty();
        notifyListeners();
      }
      return false;
    } finally {
      await access?.close();
      _cancelTokens.remove(mediaId);
      if (_activeMediaId == mediaId) _activeMediaId = null;
    }
  }

  /// Taille finale du fichier, déduite de l'en-tête qui la porte.
  ///
  /// En réponse partielle c'est `Content-Range: bytes a-b/total` qui la donne ;
  /// `Content-Length` ne décrit alors que le morceau restant, d'où l'addition
  /// avec ce qui est déjà sur le disque.
  static int _totalBytesOf(Response<ResponseBody> response,
      {required int alreadyHave}) {
    final range = response.headers.value('content-range');
    if (range != null) {
      final slash = range.lastIndexOf('/');
      if (slash > 0) {
        final parsed = int.tryParse(range.substring(slash + 1).trim());
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    final length = int.tryParse(response.headers.value('content-length') ?? '');
    if (length != null && length > 0) return length + alreadyHave;
    return 0;
  }

  static String _humanError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.connectionError:
        return 'Serveur injoignable';
      case DioExceptionType.receiveTimeout:
        return 'Transfert interrompu';
      default:
        return e.message ?? 'Téléchargement impossible';
    }
  }

  Future<void> _complete(
    int mediaId,
    ApiClient api,
    Directory dir,
    File target,
  ) async {
    final entry = _entries[mediaId];
    if (entry == null) return;
    final size = await target.exists() ? await target.length() : 0;
    _entries[mediaId] = entry.copyWith(
      status: DownloadStatus.completed,
      bytesReceived: size,
      bytesTotal: size,
      completedAt: DateTime.now(),
      error: null,
    );
    _markDirty();
    notifyListeners();

    // Les sous-titres en dernier : le serveur les extrait paresseusement, et
    // il a eu tout le transfert pour finir.
    await _fetchSubtitles(api, mediaId, dir);
    await _saveManifest();
    notifyListeners();
  }

  /// Affiche et liste des pistes. Tout est facultatif : rien de ce qui échoue
  /// ici n'empêche de regarder le média hors ligne.
  Future<void> _fetchMetadata(ApiClient api, int mediaId, Directory dir) async {
    final entry = _entries[mediaId];
    if (entry == null) return;

    if (entry.tracks == null) {
      try {
        final tracks = await api.getMediaTracksJson(mediaId);
        _entries[mediaId] = _entries[mediaId]!.copyWith(tracks: tracks);
        _markDirty();
      } catch (e) {
        debugPrint(
            'Downloads: pistes de $mediaId indisponibles: ${redactPlaybackDiagnostic(e)}');
      }
    }

    if (entry.posterFileName == null) {
      final url = resolvePosterUrl(
        entry.posterUrl ?? entry.showPosterUrl,
        serverBaseUrl: api.baseUrl,
      );
      if (url != null &&
          await _downloadImage(
            tmdbSizedUrl(url, 'w500'),
            File(p.join(dir.path, 'poster.jpg')),
          )) {
        final current = _entries[mediaId];
        if (current != null) {
          _entries[mediaId] = current.copyWith(posterFileName: 'poster.jpg');
          _markDirty();
        }
      }
    }

    await _fetchShowInfo(api, mediaId);
  }

  /// Rapatrie la fiche de la série (ou du film) à côté du média.
  ///
  /// Un épisode seul ne dit rien de ce qu'il est : ni synopsis de la série, ni
  /// affiche verticale, ni logo-titre. Sans cette fiche, un téléchargement
  /// s'affiche hors ligne sous un titre nu, et le lecteur ouvre sur du texte là
  /// où il montre d'habitude le logo de la série.
  ///
  /// Elle est rangée **une fois par série** et partagée par tous ses épisodes :
  /// la vingtième descente d'une saison n'écrit rien de plus que la première.
  /// Tout y est facultatif — rien de ce qui échoue ici n'empêche de regarder.
  Future<void> _fetchShowInfo(ApiClient api, int mediaId) async {
    final infoId = _entries[mediaId]?.infoId;
    final dir = infoId == null ? null : _showDirFor(infoId);
    if (infoId == null || dir == null) return;
    // Déjà là : une série ne change pas de synopsis entre deux épisodes.
    if (_shows.containsKey(infoId)) return;

    try {
      final raw = await api.getMediaDetailsJson(infoId);
      final details = MediaDetails.fromJson(raw);
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(p.join(dir.path, 'details.json'))
          .writeAsString(jsonEncode(raw), flush: true);
      _shows[infoId] = details;
      notifyListeners();

      // L'affiche verticale de la série et son logo-titre : les deux images que
      // l'app dessine à partir d'une fiche, donc les deux qui manqueraient.
      final poster =
          detailPosterUrl(details.posterUrl, serverBaseUrl: api.baseUrl);
      if (poster != null) {
        await _downloadImage(poster, File(p.join(dir.path, 'poster.jpg')));
      }
      final logo = logoImageUrl(details.logoUrl, serverBaseUrl: api.baseUrl);
      if (logo != null) {
        await _downloadImage(logo, File(p.join(dir.path, 'logo.png')));
      }
      notifyListeners();
    } catch (e) {
      debugPrint(
          'Downloads: fiche de $infoId indisponible: ${redactPlaybackDiagnostic(e)}');
    }
  }

  /// Écrit une image distante dans [target]. Renvoie false sur le moindre
  /// accroc — une vignette absente se dessine en aplat, ce n'est pas une panne.
  ///
  /// Les octets sont aussi classés dans le magasin d'images partagé, **sous
  /// l'URL d'origine**. C'est ce qui fait qu'une affiche ou un logo-titre
  /// rapatriés s'affichent hors ligne partout où l'app les dessine — chrome du
  /// lecteur compris — sans qu'aucun widget ait à savoir qu'il existe une copie
  /// locale : il demande la même URL qu'en ligne, et la trouve sur le disque.
  Future<bool> _downloadImage(String url, File target) async {
    try {
      final response = await _transferDio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return false;
      await target.writeAsBytes(bytes, flush: true);
      try {
        await AppImageCache.manager.putFile(
          url,
          Uint8List.fromList(bytes),
          // Bien au-delà de la péremption d'hygiène du magasin : tant que le
          // média est sur l'appareil, son artwork doit l'être aussi.
          maxAge: const Duration(days: 365),
          fileExtension: p.extension(target.path).replaceFirst('.', ''),
        );
      } catch (e) {
        debugPrint(
            'Downloads: mise en cache de $url impossible: ${redactPlaybackDiagnostic(e)}');
      }
      return true;
    } catch (e) {
      debugPrint(
          'Downloads: image indisponible ($url): ${redactPlaybackDiagnostic(e)}');
      return false;
    }
  }

  /// Rapatrie les WebVTT que le serveur sait produire.
  ///
  /// Les pistes internes au conteneur sont ignorées : elles voyagent dans le
  /// fichier et le moteur les trouve tout seul. Ce sont celles que le lecteur
  /// injecte par leur contenu qui, sans copie locale, disparaîtraient hors
  /// ligne. Les pistes bitmap n'ont pas de `.vtt` du tout.
  Future<void> _fetchSubtitles(
      ApiClient api, int mediaId, Directory dir) async {
    final entry = _entries[mediaId];
    final tracks = entry?.tracks;
    if (entry == null || tracks == null) return;

    final subs = (tracks['subtitles'] as List?) ?? const [];
    final saved = <OfflineSubtitle>[];
    for (final raw in subs) {
      if (raw is! Map) continue;
      final lang = raw['lang'] as String? ?? '';
      if (lang.isEmpty || raw['image'] == true) continue;
      if (saved.any((s) => s.lang == lang)) continue;
      try {
        final vtt = await api.fetchSubtitleContent(mediaId, lang);
        if (!vtt.contains('-->')) continue;
        final fileName = 'sub_$lang.vtt';
        await File(p.join(dir.path, fileName)).writeAsString(vtt, flush: true);
        saved.add(OfflineSubtitle(
          lang: lang,
          name: raw['name'] as String? ?? lang,
          fileName: fileName,
        ));
      } catch (e) {
        debugPrint(
            'Downloads: sous-titre $lang de $mediaId indisponible: ${redactPlaybackDiagnostic(e)}');
      }
    }
    if (saved.isEmpty) return;
    final current = _entries[mediaId];
    if (current == null) return;
    _entries[mediaId] = current.copyWith(subtitles: saved);
    _markDirty();
  }

  // ==================== Avancement ====================

  /// Enregistre une position de lecture localement.
  ///
  /// Appelé pour tout média téléchargé, en ligne comme hors ligne : c'est ce
  /// qui permet à l'écran des téléchargements de montrer un épisode vu même
  /// quand il a été regardé depuis la bibliothèque. [needsSync] n'est posé que
  /// lorsque le serveur n'a pas pu confirmer.
  Future<void> recordProgress({
    required int mediaId,
    required int positionSeconds,
    required int durationSeconds,
    required bool isFinished,
    bool syncedWithServer = false,
  }) async {
    final entry = _entries[mediaId];
    if (entry == null) return;

    // La règle des 90 % est celle du serveur ; l'appliquer ici aussi évite
    // qu'un épisode fini hors ligne attende la reconnexion pour compter comme vu.
    var finished = isFinished;
    final duration =
        durationSeconds > 0 ? durationSeconds : entry.durationSeconds;
    if (!finished && duration > 0 && positionSeconds > 0) {
      finished = (positionSeconds / duration) * 100 >= 90.0;
    }

    _entries[mediaId] = entry.copyWith(
      positionSeconds: positionSeconds,
      isFinished: finished,
      durationSeconds: duration,
      progressUpdatedAt: DateTime.now(),
      needsSync: !syncedWithServer,
    );
    _markDirty();
    notifyListeners();
  }

  /// Position de reprise connue localement, ou null si le média n'est pas là.
  int? localResumeSeconds(int mediaId) {
    final entry = _entries[mediaId];
    if (entry == null) return null;
    if (entry.isFinished) return 0;
    return entry.positionSeconds;
  }

  /// Rejoue vers le serveur tout l'avancement qu'il ne connaît pas encore.
  ///
  /// Chaque envoi porte l'heure locale de la lecture : le serveur refuse
  /// d'écraser une progression plus récente venue d'un autre appareil, ce qui
  /// rend la reconnexion sûre même une semaine après.
  Future<void> syncPending() async {
    final api = _api;
    if (api == null) return;
    final pending = _entries.values.where((e) => e.needsSync).toList();
    if (pending.isEmpty) return;

    var changed = false;
    for (final entry in pending) {
      if (await _pushProgress(entry)) {
        final current = _entries[entry.mediaId];
        if (current == null) continue;
        // Seul le rejeu qui vient d'aboutir est acquitté : une lecture
        // survenue entre-temps garde son drapeau.
        if (current.progressUpdatedAt == entry.progressUpdatedAt) {
          _entries[entry.mediaId] = current.copyWith(needsSync: false);
          changed = true;
        }
      }
    }
    if (changed) {
      await _saveManifest();
      notifyListeners();
    }
  }

  Future<bool> _pushProgress(OfflineDownload entry) async {
    final api = _api;
    if (api == null) return false;
    try {
      if (entry.isFinished && entry.positionSeconds <= 0) {
        // Marqué vu sans position (fin d'épisode remise à zéro) : la route
        // « vu » est la seule qui exprime ça.
        await api.setMediaWatched(entry.mediaId, true);
        return true;
      }
      await api.sendProgress(
        mediaId: entry.mediaId,
        currentPositionSeconds: entry.positionSeconds,
        duration: entry.durationSeconds,
        isFinished: entry.isFinished,
        clientUpdatedAt: entry.progressUpdatedAt,
      );
      return true;
    } catch (e) {
      debugPrint(
          'Downloads: resynchronisation de ${entry.mediaId} impossible: ${redactPlaybackDiagnostic(e)}');
      return false;
    }
  }

  /// Le serveur est de nouveau joignable : on lui doit l'avancement pris hors
  /// ligne, et la file reprend là où la coupure l'avait laissée.
  Future<void> onServerReachable() async {
    await syncPending();
    var restarted = false;
    for (final entry in _entries.values.toList()) {
      if (entry.status == DownloadStatus.failed) {
        _entries[entry.mediaId] =
            entry.copyWith(status: DownloadStatus.queued, error: null);
        restarted = true;
      }
    }
    if (restarted) notifyListeners();
    unawaited(_pump());
  }

  @override
  void dispose() {
    _manifestTimer?.cancel();
    for (final token in _cancelTokens.values) {
      token.cancel('dispose');
    }
    super.dispose();
  }
}
