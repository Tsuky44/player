import 'media_request.dart';

/// Ce que la recherche interactive cherche : une saison entière (`season`
/// seule) ou un épisode (`season` et `episode`) d'une série (ADR-0098).
class RequestReleaseTarget {
  const RequestReleaseTarget({
    required this.tmdbId,
    required this.season,
    this.episode,
  });

  final int tmdbId;
  final int season;
  final int? episode;

  Map<String, dynamic> toQuery() => {
        'tmdbId': tmdbId,
        'type': RequestMediaType.tv.name,
        'season': season,
        if (episode != null) 'episode': episode,
      };
}

/// L'ordre de la liste des releases. [recommended] est celui du compagnon :
/// sorraa range d'abord les releases qu'il prendrait, la meilleure en tête.
enum ReleaseSort { recommended, seeders, size, newest }

/// Une proposition d'un indexeur, telle que MediaHub la rend à travers le
/// serveur (`GET /api/requests/releases`).
///
/// Avec sorraa, [id] est un jeton de 30 minutes, il n'y a pas d'adresse et
/// [accepted] dit si son moteur la prendrait ([rejections] dit pourquoi non).
/// Avec Radarr/Sonarr, [id] est le guid de l'indexeur et la release porte son
/// adresse : ils ne jugent rien avant l'envoi.
class RequestRelease {
  const RequestRelease({
    required this.id,
    required this.title,
    required this.size,
    required this.indexer,
    required this.indexerId,
    required this.ageDays,
    required this.protocol,
    this.publishDate,
    this.seeders,
    this.leechers,
    this.downloadUrl,
    this.magnetUrl,
    this.accepted,
    this.rejections = const [],
  });

  final String id;
  final String title;

  /// En octets.
  final int size;
  final String indexer;
  final int indexerId;
  final double ageDays;

  /// `torrent` ou `usenet`.
  final String protocol;
  final String? publishDate;

  /// Absents chez Usenet, et chez les indexeurs qui ne les donnent pas.
  final int? seeders;
  final int? leechers;
  final String? downloadUrl;
  final String? magnetUrl;

  /// Le verdict de sorraa ; nul chez Radarr/Sonarr.
  final bool? accepted;

  /// Pourquoi sorraa ne la prendrait pas d'office, en français.
  final List<String> rejections;

  factory RequestRelease.fromJson(Map<String, dynamic> json) {
    String? text(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    return RequestRelease(
      id: text(json['id']) ?? text(json['guid']) ?? '',
      title: json['title'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      indexer: json['indexer'] as String? ?? '',
      indexerId: (json['indexerId'] as num?)?.toInt() ?? 0,
      ageDays: (json['age'] as num?)?.toDouble() ?? 0,
      protocol: json['protocol'] as String? ?? '',
      publishDate: text(json['publishDate']),
      seeders: (json['seeders'] as num?)?.toInt(),
      leechers: (json['leechers'] as num?)?.toInt(),
      downloadUrl: text(json['downloadUrl']),
      magnetUrl: text(json['magnetUrl']),
      accepted: json['accepted'] as bool?,
      rejections: [
        for (final reason in json['rejections'] as List<dynamic>? ?? const [])
          if (reason is String) reason,
      ],
    );
  }

  /// Le corps de `POST /api/requests/releases/grab`. Avec sorraa le jeton
  /// suffit ; Radarr/Sonarr ne connaissent pas la release, MediaHub la leur
  /// donne en entier : on renvoie donc tout ce que la liste a rendu.
  Map<String, dynamic> toGrabJson(RequestReleaseTarget target) => {
        'tmdbId': target.tmdbId,
        'mediaType': RequestMediaType.tv.name,
        'season': target.season,
        if (target.episode != null) 'episode': target.episode,
        'release': {
          'id': id,
          'indexerId': indexerId,
          'title': title,
          if (downloadUrl != null) 'downloadUrl': downloadUrl,
          if (magnetUrl != null) 'magnetUrl': magnetUrl,
          if (protocol.isNotEmpty) 'protocol': protocol,
          if (publishDate != null) 'publishDate': publishDate,
          if (indexer.isNotEmpty) 'indexer': indexer,
          if (size > 0) 'size': size,
        },
      };

  /// Il y a de quoi la télécharger : un jeton de sorraa (qui juge, donc
  /// [accepted] est renseigné), ou une adresse pour Radarr/Sonarr.
  bool get isDownloadable =>
      id.isNotEmpty &&
      (accepted != null || downloadUrl != null || magnetUrl != null);

  /// Sorraa la prendrait d'office. Faux aussi quand rien ne la juge : seule une
  /// release qu'un moteur a refusée est présentée comme telle.
  bool get isRejected => accepted == false;

  static final _words = RegExp(r'[^A-Za-z0-9]+');

  /// Ce que le nom de la release annonce : définition, source, langue. Les
  /// indexeurs n'ont pas de champ pour cela, c'est le nom qui le porte
  /// (`Show.S02E03.MULTi.1080p.WEB.H264-GRP`).
  List<String> get tags {
    final found = <String>[];
    final words = title.toUpperCase().split(_words).toSet();
    const resolutions = {
      '2160P': '4K',
      '4K': '4K',
      'UHD': '4K',
      '1080P': '1080p',
      '720P': '720p',
      '480P': '480p',
    };
    for (final entry in resolutions.entries) {
      if (words.contains(entry.key) && !found.contains(entry.value)) {
        found.add(entry.value);
      }
    }
    const sources = {
      'REMUX': 'Remux',
      'BLURAY': 'BluRay',
      'WEB': 'WEB',
      'WEBDL': 'WEB',
      'WEBRIP': 'WEB',
      'HDTV': 'HDTV',
    };
    for (final entry in sources.entries) {
      if (words.contains(entry.key) && !found.contains(entry.value)) {
        found.add(entry.value);
        break;
      }
    }
    const languages = {
      'MULTI': 'MULTI',
      'TRUEFRENCH': 'VFF',
      'VFF': 'VFF',
      'FRENCH': 'VF',
      'VF': 'VF',
      'VOSTFR': 'VOSTFR',
    };
    for (final entry in languages.entries) {
      if (words.contains(entry.key)) {
        found.add(entry.value);
        break;
      }
    }
    return found;
  }

  /// [releases] filtrées par les mots de [query] (tous doivent figurer dans le
  /// nom ou chez l'indexeur, sans tenir compte de la casse), puis rangées. Une
  /// égalité se départage par le nom, pour que la liste ne saute pas d'un
  /// rafraîchissement à l'autre.
  static List<RequestRelease> listing(
    List<RequestRelease> releases, {
    String query = '',
    ReleaseSort sort = ReleaseSort.recommended,
  }) {
    final words = query
        .toLowerCase()
        .split(_words)
        .where((word) => word.isNotEmpty)
        .toList();
    final kept = releases.where((release) {
      final haystack = '${release.title} ${release.indexer}'.toLowerCase();
      return words.every(haystack.contains);
    }).toList();
    // L'ordre du compagnon se garde tel quel : `List.sort` n'est pas stable.
    if (sort == ReleaseSort.recommended) return kept;
    int byName(RequestRelease a, RequestRelease b) =>
        a.title.compareTo(b.title);
    kept.sort(switch (sort) {
      ReleaseSort.recommended => (a, b) => 0,
      ReleaseSort.seeders => (a, b) {
          final diff = (b.seeders ?? -1).compareTo(a.seeders ?? -1);
          return diff != 0 ? diff : byName(a, b);
        },
      ReleaseSort.size => (a, b) {
          final diff = b.size.compareTo(a.size);
          return diff != 0 ? diff : byName(a, b);
        },
      ReleaseSort.newest => (a, b) {
          final diff = a.ageDays.compareTo(b.ageDays);
          return diff != 0 ? diff : byName(a, b);
        },
    });
    return kept;
  }
}
