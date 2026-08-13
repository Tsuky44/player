/// TMDB discover filters — same fields as MediaHub MediaFiltersValue.
class RequestCatalogFilters {
  final String sortBy;
  final String startDate;
  final String endDate;
  final List<int> genres;
  final String language;
  final String minDuration;
  final String maxDuration;
  final String watchRegion;
  final List<int> watchProviders;

  const RequestCatalogFilters({
    this.sortBy = 'popularity.desc',
    this.startDate = '',
    this.endDate = '',
    this.genres = const [],
    this.language = 'all',
    this.minDuration = '',
    this.maxDuration = '',
    this.watchRegion = 'FR',
    this.watchProviders = const [],
  });

  static const defaults = RequestCatalogFilters();

  bool get isDefault =>
      sortBy == defaults.sortBy &&
      startDate.isEmpty &&
      endDate.isEmpty &&
      genres.isEmpty &&
      language == defaults.language &&
      minDuration.isEmpty &&
      maxDuration.isEmpty &&
      watchRegion == defaults.watchRegion &&
      watchProviders.isEmpty;

  bool get hasDiscoverParams => !isDefault;

  RequestCatalogFilters copyWith({
    String? sortBy,
    String? startDate,
    String? endDate,
    List<int>? genres,
    String? language,
    String? minDuration,
    String? maxDuration,
    String? watchRegion,
    List<int>? watchProviders,
  }) {
    return RequestCatalogFilters(
      sortBy: sortBy ?? this.sortBy,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      genres: genres ?? this.genres,
      language: language ?? this.language,
      minDuration: minDuration ?? this.minDuration,
      maxDuration: maxDuration ?? this.maxDuration,
      watchRegion: watchRegion ?? this.watchRegion,
      watchProviders: watchProviders ?? this.watchProviders,
    );
  }

  Map<String, String> toQueryParams() {
    final map = <String, String>{'sort_by': sortBy};
    if (startDate.isNotEmpty) map['start_date'] = startDate;
    if (endDate.isNotEmpty) map['end_date'] = endDate;
    if (genres.isNotEmpty) map['genres'] = genres.join(',');
    if (language.isNotEmpty && language != 'all') {
      map['language'] = language;
    }
    if (minDuration.isNotEmpty) map['min_duration'] = minDuration;
    if (maxDuration.isNotEmpty) map['max_duration'] = maxDuration;
    if (watchRegion.isNotEmpty) map['watch_region'] = watchRegion;
    if (watchProviders.isNotEmpty) {
      map['watch_providers'] = watchProviders.join('|');
    }
    return map;
  }

  bool equals(RequestCatalogFilters other) {
    return sortBy == other.sortBy &&
        startDate == other.startDate &&
        endDate == other.endDate &&
        language == other.language &&
        minDuration == other.minDuration &&
        maxDuration == other.maxDuration &&
        watchRegion == other.watchRegion &&
        _listEq(genres, other.genres) &&
        _listEq(watchProviders, other.watchProviders);
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class RequestGenre {
  final int id;
  final String name;

  const RequestGenre({required this.id, required this.name});

  factory RequestGenre.fromJson(Map<String, dynamic> json) {
    return RequestGenre(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
    );
  }
}

class RequestWatchProvider {
  final int providerId;
  final String providerName;
  final String? logoPath;

  const RequestWatchProvider({
    required this.providerId,
    required this.providerName,
    this.logoPath,
  });

  factory RequestWatchProvider.fromJson(Map<String, dynamic> json) {
    return RequestWatchProvider(
      providerId: json['provider_id'] as int,
      providerName: json['provider_name'] as String? ?? '',
      logoPath: json['logo_path'] as String?,
    );
  }

  String? get logoUrl =>
      logoPath == null || logoPath!.isEmpty
          ? null
          : 'https://image.tmdb.org/t/p/w92$logoPath';
}

const requestCatalogSortOptions = <({String value, String label})>[
  (value: 'popularity.desc', label: 'Popularité (décr.)'),
  (value: 'popularity.asc', label: 'Popularité (crois.)'),
  (value: 'vote_average.desc', label: 'Note (décr.)'),
  (value: 'vote_average.asc', label: 'Note (crois.)'),
  (value: 'release_date.desc', label: 'Date (récent)'),
  (value: 'release_date.asc', label: 'Date (ancien)'),
];

const requestCatalogLanguageOptions = <({String code, String label})>[
  (code: 'all', label: 'Toutes les langues'),
  (code: 'fr', label: 'Français'),
  (code: 'en', label: 'Anglais'),
  (code: 'ja', label: 'Japonais'),
  (code: 'es', label: 'Espagnol'),
  (code: 'de', label: 'Allemand'),
  (code: 'it', label: 'Italien'),
  (code: 'ko', label: 'Coréen'),
  (code: 'zh', label: 'Chinois'),
];

const requestCatalogRegions = <({String value, String label})>[
  (value: 'FR', label: 'France'),
  (value: 'US', label: 'États-Unis'),
  (value: 'CA', label: 'Canada'),
  (value: 'GB', label: 'Royaume-Uni'),
  (value: 'DE', label: 'Allemagne'),
  (value: 'ES', label: 'Espagne'),
  (value: 'IT', label: 'Italie'),
  (value: 'BE', label: 'Belgique'),
  (value: 'CH', label: 'Suisse'),
  (value: 'AU', label: 'Australie'),
];

const requestProviderPreviewLimit = 12;
