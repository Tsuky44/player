import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../models/models.dart';
import '../screens/library/movie_detail_screen.dart';
import '../screens/library/show_detail_screen.dart';
import '../services/api_client.dart';

/// Le lien `onyx://play?tmdbId=ID&type=movie|tv` : « Lire sur Onyx » depuis
/// MediaHub (ADR-0091).
///
/// Il ouvre l'app et lance la lecture : le film à sa position sauvegardée, la
/// série à l'épisode que le serveur donne à reprendre (celui en cours, sinon le
/// suivant non vu). Comme [MediaLink], le lien arrive avant que l'app sache qui
/// est connecté : il attend la coquille dans [pending], et ne sert qu'une fois.
abstract final class PlayLink {
  static final ValueNotifier<(MediaType, int)?> pending = ValueNotifier(null);

  static StreamSubscription<Uri>? _subscription;

  /// Lit le lien qui a lancé l'app et ceux qui arrivent app ouverte. Sur le
  /// web et les plateformes sans schéma, rien ne se passe.
  static Future<void> listen() async {
    if (kIsWeb || _subscription != null) return;
    try {
      final links = AppLinks();
      _subscription = links.uriLinkStream.listen(_accept, onError: (_) {});
      final initial = await links.getInitialLink();
      if (initial != null) _accept(initial);
    } catch (_) {
      // Plateforme sans prise en charge : l'app s'ouvre sans lien.
    }
  }

  static void _accept(Uri uri) {
    final target = parse(uri);
    if (target != null) pending.value = target;
  }

  /// Le titre que vise [uri], ou null. Visible pour les tests.
  static (MediaType, int)? parse(Uri uri) {
    if (uri.scheme != 'onyx' || uri.host != 'play') return null;
    final tmdbId = int.tryParse(uri.queryParameters['tmdbId'] ?? '');
    if (tmdbId == null || tmdbId <= 0) return null;
    return switch (uri.queryParameters['type']) {
      'movie' => (MediaType.movie, tmdbId),
      'tv' || 'show' => (MediaType.show, tmdbId),
      _ => null,
    };
  }

  /// La fiche à ouvrir avec la lecture lancée, oubliée aussitôt. Null quand
  /// rien n'attend, ou que la bibliothèque n'a pas le titre (dit à l'écran).
  static Future<Route<void>?> takeRoute(
      ApiClient api, ScaffoldMessengerState? messenger) async {
    final target = pending.value;
    pending.value = null;
    if (target == null) return null;
    final (type, tmdbId) = target;
    try {
      final index = await api.getLibraryTmdbIndex();
      final id =
          (type == MediaType.show ? index.shows : index.movies)[tmdbId];
      if (id != null) return routeFor(type, id);
    } catch (_) {
      // Même message qu'un titre absent : la lecture n'a pas pu être lancée.
    }
    messenger?.showSnackBar(
      SnackBar(content: Text(tr('Ce titre n’est pas dans ta bibliothèque'))),
    );
    return null;
  }

  /// La fiche de [id], qui lance la lecture dès qu'elle sait quoi lire.
  static Route<void> routeFor(MediaType type, int id) {
    final media = Media(
        id: id, type: type, title: '', duration: 0, createdAt: DateTime.now());
    return MaterialPageRoute<void>(
      builder: (_) => type == MediaType.show
          ? ShowDetailScreen(show: media, autoPlay: true)
          : MovieDetailScreen(movie: media, autoPlay: true),
    );
  }
}
