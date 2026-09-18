import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'client_identity.dart';

/// La gravité d'une ligne, telle qu'elle est écrite et non telle qu'elle est
/// devinée.
///
/// Rien ici ne classe un message d'après son texte : chercher « erreur » ou
/// « failed » dans une chaîne rate ce qui est écrit autrement et se trompe sur
/// un commentaire qui cite le mot. Une ligne est une erreur parce que le code
/// qui l'écrit est passé par [ClientLog.error], ou parce que Flutter l'a
/// remontée comme telle.
enum LogLevel { info, error }

/// Une ligne du journal.
@immutable
class LogEntry {
  const LogEntry(this.sequence, this.time, this.level, this.message);

  /// Le rang de la ligne depuis le lancement de l'app.
  ///
  /// Ce qui permet de découper une tranche — « ce qui a été écrit pendant cette
  /// lecture » — sans copier le tampon au début de chaque séance ni tenir un
  /// second journal à côté. Un rang ne se réutilise pas, y compris après un
  /// vidage : une tranche ouverte avant reste bornée par ce qu'elle a demandé.
  final int sequence;

  final DateTime time;
  final LogLevel level;
  final String message;

  /// `12:04:07.318 · message`, l'heure locale devant.
  ///
  /// La milliseconde est là parce que ce journal sert surtout à lire un
  /// enchaînement — quelle requête a précédé quelle panne — et qu'à la seconde
  /// près tout un démarrage de lecture tient sur la même ligne de temps.
  String format() {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${time.millisecond.toString().padLeft(3, '0')}';
    return '$t · $message';
  }
}

/// Ce que l'application a écrit sur elle-même, gardé sur l'appareil.
///
/// L'app diagnostiquait déjà abondamment — capacités de l'appareil, choix du
/// décodeur, erreurs d'API, pannes de lecture — mais uniquement vers la console
/// du développeur. Sur un téléphone installé depuis un APK, cette console
/// n'existe pas : il faut un câble USB et `adb logcat`, c'est-à-dire un
/// ordinateur, un pilote et un mode développeur. « Ça ne se lance pas » restait
/// donc tout ce qu'on pouvait savoir d'une panne.
///
/// Alors les mêmes lignes sont gardées ici, dans un tampon circulaire en
/// mémoire, et la page Journal des réglages les montre. Rien n'est écrit sur le
/// disque et rien n'est envoyé nulle part : le journal meurt avec le processus,
/// et n'en sort que si quelqu'un appuie sur « Copier ».
abstract final class ClientLog {
  /// Combien de lignes on garde.
  ///
  /// Un démarrage de lecture en écrit une vingtaine, une session de navigation
  /// quelques dizaines. Six cents couvre largement « ce qui s'est passé avant
  /// l'erreur » sans que le tampon pèse : à deux mille caractères la ligne dans
  /// le pire des cas, le plafond tient en un peu plus d'un mégaoctet.
  static const int capacity = 600;

  /// Au-delà, la ligne est tronquée. Une réponse JSON entière recopiée dans un
  /// message d'erreur remplirait le tampon à elle seule.
  static const int maxMessageLength = 2000;

  static final ListQueue<LogEntry> _entries = ListQueue<LogEntry>();

  /// Change à chaque écriture. La page du journal s'y abonne.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Le `debugPrint` d'origine, gardé pour continuer de l'alimenter.
  ///
  /// Capturer ne veut pas dire détourner : la console garde exactement ce
  /// qu'elle avait, et un développeur branché en USB ne perd rien.
  static DebugPrintCallback? _forward;

  static bool _installed = false;
  static bool _notifyScheduled = false;
  static int _nextSequence = 0;

  /// Les lignes, de la plus ancienne à la plus récente.
  static List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  static bool get isEmpty => _entries.isEmpty;

  /// Le rang qu'aura la prochaine ligne. Le marqueur d'ouverture d'une tranche.
  static int get sequence => _nextSequence;

  /// Les lignes écrites depuis [mark], dans l'ordre.
  ///
  /// Ce qui a débordé du tampon circulaire entre-temps n'y est plus : une
  /// tranche est ce qu'on a encore, pas ce qu'on a eu. Pour une séance de
  /// lecture c'est sans conséquence — la tranche est prélevée à la fin de la
  /// séance, et six cents lignes couvrent largement un film.
  static List<LogEntry> since(int mark) => _entries
      .where((entry) => entry.sequence >= mark)
      .toList(growable: false);

  /// Branche la capture. À appeler une fois, au tout début de `main`.
  ///
  /// Trois sources, parce qu'une panne arrive par trois chemins différents :
  /// ce que le code écrit lui-même, ce que le framework remonte quand un widget
  /// lève, et ce qui échappe complètement à la boucle asynchrone. Les deux
  /// derniers sont exactement les cas où l'app n'a plus l'occasion de rien
  /// écrire elle-même.
  static void install() {
    if (_installed) return;
    _installed = true;

    _forward = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) _record(LogLevel.info, message);
      _forward?.call(message, wrapWidth: wrapWidth);
    };

    final previousOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _record(LogLevel.error,
          'Flutter: ${details.exceptionAsString()}${details.context == null ? '' : ' (${details.context})'}');
      previousOnError?.call(details);
    };

    final previousDispatch = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _record(LogLevel.error, 'Erreur non rattrapée : $error');
      return previousDispatch?.call(error, stack) ?? false;
    };
  }

  /// Écrit une ligne d'erreur.
  ///
  /// Court-circuite le `debugPrint` détourné plutôt que de passer par lui : y
  /// passer enregistrerait la même ligne deux fois, une fois à chaque niveau.
  static void error(String message) {
    _record(LogLevel.error, message);
    if (_forward != null) {
      _forward!(message);
    } else {
      debugPrint(message);
    }
  }

  static void clear() {
    _entries.clear();
    _bumpRevision();
  }

  /// Le journal en texte, précédé de ce qui le rend lisible ailleurs.
  ///
  /// L'entête compte autant que les lignes : un journal collé dans une
  /// conversation sans dire de quelle version ni de quel appareil il vient
  /// oblige à redemander les deux.
  static String export({bool errorsOnly = false}) {
    final lines = _entries
        .where((e) => !errorsOnly || e.level == LogLevel.error)
        .map((e) => e.format());
    return [
      'Onyx ${ClientIdentity.version} · ${ClientIdentity.platform} · ${ClientIdentity.deviceName}',
      'Journal du ${DateTime.now().toIso8601String()}'
          '${errorsOnly ? ' (erreurs seules)' : ''}',
      '',
      ...lines,
    ].join('\n');
  }

  static void _record(LogLevel level, String message) {
    final trimmed = message.length > maxMessageLength
        ? '${message.substring(0, maxMessageLength)}…'
        : message;
    _entries.addLast(
        LogEntry(_nextSequence++, DateTime.now(), level, trimmed));
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    _bumpRevision();
  }

  /// Prévenir la page, mais jamais pendant une phase de construction.
  ///
  /// Une ligne écrite depuis un `build` — ce qui arrive — ferait appeler
  /// `setState` sur l'écouteur au milieu de ce même `build`, ce que Flutter
  /// refuse. Le microtask reporte la notification après la frame, et le drapeau
  /// évite d'en empiler une par ligne quand il en arrive une rafale.
  static void _bumpRevision() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      revision.value++;
    });
  }

  @visibleForTesting
  static void resetForTest() {
    _entries.clear();
    revision.value = 0;
  }
}
