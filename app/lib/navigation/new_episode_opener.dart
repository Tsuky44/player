import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media.dart';
import '../providers/auth_provider.dart';
import '../screens/library/show_detail_screen.dart';
import '../services/new_episodes/new_episode_watch.dart';

/// Ouvre la fiche de la série quand on touche la notification d'un nouvel
/// épisode (ADR-0059).
///
/// La notification peut arriver avant que l'app sache qui est connecté — elle
/// l'a peut-être lancée — et viser un autre serveur que celui qui est à
/// l'écran. La demande attend donc la session, puis bascule sur le bon
/// serveur : un identifiant de série ne veut rien dire ailleurs (ADR-0013).
class NewEpisodeOpener {
  NewEpisodeOpener({required this.auth, required this.navigatorKey}) {
    auth.addListener(_tryOpen);
  }

  final AuthProvider auth;
  final GlobalKey<NavigatorState> navigatorKey;

  NewEpisodeAlert? _pending;
  bool _opening = false;

  void open(NewEpisodeAlert alert) {
    _pending = alert;
    _tryOpen();
  }

  Future<void> _tryOpen() async {
    final alert = _pending;
    if (alert == null || _opening) return;
    if (auth.isInitializing || !auth.isAuthenticated) return;
    _opening = true;
    _pending = null;
    try {
      if (auth.activeServer?.id != alert.accountId) {
        // Compte retiré depuis, ou serveur muet : l'app reste où elle est.
        if (!await auth.switchServer(alert.accountId)) return;
      }
      // La bascule reconstruit l'accueil : la fiche se pose sur la pile une
      // fois qu'il est en place, pas pendant.
      await WidgetsBinding.instance.endOfFrame;
      unawaited(navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => ShowDetailScreen(
            show: Media(
              id: alert.showId,
              type: MediaType.show,
              title: alert.showTitle,
              duration: 0,
              posterUrl: alert.posterUrl,
              createdAt: DateTime.now(),
            ),
          ),
        ),
      ));
    } finally {
      _opening = false;
    }
  }

  void dispose() => auth.removeListener(_tryOpen);
}
