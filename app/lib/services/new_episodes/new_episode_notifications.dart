import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/tr.dart';
import '../../utils/app_platform.dart';
import 'new_episode_watch.dart';

/// La notification système d'un nouvel épisode : l'afficher, et savoir
/// laquelle on vient de toucher (ADR-0059).
///
/// Le seul fichier qui connaît `flutter_local_notifications`. Rien ici ne
/// décide quoi annoncer : c'est [NewEpisodeWatch].
abstract final class NewEpisodeNotifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Le canal Android. Son identifiant est définitif : Android y attache les
  /// réglages que l'utilisateur a faits (son, silence), et en changer les
  /// remettrait à zéro.
  static const String _channelId = 'new_episodes';

  /// L'icône de la barre d'état, `res/drawable/ic_stat_onyx.xml`. Android n'en
  /// garde que la silhouette : l'icône de l'app y deviendrait un carré blanc.
  static const String _androidIcon = 'ic_stat_onyx';

  static Future<void>? _initializing;

  /// Appelé quand une notification est touchée pendant que l'app tourne.
  /// Posé à part de l'initialisation : la tâche de fond initialise aussi le
  /// plugin, parfois dans le même isolat, et ne doit pas effacer ce rappel.
  static void Function(NewEpisodeAlert alert)? onOpen;

  static Future<void> initialize() => _initializing ??= _initialize();

  static Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_androidIcon),
        // La permission se demande à son heure ([requestPermission]), pas à
        // l'initialisation : la tâche de fond n'a pas d'écran où la poser.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final alert = NewEpisodeAlert.fromPayload(response.payload);
        if (alert != null) onOpen?.call(alert);
      },
    );
  }

  /// La notification qui a lancé l'app, si elle était fermée. Le rappel
  /// [onOpen] ne voit pas celle-là : il n'existait pas encore.
  static Future<NewEpisodeAlert?> launchAlert() async {
    await initialize();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return NewEpisodeAlert.fromPayload(details.notificationResponse?.payload);
  }

  /// Pose la question du système. Rend faux quand elle est refusée — ou
  /// qu'Android ne la pose plus, après deux refus.
  static Future<bool> requestPermission() async {
    await initialize();
    if (AppPlatform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin>()
              ?.requestNotificationsPermission() ??
          false;
    }
    if (AppPlatform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, sound: true) ??
          false;
    }
    return false;
  }

  /// Affiche [alert]. Sans la permission, le système l'écarte en silence.
  static Future<void> show(
    NewEpisodeAlert alert, {
    required bool nameServer,
  }) async {
    await initialize();
    try {
      await _plugin.show(
        id: alert.notificationId,
        title: alert.showTitle,
        body: alert.body(nameServer: nameServer),
        payload: alert.toPayload(),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            tr('Nouveaux épisodes'),
            channelDescription:
                tr('Un épisode vient de sortir pour une série que vous '
                    'suivez.'),
            // Dans le volet, avec son son, sans bandeau par-dessus l'écran :
            // un épisode n'a rien d'urgent.
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    } on Object catch (error) {
      debugPrint('NewEpisodeNotifications: affichage refusé ($error)');
    }
  }
}
