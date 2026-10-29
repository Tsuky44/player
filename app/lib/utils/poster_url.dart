import '../models/models.dart';

/// Resolves a poster URL for display (handles relative paths from the API).
String? resolvePosterUrl(String? posterUrl, {String? serverBaseUrl}) {
  if (posterUrl == null || posterUrl.trim().isEmpty) return null;
  final url = posterUrl.trim();
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  if (serverBaseUrl == null || serverBaseUrl.isEmpty) return url;
  final base = serverBaseUrl.endsWith('/')
      ? serverBaseUrl.substring(0, serverBaseUrl.length - 1)
      : serverBaseUrl;
  final path = url.startsWith('/') ? url : '/$url';
  return '$base$path';
}

/// The size segment of a TMDB image URL: `w500`, `h632` or `original`.
///
/// Matching `original` matters: the catalog hands back title logos at that
/// size, and a pattern that only knew `w<digits>` left them untouched.
final RegExp _tmdbSizeSegment = RegExp(r'/t/p/(?:original|[wh]\d+)');

bool isTmdbImageUrl(String url) => url.contains('image.tmdb.org/t/p/');

/// Rewrites a TMDB URL to [size]. Anything served by our own server (or any
/// other host) is returned untouched.
///
/// Every render site asks for the size it actually draws, so one title's
/// artwork resolves to the same URL on every screen and the disk entry — and
/// the decoded frame — are shared rather than fetched again per surface.
String tmdbSizedUrl(String url, String size) {
  if (!isTmdbImageUrl(url)) return url;
  return url.replaceFirst(_tmdbSizeSegment, '/t/p/$size');
}

/// Les largeurs que TMDB sert, de la plus petite à la plus grande. Relevé sur
/// image.tmdb.org : chacune répond pour n'importe quelle image (affiche, fond,
/// portrait, logo), pas seulement pour celles de sa catégorie.
const List<int> _tmdbWidths = [92, 154, 185, 300, 342, 500, 780, 1280];

/// Le segment de taille d'une URL TMDB, quand il se lit en largeur :
/// `w342` (largeur dans le groupe 2) ou `original`. `h632` n'en fait pas partie.
final RegExp _tmdbWidthSegment = RegExp(r'/t/p/(original|w(\d+))/');

/// La largeur en pixels que sert [url], ou null si ce n'est pas une URL TMDB
/// en `w…` (`original`, `h632`, autre hôte).
int? tmdbServedWidth(String url) {
  final width = _tmdbWidthSegment.firstMatch(url)?.group(2);
  return width == null ? null : int.parse(width);
}

/// [url] à la plus petite taille TMDB qui couvre [physicalWidth] pixels, sans
/// jamais dépasser celle que l'appelant demandait : sa taille est un plafond.
///
/// Une carte de grille demande `w500` mais se dessine sur 112 px logiques en
/// téléphone (336 px physiques) ou 150 px sur un téléviseur à densité 1 :
/// `w342` pèse moitié moins que `w500` (58 Ko contre 117 Ko mesurés), `w154`
/// huit fois moins. Le décodage, ce qui fait saccader une petite TV pendant un
/// défilement, coûte en proportion des pixels de la source.
///
/// [allowOriginal] faux plafonne `original` à `w1280` même sur une place plus
/// large : le mode léger ne décode jamais une image en 4K (ADR-0086).
String tmdbUrlForWidth(
  String url,
  double physicalWidth, {
  bool allowOriginal = true,
}) {
  final match = _tmdbWidthSegment.firstMatch(url);
  if (match == null || !physicalWidth.isFinite || physicalWidth <= 0) {
    return url;
  }
  final asked = match.group(2) == null ? null : int.parse(match.group(2)!);
  for (final width in _tmdbWidths) {
    if (width < physicalWidth) continue;
    if (asked != null && width >= asked) return url;
    return url.replaceRange(match.start, match.end, '/t/p/w$width/');
  }
  if (asked == null && !allowOriginal) {
    return url.replaceRange(
        match.start, match.end, '/t/p/w${_tmdbWidths.last}/');
  }
  return url;
}

/// TMDB serves multiple sizes — upgrade small posters/stills for large hero backgrounds.
String upgradeTmdbImageUrl(String url, {bool hero = false}) {
  return tmdbSizedUrl(url, hero ? 'w1280' : 'w780');
}

/// Poster for a grid/row card: TMDB is normalised to w500 — the server stores
/// some artwork as w300, which is visibly soft on a desktop grid. w500 est un
/// plafond : `AppNetworkImage` descend à la taille de la place réelle
/// ([tmdbUrlForWidth], ADR-0087).
String? cardPosterUrl(String? posterUrl, {String? serverBaseUrl}) {
  final resolved = resolvePosterUrl(posterUrl, serverBaseUrl: serverBaseUrl);
  if (resolved == null) return null;
  return tmdbSizedUrl(resolved, 'w500');
}

/// Title logo for the detail header and the player chrome.
///
/// The catalog returns logos at `original` — a lossless PNG that routinely
/// weighs several MB for an element drawn at most 160 px high. That is why
/// logos arrived late, or not at all on a slow link. `w500` is TMDB's largest
/// scaled logo and covers the widest slot we have (420 px at 2x) while costing
/// a few tens of KB.
///
/// The size is deliberately fixed rather than derived from the slot: the
/// player and the detail page then share one URL, so opening playback from a
/// detail page draws the logo from memory on the first frame.
String? logoImageUrl(String? logoUrl, {String? serverBaseUrl}) {
  final resolved = resolvePosterUrl(logoUrl, serverBaseUrl: serverBaseUrl);
  if (resolved == null) return null;
  return tmdbSizedUrl(resolved, 'w500');
}

/// Cast/crew headshot for a card-sized slot. The catalog serves `h632`
/// portraits, ~6x the pixels a 120x150 card can show.
String? castProfileUrl(String? profileUrl, {String? serverBaseUrl}) {
  final resolved = resolvePosterUrl(profileUrl, serverBaseUrl: serverBaseUrl);
  if (resolved == null) return null;
  return tmdbSizedUrl(resolved, 'w185');
}

/// Poster for the detail header (190x285 logical, so w500 at 2x).
String? detailPosterUrl(String? posterUrl, {String? serverBaseUrl}) {
  final resolved = resolvePosterUrl(posterUrl, serverBaseUrl: serverBaseUrl);
  if (resolved == null) return null;
  return tmdbSizedUrl(resolved, 'w500');
}

/// Le fond d'une fiche (bibliothèque ou demande), en pleine page comme sur
/// OnyxHub : plafonné à `original`. Sur une fenêtre de 2000 px, `w1280` était
/// agrandi et se voyait flou ; `AppNetworkImage` redescend à `w1280` dès que
/// la place le permet, et toujours en mode léger (ADR-0087).
String? detailBackdropUrl(String? backdropUrl, {String? serverBaseUrl}) {
  final resolved = resolvePosterUrl(backdropUrl, serverBaseUrl: serverBaseUrl);
  if (resolved == null) return null;
  return tmdbSizedUrl(resolved, 'original');
}

/// Backdrop behind a hero or a banner. `w1280` is the largest TMDB size
/// below `original` and is plenty for a banner that is at most ~600 px tall,
/// and cheap enough for a carousel that changes image every few seconds.
String? backdropImageUrl(String? backdropUrl, {String? serverBaseUrl}) {
  final resolved = resolvePosterUrl(backdropUrl, serverBaseUrl: serverBaseUrl);
  if (resolved == null) return null;
  return tmdbSizedUrl(resolved, 'w1280');
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
  return resolveHeroImageUrl(item.displayPosterUrl,
      serverBaseUrl: serverBaseUrl);
}

/// Estimated card height for layout (poster 2:3 + title line + subtitle line).
double mediaCardHeight(double width, {bool compact = false}) {
  final posterH = width * (compact ? 1.45 : 1.5);
  final gap = compact ? 7.0 : 9.0;
  final metaH = compact ? 34.0 : 38.0;
  return posterH + gap + metaH;
}
