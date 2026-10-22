import 'package:flutter/foundation.dart';

import '../models/server_account.dart';
import 'client_log.dart';

/// Les photos de profil déjà lues, en mémoire.
///
/// Elles se lisent avec le jeton de leur compte (ADR-0078), ce que le cache
/// d'images partagé ne sait pas faire : il ne présente qu'un seul en-tête par
/// adresse. La clé porte la version de la photo, si bien qu'un nouvel envoi
/// n'a rien à invalider — l'ancienne entrée n'est simplement plus demandée.
class AvatarPhotoCache {
  AvatarPhotoCache._();

  /// Quelques personnes par serveur, quelques serveurs : au-delà, la plus
  /// ancienne sort, et sera relue si elle revient à l'écran.
  static const _capacity = 24;

  static final Map<String, Future<Uint8List?>> _photos = {};

  /// La photo de [account] dans sa [version], lue une fois par [fetch].
  static Future<Uint8List?> photoFor(
    ServerAccount account,
    String version,
    Future<Uint8List?> Function(ServerAccount) fetch,
  ) {
    final key = '${account.id}|$version';
    final known = _photos.remove(key);
    if (known != null) return _photos[key] = known;
    if (_photos.length >= _capacity) _photos.remove(_photos.keys.first);
    return _photos[key] = fetch(account).catchError((Object error) {
      // Serveur injoignable ou session close : la pastille garde l'initiale,
      // et l'entrée sort pour qu'un prochain affichage réessaie.
      ClientLog.error('AvatarPhotoCache: $error');
      _photos.remove(key);
      return null;
    });
  }

  /// Range une photo qu'on vient d'envoyer : pas besoin de la relire.
  static void put(ServerAccount account, String version, Uint8List photo) {
    _photos['${account.id}|$version'] = SynchronousFuture(photo);
  }

  @visibleForTesting
  static void resetForTest() => _photos.clear();
}
