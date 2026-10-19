/// Une affiche qu'un site d'images (TMDB, Fanart.tv) propose pour une fiche
/// (ADR-0068). [url] est ce que le serveur enregistrera si on la choisit ;
/// [thumbUrl], une version réduite pour la grille du choix.
class RemotePoster {
  final String url;
  final String thumbUrl;

  /// `tmdb` ou `fanart`.
  final String source;

  /// Code ISO 639-1 du texte de l'affiche ; null quand elle n'en a pas.
  final String? language;
  final int width;
  final int height;
  final double rating;
  final int votes;

  const RemotePoster({
    required this.url,
    required this.thumbUrl,
    required this.source,
    this.language,
    this.width = 0,
    this.height = 0,
    this.rating = 0,
    this.votes = 0,
  });

  /// Le nom du site, tel qu'on l'affiche sous la vignette.
  String get sourceLabel => source == 'fanart' ? 'Fanart.tv' : 'TMDB';

  factory RemotePoster.fromJson(Map<String, dynamic> json) {
    final url = json['url'] as String? ?? '';
    final language = json['language'] as String?;
    return RemotePoster(
      url: url,
      thumbUrl: json['thumb_url'] as String? ?? url,
      source: json['source'] as String? ?? 'tmdb',
      language: language == null || language.isEmpty ? null : language,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      votes: (json['votes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Les affiches proposées pour une fiche, et celle qu'elle porte aujourd'hui
/// (`GET /api/media/:id/images/posters`).
class RemotePosters {
  /// L'affiche enregistrée aujourd'hui.
  final String? current;

  /// [current] a été choisie à la main : l'enrichissement automatique ne la
  /// remplace plus, et « Affiche par défaut » a un sens.
  final bool locked;

  /// Une clé Fanart.tv est réglée sur le serveur.
  final bool fanartEnabled;
  final List<RemotePoster> images;

  const RemotePosters({
    this.current,
    this.locked = false,
    this.fanartEnabled = false,
    this.images = const [],
  });

  factory RemotePosters.fromJson(Map<String, dynamic> json) {
    final current = json['current'] as String?;
    return RemotePosters(
      current: current == null || current.isEmpty ? null : current,
      locked: json['locked'] as bool? ?? false,
      fanartEnabled: json['fanart_enabled'] as bool? ?? false,
      images: (json['images'] as List? ?? const [])
          .map((e) => RemotePoster.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((p) => p.url.isNotEmpty)
          .toList(),
    );
  }
}
