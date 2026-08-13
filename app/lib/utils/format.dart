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

/// Wall-clock time at which playback ends, as `HH:mm` — the `19:31` half of
/// the Emby player's `-3:12:33 / 19:31` readout.
///
/// [now] is injectable so the result is testable without freezing the clock.
String formatEndClock(int remainingSeconds, {DateTime? now}) {
  if (remainingSeconds < 0) remainingSeconds = 0;
  final end =
      (now ?? DateTime.now()).add(Duration(seconds: remainingSeconds));
  return '${end.hour.toString().padLeft(2, '0')}:'
      '${end.minute.toString().padLeft(2, '0')}';
}

String? extractYear(String? releaseDate) {
  if (releaseDate == null || releaseDate.isEmpty) return null;
  return releaseDate.split('-').first;
}

/// Formats a TMDB air/release date (YYYY-MM-DD) for unavailable episode tiles.
String? formatAirDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) return raw.trim();

  const months = [
    'janv.',
    'févr.',
    'mars',
    'avr.',
    'mai',
    'juin',
    'juil.',
    'août',
    'sept.',
    'oct.',
    'nov.',
    'déc.',
  ];
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(parsed.year, parsed.month, parsed.day);
  final label = '${day.day} ${months[day.month - 1]} ${day.year}';

  if (day.isAfter(today)) {
    return 'Sortie prévue le $label';
  }
  if (day.isAtSameMomentAs(today)) {
    return 'Sortie aujourd’hui';
  }
  return 'Sorti le $label';
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
