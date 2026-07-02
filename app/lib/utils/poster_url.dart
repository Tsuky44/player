import '../models/models.dart';

/// Resolves a poster URL for display (handles relative paths from the API).
String? resolvePosterUrl(String? posterUrl, {String? serverBaseUrl}) {
  if (posterUrl == null || posterUrl.trim().isEmpty) return null;
  final url = posterUrl.trim();
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  if (serverBaseUrl == null || serverBaseUrl.isEmpty) return url;
  final base = serverBaseUrl.endsWith('/') ? serverBaseUrl.substring(0, serverBaseUrl.length - 1) : serverBaseUrl;
  final path = url.startsWith('/') ? url : '/$url';
  return '$base$path';
}

/// TMDB serves multiple sizes — upgrade small posters/stills for large hero backgrounds.
String upgradeTmdbImageUrl(String url, {bool hero = false}) {
  if (!url.contains('image.tmdb.org/t/p/')) return url;
  final size = hero ? 'w1280' : 'w780';
  return url.replaceFirst(RegExp(r'/t/p/w\d+'), '/t/p/$size');
}

String? resolveHeroImageUrl(String? posterUrl, {String? serverBaseUrl}) {
  final resolved = resolvePosterUrl(posterUrl, serverBaseUrl: serverBaseUrl);
  if (resolved == null) return null;
  return upgradeTmdbImageUrl(resolved, hero: true);
}

String? effectivePosterUrl(Media media, {String? serverBaseUrl}) {
  return resolvePosterUrl(media.posterUrl, serverBaseUrl: serverBaseUrl);
}

/// Best background for the home hero: episode still (16:9) when available.
String? heroBackgroundUrl(HomeMediaItem item, {String? serverBaseUrl}) {
  final episodeStill = item.media.posterUrl;
  if (episodeStill != null && episodeStill.trim().isNotEmpty) {
    return resolveHeroImageUrl(episodeStill, serverBaseUrl: serverBaseUrl);
  }
  return resolveHeroImageUrl(item.displayPosterUrl, serverBaseUrl: serverBaseUrl);
}

/// Estimated card height for layout (poster 2:3 + metadata).
double mediaCardHeight(double width, {bool compact = false}) {
  final posterH = width * (compact ? 1.45 : 1.5);
  final metaH = compact ? 36.0 : 52.0;
  return posterH + 8 + metaH;
}
