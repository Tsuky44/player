import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Garde les noms des serveurs dans le cache DNS du système, pour que le
/// lecteur ne paie jamais leur résolution.
///
/// mpv ouvre le flux par son propre client HTTP (celui de FFmpeg), qui résout
/// le nom au moment d'ouvrir — sur le chemin de la première image. Tant que le
/// nom est dans le cache du système, ça coûte une milliseconde. Hors cache,
/// ça coûte ce que le DNS du poste veut bien coûter, et sous Windows un
/// serveur DNS mort sur une des cartes réseau (la box, un adaptateur VPN) le
/// fait attendre avant de passer au suivant : 11 s mesurées, identiques sur
/// `Resolve-DnsName` hors d'Onyx, et identiques aux 11,4 s de silence entre le
/// hook `on_load` et le premier démultiplexeur dans la trace de démarrage. Le
/// cas type est le média partagé, dont le flux vient d'un autre serveur que
/// celui que l'app interroge depuis le lancement : son nom n'a jamais été
/// résolu.
///
/// Le cache du système est commun à tous les clients du poste et respecte la
/// durée de vie des enregistrements (cinq minutes derrière Cloudflare). Un
/// rappel toutes les [_interval] le retrouve encore en cache la plupart du
/// temps — une réponse locale, sans réseau — et le renouvelle juste après
/// expiration, en arrière-plan, loin de tout démarrage.
abstract final class DnsWarmup {
  static final Set<String> _hosts = {};
  static final Set<String> _inFlight = {};
  static Timer? _timer;

  /// Plus court que toute durée de vie raisonnable : la fenêtre où un nom
  /// expiré attend son renouvellement reste de l'ordre de cet intervalle.
  static const _interval = Duration(seconds: 20);

  /// Au-delà, la résolution est notée au journal : c'est le symptôme que ce
  /// service masque, et il doit rester visible.
  static const _slow = Duration(milliseconds: 500);

  /// Ajoute les hôtes de [urls] à ceux qu'on garde au chaud, et résout
  /// aussitôt les nouveaux.
  static void watch(Iterable<String> urls) {
    for (final url in urls) {
      final host = hostToWarm(url);
      if (host == null || !_hosts.add(host)) continue;
      unawaited(_resolve(host));
    }
    if (_hosts.isNotEmpty) {
      _timer ??= Timer.periodic(_interval, (_) {
        for (final host in _hosts) {
          unawaited(_resolve(host));
        }
      });
    }
  }

  /// Le nom à résoudre pour [url], ou null : une adresse IP ou `localhost`
  /// n'a rien à demander au DNS.
  @visibleForTesting
  static String? hostToWarm(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    if (host.isEmpty || host == 'localhost') return null;
    if (InternetAddress.tryParse(host) != null) return null;
    return host;
  }

  static Future<void> _resolve(String host) async {
    if (!_inFlight.add(host)) return;
    final clock = Stopwatch()..start();
    try {
      await InternetAddress.lookup(host).timeout(const Duration(seconds: 30));
      if (clock.elapsed >= _slow) {
        debugPrint('DNS: $host résolu en ${clock.elapsedMilliseconds}ms — '
            'le DNS de ce poste est lent, le pré-chauffage évite de le payer '
            'au lancement');
      }
    } catch (e) {
      debugPrint('DNS: $host non résolu (${clock.elapsedMilliseconds}ms): $e');
    } finally {
      _inFlight.remove(host);
    }
  }
}
