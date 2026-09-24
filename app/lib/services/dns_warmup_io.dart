import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Les adresses des serveurs, résolues en arrière-plan et gardées par l'app.
///
/// Sous Windows, un serveur DNS mort sur une des cartes réseau (la box, un
/// adaptateur VPN) fait attendre toute résolution hors cache : 11 s mesurées,
/// identiques sur `Resolve-DnsName` hors d'Onyx et dans la libmpv seule. Le
/// lecteur la payait devant la première image, en silence entre le hook
/// `on_load` et le premier démultiplexeur de la trace de démarrage.
///
/// Garder le cache du système au chaud ne suffit pas : ses entrées IPv4 et
/// IPv6 expirent chacune toutes les cinq minutes derrière Cloudflare, une
/// résolution servie par le cache ne les renouvelle pas, et une requête qui le
/// contourne ne les renouvelle pas non plus (mesuré). Chaque expiration rouvre
/// une fenêtre d'une vingtaine de secondes où la lecture repaie les 11 s.
///
/// Alors l'app garde ses propres adresses : la dernière réponse réussie reste
/// valable jusqu'à la suivante, même expirée côté système. Le lecteur passe par
/// [StreamProxy], qui se connecte à ces adresses sans jamais demander le nom
/// au système. Le rappel toutes les [_interval] entretient aussi le cache du
/// système pour le reste de l'app.
abstract final class DnsWarmup {
  static final Set<String> _hosts = {};
  static final Set<String> _inFlight = {};
  static final Map<String, List<InternetAddress>> _addresses = {};
  static Timer? _timer;

  static const _interval = Duration(seconds: 20);

  /// Au-delà, la résolution est notée au journal : c'est le symptôme que ce
  /// service masque, et il doit rester visible.
  static const _slow = Duration(milliseconds: 500);

  /// Ajoute les hôtes de [urls] à ceux qu'on suit, et résout aussitôt les
  /// nouveaux.
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

  /// La dernière réponse réussie pour [host], IPv4 d'abord ; null si le nom
  /// n'a jamais été résolu. Peut être plus ancienne que la durée de vie de
  /// l'enregistrement : c'est voulu, voir la documentation de la classe.
  static List<InternetAddress>? addressesFor(String host) =>
      _addresses[host.toLowerCase()];

  /// Le nom à résoudre pour [url], ou null : une adresse IP ou `localhost`
  /// n'a rien à demander au DNS.
  @visibleForTesting
  static String? hostToWarm(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    if (host.isEmpty || host == 'localhost') return null;
    if (InternetAddress.tryParse(host) != null) return null;
    return host;
  }

  /// IPv4 d'abord : l'IPv6 est annoncé par Cloudflare mais souvent sans route
  /// côté poste, et chaque adresse morte essayée d'abord coûte une tentative.
  @visibleForTesting
  static List<InternetAddress> preferIpv4(List<InternetAddress> found) => [
        ...found.where((a) => a.type == InternetAddressType.IPv4),
        ...found.where((a) => a.type != InternetAddressType.IPv4),
      ];

  @visibleForTesting
  static void rememberForTest(String host, List<InternetAddress> addresses) =>
      _addresses[host.toLowerCase()] = addresses;

  static Future<void> _resolve(String host) async {
    if (!_inFlight.add(host)) return;
    final clock = Stopwatch()..start();
    try {
      final found = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 30));
      if (found.isNotEmpty) _addresses[host] = preferIpv4(found);
      if (clock.elapsed >= _slow) {
        debugPrint('DNS: $host résolu en ${clock.elapsedMilliseconds}ms — '
            'le DNS de ce poste est lent ; la lecture se sert de la dernière '
            'adresse connue');
      }
    } catch (e) {
      // La dernière adresse connue reste : un DNS en panne ne doit pas
      // effacer ce qu'on savait.
      debugPrint('DNS: $host non résolu (${clock.elapsedMilliseconds}ms): $e');
    } finally {
      _inFlight.remove(host);
    }
  }
}
