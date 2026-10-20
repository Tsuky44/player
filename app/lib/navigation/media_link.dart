import 'package:flutter/material.dart';

import '../models/models.dart';
import '../screens/library/movie_detail_screen.dart';
import '../screens/library/show_detail_screen.dart';

/// Le lien `?movie=ID` ou `?show=ID` qui ouvre une fiche (ADR-0073).
///
/// OnyxHub, qui montre le catalogue TMDB, envoie ici avec « Lire dans Onyx ».
/// Comme le code d'appairage de [TvPairingLink], l'identifiant arrive avant
/// que l'app sache qui est connecté : il attend la coquille, et ne sert
/// qu'une fois. Hors du web, [Uri.base] n'a pas de requête et rien ne se passe.
abstract final class MediaLink {
  static (MediaType, int)? _pending;

  static void capture() => _pending = parse(Uri.base);

  /// Le titre que vise [uri], ou null. Visible pour les tests.
  static (MediaType, int)? parse(Uri uri) {
    for (final (key, type) in const [
      ('movie', MediaType.movie),
      ('show', MediaType.show)
    ]) {
      final id = int.tryParse(uri.queryParameters[key] ?? '');
      if (id != null && id > 0) return (type, id);
    }
    return null;
  }

  /// La fiche à ouvrir, oubliée aussitôt : une reconstruction de la coquille
  /// ne la rouvre pas derrière l'utilisateur.
  static Route<void>? takeRoute() {
    final pending = _pending;
    _pending = null;
    if (pending == null) return null;
    final (type, id) = pending;
    // La fiche se charge par son identifiant : le titre vide n'est affiché
    // que le temps de cette lecture.
    final media = Media(
        id: id, type: type, title: '', duration: 0, createdAt: DateTime.now());
    return MaterialPageRoute<void>(
      builder: (_) => type == MediaType.show
          ? ShowDetailScreen(show: media)
          : MovieDetailScreen(movie: media),
    );
  }
}
