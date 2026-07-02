import '../models/models.dart';

String formatDuration(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}min';
  return '${m}min';
}

/// Formats seconds as mm:ss or hh:mm:ss for playback/chapter debug UI.
String formatPlaybackTime(int totalSeconds) {
  if (totalSeconds < 0) totalSeconds = 0;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String? extractYear(String? releaseDate) {
  if (releaseDate == null || releaseDate.isEmpty) return null;
  return releaseDate.split('-').first;
}

String mediaTypeLabel(MediaType type) {
  switch (type) {
    case MediaType.movie:
      return 'Film';
    case MediaType.show:
      return 'Série';
    case MediaType.season:
      return 'Saison';
    case MediaType.episode:
      return 'Épisode';
  }
}
