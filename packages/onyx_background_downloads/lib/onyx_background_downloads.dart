/// Le pont natif des téléchargements hors ligne en arrière-plan — voir
/// l'ADR-0040.
library;

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('onyx/background_downloads');

/// Android : le service de premier plan qui garde le processus, le processeur
/// et le Wi-Fi éveillés tant qu'un téléchargement tourne.
///
/// Écran éteint, Android gèle une app sans service de premier plan en quelques
/// minutes, puis lui coupe le réseau (Doze). Le transfert, lui, est du Dart :
/// il suffit que le processus continue de tourner. La notification est le prix
/// de ce droit — Android n'en accorde pas sans elle.
class DownloadForegroundService {
  const DownloadForegroundService();

  /// Démarre le service, ou met sa notification à jour s'il tourne déjà.
  /// [percent] vaut -1 quand la taille totale n'est pas connue.
  Future<void> show({
    required String title,
    required String text,
    required int percent,
  }) =>
      _channel.invokeMethod<void>('keepAlive', {
        'title': title,
        'text': text,
        'percent': percent,
      });

  /// Arrête le service et rend les verrous.
  Future<void> stop() => _channel.invokeMethod<void>('release');
}

/// iOS : une session URLSession d'arrière-plan, qui télécharge dans un
/// processus du système pendant que l'app est suspendue.
///
/// Chaque tâche rapatrie une tranche du fichier (`Range:`) et le système la
/// dépose, finie, à la destination donnée à [enqueue]. Rien d'autre n'arrive côté natif :
/// assembler les tranches, compter et réessayer se fait en Dart, où c'est
/// testable.
class BackgroundDownloadSession {
  const BackgroundDownloadSession();

  /// Confie au système la tranche `[start, end]` (bornes incluses) de [url],
  /// à déposer en [destination]. Un dossier parent absent à l'arrivée veut
  /// dire « média supprimé » : la tranche est jetée.
  Future<void> enqueue({
    required String url,
    required int start,
    required int end,
    required String destination,
  }) =>
      _channel.invokeMethod<void>('enqueue', {
        'url': url,
        'start': start,
        'end': end,
        'destination': destination,
      });

  /// Les tranches en cours dont la destination commence par [prefix], et les
  /// derniers échecs connus.
  Future<BackgroundDownloadSnapshot> snapshot(String prefix) async {
    final raw = await _channel
        .invokeMapMethod<String, Object?>('snapshot', {'prefix': prefix});
    return BackgroundDownloadSnapshot.fromMap(raw ?? const {});
  }

  /// Annule les tranches en cours dont la destination commence par [prefix].
  /// Les tranches déjà déposées restent sur le disque.
  Future<void> cancel(String prefix) =>
      _channel.invokeMethod<void>('cancel', {'prefix': prefix});
}

/// L'état des tranches d'un fichier, vu du système.
class BackgroundDownloadSnapshot {
  const BackgroundDownloadSnapshot({
    this.running = const {},
    this.failures = const {},
  });

  factory BackgroundDownloadSnapshot.fromMap(Map<String, Object?> raw) {
    final running = <String, int>{};
    final rawRunning = raw['running'];
    if (rawRunning is Map) {
      rawRunning.forEach((key, value) {
        if (key is String && value is int) running[key] = value;
      });
    }
    final failures = <String, String>{};
    final rawFailures = raw['failures'];
    if (rawFailures is Map) {
      rawFailures.forEach((key, value) {
        if (key is String && value is String) failures[key] = value;
      });
    }
    return BackgroundDownloadSnapshot(running: running, failures: failures);
  }

  /// Destination → octets déjà reçus par la tâche.
  final Map<String, int> running;

  /// Destination → raison du dernier échec (statut HTTP, erreur réseau).
  final Map<String, String> failures;
}
