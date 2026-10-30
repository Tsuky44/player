import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'client_log.dart';

/// Les journaux de lecture que le serveur n'a pas pu recevoir, gardés sur
/// l'appareil jusqu'au prochain lancement.
///
/// Une lecture qui laisse sa ligne d'historique sans journal avait deux causes
/// côté client : l'app tuée ou coupée du réseau avant le dernier envoi, et
/// l'envoi qui échoue sans que personne le rejoue. Le journal vivait en mémoire,
/// donc il mourait avec le processus. Ici l'échec écrit la tranche sur le
/// disque, indexée par la ligne d'historique que le serveur a nommée au premier
/// envoi réussi (`history_id`), et le lancement suivant la renvoie : le serveur
/// la rattache à cette ligne même si la séance est fermée depuis longtemps.
abstract final class PendingPlaybackLogs {
  static const _key = 'pending_playback_logs';

  /// Au-delà, les plus anciennes sont écartées : le disque de l'appareil n'est
  /// pas un second serveur de journaux.
  static const maxEntries = 5;

  /// Garde la tranche de cette lecture, en remplaçant celle déjà gardée pour la
  /// même ligne d'historique : un envoi plus tardif est plus complet.
  static Future<void> save(
    int historyId,
    List<LogEntry> lines,
    Map<String, dynamic>? stats,
  ) async {
    final entries = await _load();
    entries.removeWhere((e) => e['history_id'] == historyId);
    entries.add({
      'history_id': historyId,
      'lines': [
        for (final line in lines)
          {
            'at': line.time.toUtc().toIso8601String(),
            'error': line.level == LogLevel.error,
            'message': line.message,
          },
      ],
      if (stats != null) 'stats': stats,
    });
    while (entries.length > maxEntries) {
      entries.removeAt(0);
    }
    await _store(entries);
  }

  /// Une tranche reçue par le serveur n'a plus à être rejouée.
  static Future<void> discard(int historyId) async {
    final entries = await _load();
    final before = entries.length;
    entries.removeWhere((e) => e['history_id'] == historyId);
    if (entries.length != before) await _store(entries);
  }

  /// Renvoie ce qui attendait. Une tranche que le réseau n'a pas laissée passer
  /// reste en place pour le lancement d'après.
  static Future<void> replay(ApiClient api) async {
    final entries = await _load();
    for (final entry in entries) {
      final historyId = entry['history_id'];
      if (historyId is! int) continue;
      try {
        await api.uploadPlaybackLogs(
          _lines(entry['lines']),
          stats: (entry['stats'] as Map?)?.cast<String, dynamic>(),
          historyId: historyId,
        );
        await discard(historyId);
      } catch (_) {
        // Hors ligne ou serveur plus ancien : la tranche reste gardée, le
        // prochain lancement réessaie.
      }
    }
  }

  static List<LogEntry> _lines(Object? raw) => [
        for (final item in (raw as List? ?? const []))
          if (item is Map)
            LogEntry(
              0,
              DateTime.tryParse('${item['at']}') ?? DateTime.now(),
              item['error'] == true ? LogLevel.error : LogLevel.info,
              '${item['message']}',
            ),
      ];

  static Future<List<Map<String, dynamic>>> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      // Un stockage illisible ou corrompu vaut un stockage vide : le journal
      // est un diagnostic, il ne doit jamais bloquer une lecture.
      return [];
    }
  }

  static Future<void> _store(List<Map<String, dynamic>> entries) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (entries.isEmpty) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, jsonEncode(entries));
      }
    } catch (_) {
      // Disque plein ou stockage refusé : on perd la reprise, pas la lecture.
    }
  }
}
