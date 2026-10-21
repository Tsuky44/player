import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../l10n/app_language.dart';
import '../../tv/tv_mode.dart';
import '../../utils/app_platform.dart';
import '../api_client.dart';
import '../notifications/onyx_notifications.dart';
import '../request_alerts/request_alert_watch.dart';
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
/// serveurs de l'appareil (ADR-0059), et, sur ceux que l'on administre, quand
/// un autre compte demande un média (ADR-0077) — sans qu'on ait à ouvrir
/// l'app.
///
/// Il n'y a pas de service central pour pousser une notification (ADR-0013) :
/// c'est l'appareil qui va demander, de temps en temps, à chacun de ses
/// serveurs. [NewEpisodeWatch] et [RequestAlertWatch] font le tour,
/// [OnyxNotifications] affiche ; ici se décident le quand et le si. Les deux
/// veilles partagent une seule tâche de fond : iOS n'en réveille qu'une, à
/// l'heure qu'il choisit.
abstract final class NewEpisodeAlerts {
  static const String _enabledKey = 'new_episode_alerts_enabled';
  static const String _requestsEnabledKey = 'request_alerts_enabled';
  static const String _askedKey = 'new_episode_alerts_permission_asked';
  static const String _episodesCheckedKey = 'new_episode_alerts_checked_at';

  /// Le nom de la tâche. Sur iOS c'est l'identifiant BGTaskScheduler : il doit
  /// rester celui d'`ios/Runner/Info.plist` et d'`AppDelegate.swift`, ce que
  /// garde `test/new_episode_alerts_wiring_test.dart`.
  static const String taskName = 'com.tsuky.onyx.new-episodes';

  /// L'écart visé entre deux passages : le plancher de WorkManager. Une
  /// demande est annoncée dans le quart d'heure sur Android ; iOS prend ce
  /// chiffre pour un plancher et choisit lui-même, selon l'usage qu'on fait
  /// de l'app. Doit rester celui d'`AppDelegate.swift`.
  static const Duration interval = Duration(minutes: 15);

  /// Les épisodes, eux, gardent leur rythme d'une heure (ADR-0059) :
  /// `/api/home` coûte plus cher que le flux des demandes, et un épisode n'a
  /// pas à arriver dans le quart d'heure. Cinq minutes de marge, parce que
  /// WorkManager ne tombe jamais pile.
  static const Duration episodeInterval = Duration(minutes: 55);

  /// Entre deux passages de l'app ouverte : y revenir dix fois de suite ne
  /// vaut pas dix tours de serveurs.
  static const Duration _foregroundPause = Duration(minutes: 5);

  /// Vrai tant que rien n'a été réglé : c'est une fonction qu'on attend d'une
  /// app qui suit des séries, pas une option à découvrir.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  /// Les nouvelles demandes. Vrai par défaut : seul un administrateur en
  /// reçoit, et c'est pour lui que la fonction existe.
  static final ValueNotifier<bool> requestsEnabled = ValueNotifier<bool>(true);

  static bool get _anyEnabled => enabled.value || requestsEnabled.value;

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
      requestsEnabled.value = prefs.getBool(_requestsEnabledKey) ?? true;
      await Workmanager().initialize(newEpisodeBackgroundEntry);
      await _schedule();
    } on Object catch (error) {
      // Sans tâche de fond l'app marche comme avant : on ne retarde pas son
      // démarrage pour ça.
      debugPrint('NewEpisodeAlerts: planification impossible ($error)');
    }
  }

  static Future<void> _schedule() async {
    if (!_anyEnabled) {
      await Workmanager().cancelByUniqueName(taskName);
      return;
    }
    await Workmanager().registerPeriodicTask(
      taskName,
      taskName,
      frequency: interval,
      constraints: Constraints(networkType: NetworkType.connected),
      // `update` garde l'heure du prochain passage : replanifier à chaque
      // lancement ne le repousse pas, et quelqu'un qui ouvre l'app souvent
      // est quand même prévenu. `keep` aurait laissé l'intervalle d'une heure
      // aux installations d'avant l'ADR-0077.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  /// Le réglage de l'utilisateur. L'activer pose la question du système, et
  /// rend faux si elle est refusée — le réglage reste alors noté, et vaudra
  /// dès que les notifications seront rouvertes dans les réglages du système.
  static Future<bool> setEnabled(bool value) =>
      _setFlag(enabled, _enabledKey, value);

  /// Le réglage des nouvelles demandes, qui se comporte comme [setEnabled].
  static Future<bool> setRequestsEnabled(bool value) =>
      _setFlag(requestsEnabled, _requestsEnabledKey, value);

  static Future<bool> _setFlag(
    ValueNotifier<bool> flag,
    String key,
    bool value,
  ) async {
    flag.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
      await _schedule();
    } on Object catch (error) {
      debugPrint('NewEpisodeAlerts: réglage non appliqué ($error)');
    }
    if (!value) return true;
    return OnyxNotifications.requestPermission();
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
    if (!_anyEnabled) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_askedKey) ?? false) return;
      await prefs.setBool(_askedKey, true);
      await OnyxNotifications.requestPermission();
    } on Object catch (error) {
      debugPrint('NewEpisodeAlerts: permission non demandée ($error)');
    }
  }

  /// Le passage de l'app ouverte : au lancement, au retour au premier plan, au
  /// retour du serveur. C'est lui qui rattrape iOS, où le système décide seul
  /// de l'heure de la tâche de fond.
  ///
  /// Le serveur actif n'annonce aucun épisode : sa pastille « Nouvel épisode »
  /// est déjà à l'écran. Les autres serveurs, eux, sont précisément ceux
  /// qu'on ne regarde pas.
  static Future<void> checkInForeground(ApiClient api) async {
    if (!supported) return;
    // Le réglage se lit au démarrage : sans l'attendre, un passage partirait
    // sur la valeur par défaut chez quelqu'un qui a tout coupé.
    await start();
    if (!_anyEnabled) return;
    final now = DateTime.now();
    final last = _lastForegroundCheck;
    if (last != null && now.difference(last) < _foregroundPause) return;
    _lastForegroundCheck = now;
    final active = api.servers.active?.id;
    await Future.wait([
      if (enabled.value) _announce(api, quiet: {if (active != null) active}),
      // Aucune pastille ne dit les demandes à l'écran : le serveur actif
      // annonce comme les autres.
      if (requestsEnabled.value) _announceRequests(api),
    ]);
  }

  /// Le passage de la tâche de fond : rien de l'app n'est initialisé ici, ni
  /// la langue, ni le carnet de serveurs.
  static Future<void> runInBackground() async {
    final prefs = await SharedPreferences.getInstance();
    final episodes = (prefs.getBool(_enabledKey) ?? true) &&
        await episodesDue(prefs, DateTime.now());
    final requests = prefs.getBool(_requestsEnabledKey) ?? true;
    if (!episodes && !requests) return;
    await AppLanguage.load();
    final api = ApiClient();
    await api.servers.load();
    await Future.wait([
      if (episodes) _announce(api),
      if (requests) _announceRequests(api),
    ]);
  }

  /// Vrai quand le dernier tour des épisodes de la tâche de fond date d'une
  /// heure : elle passe tous les quarts d'heure pour les demandes, et ne fait
  /// les épisodes qu'une fois sur quatre. L'heure est notée avant le tour,
  /// pour qu'un serveur muet ne soit pas réinterrogé au quart d'heure suivant.
  @visibleForTesting
  static Future<bool> episodesDue(SharedPreferences prefs, DateTime now) async {
    final last = prefs.getInt(_episodesCheckedKey);
    final elapsed = now.millisecondsSinceEpoch - (last ?? 0);
    if (last != null && elapsed < episodeInterval.inMilliseconds) return false;
    await prefs.setInt(_episodesCheckedKey, now.millisecondsSinceEpoch);
    return true;
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
      await OnyxNotifications.showEpisode(alert, nameServer: nameServer);
    }
  }

  static Future<void> _announceRequests(ApiClient api) async {
    final alerts = await RequestAlertWatch(
      accounts: () => api.servers.accounts,
      fetch: (account, after) => api.requestFeedOf(account.id, after: after),
    ).check();
    final nameServer = api.servers.hasMultipleServers;
    for (final alert in alerts) {
      await OnyxNotifications.showRequest(alert, nameServer: nameServer);
    }
  }

  @visibleForTesting
  static void resetForTest() {
    enabled.value = true;
    requestsEnabled.value = true;
    _lastForegroundCheck = null;
    _starting = null;
    _permissionAsked = false;
  }
}
