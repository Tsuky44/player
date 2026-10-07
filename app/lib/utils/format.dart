import '../models/models.dart';
import '../l10n/tr.dart';

String formatDuration(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return tr('{0}h {1}min', [h, m]);
  return '${m}min';
}

/// Le temps qu'il reste à regarder : « 1h 15min restantes ».
///
/// Un temps restant se lit d'un coup d'œil, un pourcentage demande de
/// connaître la durée pour savoir si l'on a le temps. Null quand il ne reste
/// rien, pour que l'appelant n'affiche pas « restantes » tout seul.
String? formatRemaining(int remainingSeconds) {
  final duration = formatDuration(remainingSeconds);
  return duration.isEmpty ? null : '$duration restantes';
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
/// the Chrome Onyx `-3:12:33 / 19:31` readout.
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

const _shortMonths = [
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

/// Date TMDB (YYYY-MM-DD) en toutes lettres : « 12 mars 2024 ».
///
/// Sert aux épisodes déjà sur le serveur, où la date seule suffit : un
/// « Sorti le » devant chaque ligne d'une saison ne dirait rien de plus.
String? formatReleaseDay(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) return raw.trim();
  return '${parsed.day} ${tr(_shortMonths[parsed.month - 1])} ${parsed.year}';
}

/// Formats a TMDB air/release date (YYYY-MM-DD) for unavailable episode tiles.
///
/// [now] is injectable so the result is testable without freezing the clock.
String? formatAirDate(String? raw, {DateTime? now}) {
  if (raw == null || raw.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed == null) return raw.trim();

  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final day = DateTime(parsed.year, parsed.month, parsed.day);
  final label = formatReleaseDay(raw)!;

  if (day.isAfter(today)) {
    return tr('Sortie prévue le {0}', [label]);
  }
  if (day.isAtSameMomentAs(today)) {
    return tr('Sortie aujourd’hui');
  }
  return tr('Sorti le {0}', [label]);
}

String mediaTypeLabel(MediaType type) {
  switch (type) {
    case MediaType.movie:
      return tr('Film');
    case MediaType.show:
      return tr('Série');
    case MediaType.season:
      return tr('Saison');
    case MediaType.episode:
      return tr('Épisode');
  }
}

/// Taille de fichier lisible : « 1,4 Go ».
///
/// Base 1000 comme les systèmes d'exploitation grand public l'affichent, et
/// une décimale seulement à partir du gigaoctet — sous cette échelle elle ne
/// renseigne sur rien.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 ${tr('Mo')}';
  const units = ['o', 'Ko', 'Mo', 'Go', 'To'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final decimals = unit >= 3 && value < 100 ? 1 : 0;
  return '${value.toStringAsFixed(decimals).replaceAll('.', ',')} ${tr(units[unit])}';
}
