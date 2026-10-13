/// Comment le contenu d'une bibliothèque se lit.
enum LibraryKind {
  /// Un fichier vidéo est une œuvre.
  movies('movies'),

  /// Les fichiers sont des épisodes, rangés par série et par saison.
  shows('shows'),

  /// Ni l'un ni l'autre — vidéos de famille, concerts, cours. Chaque vidéo
  /// porte le nom de son fichier, et le serveur ne cherche pas à la
  /// reconnaître.
  other('other');

  const LibraryKind(this.wire);

  /// La valeur échangée avec le serveur.
  final String wire;

  /// Un type que cette version de l'app ne connaît pas se lit comme [movies] :
  /// une grille de vidéos, ce que toute bibliothèque sait au moins être.
  static LibraryKind parse(String? wire) => LibraryKind.values.firstWhere(
        (kind) => kind.wire == wire,
        orElse: () => LibraryKind.movies,
      );
}

/// Une bibliothèque du serveur : un dossier de médias et le nom que son
/// administrateur lui a donné (ADR-0058). L'app n'en suppose aucune — ses
/// onglets sont ceux que le serveur liste.
class MediaLibrary {
  const MediaLibrary({
    required this.id,
    required this.name,
    required this.kind,
    this.path,
  });

  final int id;
  final String name;
  final LibraryKind kind;

  /// Le dossier, tel que le serveur le voit. Null pour un compte qui
  /// n'administre pas le serveur : il ne lui est pas envoyé.
  final String? path;

  /// Les deux bibliothèques d'un serveur d'avant les bibliothèques, qui n'a
  /// qu'une liste de films et une liste de séries. Leurs identifiants négatifs
  /// disent à [ApiClient] de lire ces deux listes entières.
  static const List<MediaLibrary> legacy = [
    MediaLibrary(id: -1, name: 'Films', kind: LibraryKind.movies),
    MediaLibrary(id: -2, name: 'Séries', kind: LibraryKind.shows),
  ];

  /// Vrai pour une bibliothèque que le serveur ne connaît pas sous ce nom :
  /// elle ne se renomme ni ne se supprime.
  bool get isLegacy => id < 0;

  factory MediaLibrary.fromJson(Map<String, dynamic> json) {
    final path = json['path'] as String?;
    return MediaLibrary(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      kind: LibraryKind.parse(json['kind'] as String?),
      path: path == null || path.isEmpty ? null : path,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaLibrary &&
      other.id == id &&
      other.name == name &&
      other.kind == kind &&
      other.path == path;

  @override
  int get hashCode => Object.hash(id, name, kind, path);
}
