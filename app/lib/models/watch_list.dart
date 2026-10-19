import '../l10n/tr.dart';
import 'media.dart';
import 'media_request.dart';

/// Les listes d'un compte : « À regarder plus tard » et les siennes, partagées
/// ou non avec les autres comptes du serveur (ADR-0070).
enum WatchListKind {
  /// La liste que chaque compte a d'office : elle ne se renomme ni ne se
  /// supprime.
  watchLater,
  custom;

  static WatchListKind parse(String? wire) =>
      wire == 'watch_later' ? WatchListKind.watchLater : WatchListKind.custom;
}

/// Ce qu'une liste range : un film ou une série.
enum WatchListMediaType {
  movie,
  show;

  static WatchListMediaType parse(String? wire) =>
      wire == 'show' ? WatchListMediaType.show : WatchListMediaType.movie;

  String get wire => name;
}

class WatchListOwner {
  const WatchListOwner({required this.id, required this.username});

  final int id;
  final String username;

  factory WatchListOwner.fromJson(Map<String, dynamic> json) => WatchListOwner(
        id: (json['id'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
      );
}

/// Le résumé d'une liste : ce que montrent la page des listes et la feuille
/// « Ajouter à une liste ».
class WatchList {
  const WatchList({
    required this.id,
    required this.kind,
    required this.name,
    required this.description,
    required this.isShared,
    required this.isMine,
    required this.owner,
    required this.itemCount,
    required this.posters,
    this.updatedAt,
    this.containsItemId,
  });

  final int id;
  final WatchListKind kind;
  final String name;
  final String description;
  final bool isShared;
  final bool isMine;
  final WatchListOwner owner;
  final int itemCount;

  /// Les affiches des derniers ajouts, quatre au plus.
  final List<String> posters;
  final DateTime? updatedAt;

  /// L'élément de cette liste qui porte le titre demandé, 0 s'il n'y est pas ;
  /// null quand rien n'a été demandé.
  final int? containsItemId;

  bool get isWatchLater => kind == WatchListKind.watchLater;

  /// Le nom à afficher : celui de « À regarder plus tard » suit la langue de
  /// l'interface, le serveur n'en range qu'une version.
  String get displayName => isWatchLater ? tr('À regarder plus tard') : name;

  /// Un élément en cours d'ajout porte un identifiant négatif : il compte
  /// déjà comme présent.
  bool get contains => (containsItemId ?? 0) != 0;

  factory WatchList.fromJson(Map<String, dynamic> json) => WatchList(
        id: (json['id'] as num).toInt(),
        kind: WatchListKind.parse(json['kind'] as String?),
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        isShared: json['is_shared'] as bool? ?? false,
        isMine: json['is_mine'] as bool? ?? false,
        owner: WatchListOwner.fromJson(
            Map<String, dynamic>.from(json['owner'] as Map? ?? const {})),
        itemCount: (json['item_count'] as num?)?.toInt() ?? 0,
        posters: (json['posters'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
        containsItemId: (json['contains_item_id'] as num?)?.toInt(),
      );

  /// La même liste avec un titre de plus ou de moins, en attendant que le
  /// serveur confirme.
  WatchList withMembership(int itemId) => WatchList(
        id: id,
        kind: kind,
        name: name,
        description: description,
        isShared: isShared,
        isMine: isMine,
        owner: owner,
        itemCount: itemCount +
            (itemId != 0 && !contains
                ? 1
                : itemId == 0 && contains
                    ? -1
                    : 0),
        posters: posters,
        updatedAt: updatedAt,
        containsItemId: itemId,
      );
}

/// Un film ou une série d'une liste, sur le serveur ou pas encore.
class WatchListItem {
  const WatchListItem({
    required this.id,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    required this.posterUrl,
    required this.releaseDate,
    required this.mediaId,
    this.addedAt,
    this.media,
  });

  final int id;
  final WatchListMediaType mediaType;
  final int tmdbId;
  final String title;
  final String posterUrl;
  final String releaseDate;
  final DateTime? addedAt;

  /// La fiche du serveur, 0 quand il n'a pas (ou plus) ce titre.
  final int mediaId;

  /// Cette fiche, avec la progression du compte qui lit la liste.
  final HomeMediaItem? media;

  /// Le serveur a ce titre : il s'ouvre sur sa fiche.
  bool get isOnServer => media != null;

  String? get year =>
      releaseDate.length >= 4 ? releaseDate.substring(0, 4) : null;

  factory WatchListItem.fromJson(Map<String, dynamic> json) {
    final media = json['media'];
    return WatchListItem(
      id: (json['id'] as num).toInt(),
      mediaType: WatchListMediaType.parse(json['media_type'] as String?),
      tmdbId: (json['tmdb_id'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      posterUrl: json['poster_url'] as String? ?? '',
      releaseDate: json['release_date'] as String? ?? '',
      addedAt: DateTime.tryParse(json['added_at'] as String? ?? ''),
      mediaId: (json['media_id'] as num?)?.toInt() ?? 0,
      media: media is Map
          ? HomeMediaItem.fromJson(Map<String, dynamic>.from(media))
          : null,
    );
  }

  /// Le titre tel que le catalogue des demandes l'ouvre, pour ce que le
  /// serveur n'a pas.
  RequestMediaItem toRequestItem() => RequestMediaItem(
        id: tmdbId,
        mediaType: mediaType == WatchListMediaType.show
            ? RequestMediaType.tv
            : RequestMediaType.movie,
        title: title,
        overview: '',
        posterPath: _tmdbPath(posterUrl),
        backdropPath: null,
        releaseDate: releaseDate.isEmpty ? null : releaseDate,
        rating: 0,
        status: RequestMediaStatus.unknown,
      );

  /// Le chemin TMDB d'une affiche (`/abc.jpg`), que [RequestMediaItem]
  /// recompose ; null pour une autre adresse.
  static String? _tmdbPath(String url) {
    final marker = url.indexOf('/t/p/');
    if (marker < 0) return null;
    final slash = url.indexOf('/', marker + 5);
    return slash < 0 ? null : url.substring(slash);
  }
}

/// Une liste et son contenu, du plus récent ajout au plus ancien.
class WatchListDetail {
  const WatchListDetail({required this.list, required this.items});

  final WatchList list;
  final List<WatchListItem> items;

  factory WatchListDetail.fromJson(Map<String, dynamic> json) =>
      WatchListDetail(
        list: WatchList.fromJson(json),
        items: (json['items'] as List<dynamic>? ?? const [])
            .map((e) =>
                WatchListItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// Les listes du compte, « À regarder plus tard » en tête, et celles que les
/// autres comptes partagent.
class WatchListsOverview {
  const WatchListsOverview({required this.mine, required this.shared});

  static const empty = WatchListsOverview(mine: [], shared: []);

  final List<WatchList> mine;
  final List<WatchList> shared;

  factory WatchListsOverview.fromJson(Map<String, dynamic> json) {
    List<WatchList> read(String key) =>
        (json[key] as List<dynamic>? ?? const [])
            .map((e) => WatchList.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
    return WatchListsOverview(mine: read('mine'), shared: read('shared'));
  }
}

/// Un titre qu'on peut ranger dans une liste : une fiche du serveur, ou un
/// titre du catalogue que le serveur n'a peut-être pas.
class ListableTitle {
  const ListableTitle._({
    required this.title,
    this.mediaId = 0,
    this.tmdbId = 0,
    this.mediaType = WatchListMediaType.movie,
    this.posterPath,
    this.releaseDate,
  });

  /// Un film ou une série du serveur.
  factory ListableTitle.server(Media media) => ListableTitle._(
        title: media.title,
        mediaId: media.id,
        mediaType: media.type == MediaType.show
            ? WatchListMediaType.show
            : WatchListMediaType.movie,
      );

  /// Un titre du catalogue des demandes.
  factory ListableTitle.catalog(RequestMediaItem item) => ListableTitle._(
        title: item.title,
        tmdbId: item.id,
        mediaType: item.mediaType == RequestMediaType.tv
            ? WatchListMediaType.show
            : WatchListMediaType.movie,
        posterPath: item.posterPath,
        releaseDate: item.releaseDate,
      );

  final String title;
  final int mediaId;
  final int tmdbId;
  final WatchListMediaType mediaType;
  final String? posterPath;
  final String? releaseDate;

  bool get isOnServer => mediaId > 0;

  /// Le corps de `POST /api/lists/:id/items`.
  Map<String, dynamic> toJson() => isOnServer
      ? {'media_id': mediaId}
      : {
          'tmdb_id': tmdbId,
          'media_type': mediaType.wire,
          'title': title,
          if (posterPath != null && posterPath!.isNotEmpty)
            'poster_path': posterPath,
          if (releaseDate != null && releaseDate!.isNotEmpty)
            'release_date': releaseDate,
        };

  /// La question de `GET /api/lists` : dans quelles listes est ce titre.
  Map<String, dynamic> get probe => isOnServer
      ? {'media_id': mediaId}
      : {'tmdb_id': tmdbId, 'media_type': mediaType.wire};
}
