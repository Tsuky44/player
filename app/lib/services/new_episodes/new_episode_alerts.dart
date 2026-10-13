import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../l10n/app_language.dart';
import '../../tv/tv_mode.dart';
import '../../utils/app_platform.dart';
import '../api_client.dart';
import 'new_episode_notifications.dart';
import 'new_episode_watch.dart';

/// Le point d'entrée de la tâche de fond, appelé par le système dans un
/// moteur Flutter à part, sans interface (ADR-0059).
///
/// Rend toujours vrai : un serveur muet n'est pas un échec à rejouer tout de
/// suite, le passage suivant suffit.
@pragma('vm:entry-point')
void newEpisodeBackgroundEntry() {
  Workmanager().executeTask((_, __) async {
    try {
      await NewEpisodeAlerts.runInBackground();
    } on Object catch (error) {
      debugPrint('NewEpisodeAlerts: passage de fond interrompu ($error)');
    }
    return true;
  });
}

/// Prévient quand un nouvel épisode d'une série suivie sort sur l'un des
/// serveurs de l'appareil, sans qu'on ait à ouvrir l'app (ADR-0059).
///
/// Il n'y a pas de service central pour pousser une notification (ADR-0013) :
/// c'est l'appareil qui va demander, de temps en temps, à chacun de ses
/// serveurs. [NewEpisodeWatch] fait le tour, [NewEpisodeNotifications]
/// affiche ; ici se décident le quand et le si.
abstract final class NewEpisodeAlerts {
  static const String _enabledKey = 'new_episode_alerts_enabled';
  static const String _askedKey = 'new_episode_alerts_permission_asked';

  /// Le nom de la tâche. Sur iOS c'est l'identifiant BGTaskScheduler : il doit
  /// rester celui d'`ios/Runner/Info.plist` et d'`AppDelegate.swift`, ce que
  /// garde `test/new_episode_alerts_wiring_test.dart`.
  static const String taskName = 'com.tsuky.onyx.new-episodes';

  /// L'écart visé entre deux passages. Un épisode sorti est annoncé dans
  /// l'heure sur Android ; iOS prend ce chiffre pour un plancher et choisit
  /// lui-même, selon l'usage qu'on fait de l'app.
  static const Duration interval = Duration(hours: 1);

  /// Entre deux passages de l'app ouverte : y revenir dix fois de suite ne
  /// vaut pas dix tours de serveurs.
  static const Duration _foregroundPause = Duration(minutes: 5);

  /// Vrai tant que rien n'a été réglé : c'est une fonction qu'on attend d'une
  /// app qui suit des séries, pas une option à découvrir.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  static DateTime? _lastForegroundCheck;
  static Future<void>? _starting;
  static bool _permissionAsked = false;

  /// Un téléphone ou une tablette. Un téléviseur n'a pas de volet de
  /// notifications où lire ça, et un ordinateur n'a pas de tâche de fond
  /// quand l'app est fermée.
  static bool get supported => AppPlatform.isMobile && !TvMode.detected;

  /// À appeler une fois au démarrage, après [TvMode.initialize].
  static Future<void> start() => _starting ??= _start();

  static Future<void> _start() async {
    if (!supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_enabledKey) ?? true;
      await Workmanager().initialize(newEpisodeBackgroundEntry);
      await _schedule();
    } on Object catch (error) {
      // Sans tâche de fond l'app marche comme avant : on ne retarde pas son
      // démarrage pour ça.
      debugPrint('NewEpisodeAlerts: planification impossible ($error)');
    }
  }

  static Future<void> _schedule() async {
    if (!enabled.value) {
      await Workmanager().cancelByUniqueName(taskName);
      return;
    }
    await Workmanager().registerPeriodicTask(
      taskName,
      taskName,
      frequency: interval,
      constraints: Constraints(networkType: NetworkType.connected),
      // Replanifier à chaque lancement repousserait le prochain passage d'une
      // heure : quelqu'un qui ouvre l'app souvent ne serait jamais prévenu.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// Le réglage de l'utilisateur. L'activer pose la question du système, et
  /// rend faux si elle est refusée — le réglage reste alors noté, et vaudra
  /// dès que les notifications seront rouvertes dans les réglages du système.
  static Future<bool> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, value);
      await _schedule();
    } on Object catch (error) {
      debugPrint('NewEpisodeAlerts: réglage non appliqué ($error)');
    }
    if (!value) return true;
    return NewEpisodeNotifications.requestPermission();
  }

  /// Pose la question du système une seule fois, à la première session
  /// ouverte : avant, l'app n'a aucune série à suivre et la question n'a pas
  /// de sens.
  static Future<void> askPermissionOnce() async {
    if (!supported || _permissionAsked) return;
    // Plusieurs écouteurs arrivent ici dans le même instant : sans ce verrou
    // en mémoire, chacun lirait « pas encore demandé » avant que l'autre
    // l'écrive.
    _permissionAsked = true;
    await start();
    if (!enabled.value) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_askedKey) ?? false) return;
      await prefs.setBool(_askedKey, true);
      await NewEpisodeNotifications.requestPermission();
    } on Object catch (error) {
      debugPrint('NewEpisodeAlerts: permission non demandée ($error)');
    }
  }

  /// Le passage de l'app ouverte : au lancement, au retour au premier plan, au
  /// retour du serveur. C'est lui qui rattrape iOS, où le système décide seul
  /// de l'heure de la tâche de fond.
  ///
  /// Le serveur actif n'annonce rien : sa pastille « Nouvel épisode » est déjà
  /// à l'écran. Les autres serveurs, eux, sont précisément ceux qu'on ne
  /// regarde pas.
  static Future<void> checkInForeground(ApiClient api) async {
    if (!supported) return;
    // Le réglage se lit au démarrage : sans l'attendre, un passage partirait
    // sur la valeur par défaut chez quelqu'un qui a tout coupé.
    await start();
    if (!enabled.value) return;
    final now = DateTime.now();
    final last = _lastForegroundCheck;
    if (last != null && now.difference(last) < _foregroundPause) return;
    _lastForegroundCheck = now;
    final active = api.servers.active?.id;
    await _announce(api, quiet: {if (active != null) active});
  }

  /// Le passage de la tâche de fond : rien de l'app n'est initialisé ici, ni
  /// la langue, ni le carnet de serveurs.
  static Future<void> runInBackground() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_enabledKey) ?? true)) return;
    await AppLanguage.load();
    final api = ApiClient();
    await api.servers.load();
    await _announce(api);
  }

  static Future<void> _announce(
    ApiClient api, {
    Set<String> quiet = const {},
  }) async {
    final alerts = await NewEpisodeWatch(
      accounts: () => api.servers.accounts,
      fetch: (account) => api.continueWatchingOf(account.id),
    ).check(quiet: quiet);
    final nameServer = api.servers.hasMultipleServers;
    for (final alert in alerts) {
      await NewEpisodeNotifications.show(alert, nameServer: nameServer);
    }
  }

  @visibleForTesting
  static void resetForTest() {
    enabled.value = true;
    _lastForegroundCheck = null;
    _starting = null;
    _permissionAsked = false;
  }
}
