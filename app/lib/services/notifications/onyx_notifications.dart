import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/tr.dart';
import '../../utils/app_platform.dart';
import '../new_episodes/new_episode_watch.dart';
import '../request_alerts/request_alert_watch.dart';
import 'notification_poster.dart';

/// Les notifications système de l'app : les afficher, et savoir laquelle on
/// vient de toucher (ADR-0059, ADR-0077).
///
/// Le seul fichier qui connaît `flutter_local_notifications` : le plugin ne
/// s'initialise qu'une fois par isolat, avec un seul rappel pour toutes les
/// notifications. Rien ici ne décide quoi annoncer : c'est [NewEpisodeWatch]
/// et [RequestAlertWatch].
abstract final class OnyxNotifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Les canaux Android. Leurs identifiants sont définitifs : Android y
  /// attache les réglages que l'utilisateur a faits (son, silence), et en
  /// changer les remettrait à zéro.
  static const String _episodesChannelId = 'new_episodes';
  static const String _requestsChannelId = 'new_requests';

  /// L'icône de la barre d'état, `res/drawable/ic_stat_onyx.xml`. Android n'en
  /// garde que la silhouette : l'icône de l'app y deviendrait un carré blanc.
  static const String _androidIcon = 'ic_stat_onyx';

  static Future<void>? _initializing;

  /// Appelé quand une notification d'épisode est touchée pendant que l'app
  /// tourne. Posé à part de l'initialisation : la tâche de fond initialise
  /// aussi le plugin, parfois dans le même isolat, et ne doit pas effacer ce
  /// rappel. Une notification de demande n'a pas de charge : la toucher ouvre
  /// l'app, sans plus.
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

  /// La notification d'épisode qui a lancé l'app, si elle était fermée. Le
  /// rappel [onOpen] ne voit pas celle-là : il n'existait pas encore.
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
  static Future<void> showEpisode(
    NewEpisodeAlert alert, {
    required bool nameServer,
  }) {
    return _show(
      id: alert.notificationId,
      title: alert.showTitle,
      body: alert.body(nameServer: nameServer),
      payload: alert.toPayload(),
      android: AndroidNotificationDetails(
        _episodesChannelId,
        tr('Nouveaux épisodes'),
        channelDescription:
            tr('Un épisode vient de sortir pour une série que vous suivez.'),
        // Dans le volet, avec son son, sans bandeau par-dessus l'écran : un
        // épisode n'a rien d'urgent.
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    );
  }

  /// Affiche [alert], une demande faite par un autre compte, avec l'affiche
  /// du média quand elle arrive à temps.
  static Future<void> showRequest(
    NewRequestAlert alert, {
    required bool nameServer,
  }) async {
    final title = alert.title;
    final body = alert.body(nameServer: nameServer);
    final poster = await NotificationPoster.load(alert.entry.posterUrl);
    final picture =
        poster == null ? null : ByteArrayAndroidBitmap(poster.bytes);
    final posterFile = poster?.filePath;
    return _show(
      id: alert.notificationId,
      title: title,
      body: body,
      iOS: DarwinNotificationDetails(
        attachments: [
          if (posterFile != null) DarwinNotificationAttachment(posterFile),
        ],
      ),
      android: AndroidNotificationDetails(
        // Repliée, l'affiche en vignette ; dépliée, en grand. La vignette se
        // cache alors pour ne pas montrer deux fois la même image.
        largeIcon: picture,
        styleInformation: picture == null
            ? null
            : BigPictureStyleInformation(
                picture,
                contentTitle: title,
                summaryText: body,
                hideExpandedLargeIcon: true,
              ),
        _requestsChannelId,
        tr('Nouvelles demandes'),
        channelDescription:
            tr('Un compte de votre serveur vient de demander un film ou une '
                'série.'),
        // Même registre que les épisodes : l'administrateur la lira à son
        // heure, rien ne presse au point de couvrir l'écran.
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    );
  }

  static Future<void> _show({
    required int id,
    required String title,
    required String body,
    required AndroidNotificationDetails android,
    DarwinNotificationDetails iOS = const DarwinNotificationDetails(),
    String? payload,
  }) async {
    await initialize();
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: NotificationDetails(android: android, iOS: iOS),
      );
    } on Object catch (error) {
      debugPrint('OnyxNotifications: affichage refusé ($error)');
    }
  }
}
