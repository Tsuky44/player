import 'dart:math';

import '../models/models.dart';
import 'format.dart';
import 'poster_url.dart';

/// One slide in the home hero carousel (Netflix-style rotating header).
class HeroSlide {
  final Media media;
  final HomeMediaItem? continueItem;
  final String title;
  final String? subtitle;
  final String? backgroundUrl;
  final String playLabel;

  const HeroSlide({
    required this.media,
    this.continueItem,
    required this.title,
    this.subtitle,
    this.backgroundUrl,
    this.playLabel = 'LECTURE',
  });

  bool get showInfoButton =>
      media.type != MediaType.episode && continueItem == null;
}

const _heroResumeMaxAge = Duration(days: 3);
const _maxHeroSlides = 8;

bool _isRecentlyWatched(HomeMediaItem item) {
  final watchedAt = item.updatedAt ?? item.media.createdAt;
  return DateTime.now().difference(watchedAt) <= _heroResumeMaxAge;
}

bool _showAlreadyFeatured(List<HeroSlide> slides, Media show) {
  for (final slide in slides) {
    if (slide.media.type == MediaType.show && slide.media.id == show.id) {
      return true;
    }
    final cw = slide.continueItem;
    if (cw != null &&
        cw.media.type == MediaType.episode &&
        cw.displayTitle.toLowerCase() == show.title.toLowerCase()) {
      return true;
    }
  }
  return false;
}

/// Alternates shows and movies for a balanced carousel.
List<Media> _interleaveMedia(List<Media> movies, List<Media> shows) {
  final merged = <Media>[];
  final maxLen = movies.length > shows.length ? movies.length : shows.length;
  for (var i = 0; i < maxLen; i++) {
    if (i < shows.length) merged.add(shows[i]);
    if (i < movies.length) merged.add(movies[i]);
  }
  return merged;
}

int _dailyDiscoverySeed({required int userId, DateTime? now}) {
  final date = now ?? DateTime.now();
  return Object.hash(userId, date.year, date.month, date.day);
}

List<Media> _discoveryPool(HomeResponse data) {
  final movies = data.discoveryMovies.isNotEmpty
      ? data.discoveryMovies
      : data.recentMovies;
  final shows = data.discoveryShows.isNotEmpty
      ? data.discoveryShows
      : data.recentShows;
  return _interleaveMedia(movies, shows);
}

/// Picks a different mix each day (per user) from the full discovery pool.
List<Media> _pickDailyDiscovery(HomeResponse data, {required int userId}) {
  final movies = data.discoveryMovies.isNotEmpty
      ? List<Media>.from(data.discoveryMovies)
      : List<Media>.from(data.recentMovies);
  final shows = data.discoveryShows.isNotEmpty
      ? List<Media>.from(data.discoveryShows)
      : List<Media>.from(data.recentShows);

  final rng = Random(_dailyDiscoverySeed(userId: userId));
  movies.shuffle(rng);
  shows.shuffle(rng);

  return _interleaveMedia(movies, shows);
}

HeroSlide _discoverySlide(Media media, {required String serverBaseUrl}) {
  return HeroSlide(
    media: media,
    title: media.title,
    subtitle: extractYear(media.releaseDate),
    backgroundUrl:
        resolveHeroImageUrl(media.posterUrl, serverBaseUrl: serverBaseUrl),
  );
}

List<HeroSlide> buildHeroSlides(
  HomeResponse data, {
  required String serverBaseUrl,
  int userId = 0,
}) {
  final slides = <HeroSlide>[];
  final seen = <String>{};

  void add(HeroSlide slide) {
    final key = '${slide.media.type.name}-${slide.media.id}';
    if (seen.contains(key)) return;
    seen.add(key);
    slides.add(slide);
  }

  for (final cw in data.continueWatching) {
    if (!_isRecentlyWatched(cw)) continue;

    final inProgress =
        cw.currentPositionSeconds > 0 && !cw.isFinished;
    add(HeroSlide(
      media: cw.media,
      continueItem: cw,
      title: cw.displayTitle,
      subtitle: _heroSubtitle(cw),
      backgroundUrl: heroBackgroundUrl(cw, serverBaseUrl: serverBaseUrl),
      playLabel: inProgress ? 'REPRENDRE' : 'LECTURE',
    ));
  }

  final discovery = userId > 0
      ? _pickDailyDiscovery(data, userId: userId)
      : _discoveryPool(data);

  for (final media in discovery) {
    if (slides.length >= _maxHeroSlides) break;
    if (media.type == MediaType.show && _showAlreadyFeatured(slides, media)) {
      continue;
    }
    add(_discoverySlide(media, serverBaseUrl: serverBaseUrl));
  }

  return slides;
}

String? _heroSubtitle(HomeMediaItem item) {
  final parts = <String>[];
  final year = extractYear(item.media.releaseDate);
  if (year != null) parts.add(year);
  final ep = item.continueWatchingSubtitle;
  if (ep != null) parts.add(ep);
  return parts.isEmpty ? null : parts.join(' · ');
}
