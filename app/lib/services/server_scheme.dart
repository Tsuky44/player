import 'package:dio/dio.dart';

import '../models/server_account.dart';
import 'server_registry.dart';

/// HTTPS dès que le serveur le parle, HTTP seulement quand il ne parle que ça.
///
/// Une adresse tapée sans préfixe devenait toujours `http://`, et un compte
/// enregistré en HTTP y restait même après que son serveur était passé en
/// HTTPS (TLS_CERT_FILE, ou un proxy TLS devant) : mots de passe et jetons
/// continuaient de circuler en clair, ou la connexion tombait. Voir ADR-0080.
///
/// Le sens est unique : une adresse en `https://` n'est jamais rabattue sur
/// HTTP. Un intermédiaire qui bloquerait HTTPS ne doit pas pouvoir faire
/// repasser l'app en clair ; c'est à l'utilisateur de retaper `http://`.
///
/// Le certificat est vérifié comme pour toute requête : un serveur au
/// certificat auto-signé reste en HTTP.
class ServerScheme {
  ServerScheme({
    Future<bool> Function(String baseUrl)? probe,
    this.timeout = const Duration(seconds: 2),
  }) : _probe = probe;

  /// Celui de l'app ; les tests en posent un autre.
  static ServerScheme instance = ServerScheme();

  /// Le temps laissé à un serveur pour répondre en HTTPS. Court : sur un
  /// serveur en HTTP, la poignée de main échoue tout de suite, et ce délai ne
  /// se paie que devant un serveur éteint.
  final Duration timeout;

  final Future<bool> Function(String baseUrl)? _probe;

  /// Les réponses récentes : l'écran de connexion fixe la même adresse
  /// plusieurs fois de suite, à la sonde puis à la connexion.
  final Map<String, (String, DateTime)> _recent = {};
  static const _recentFor = Duration(minutes: 1);

  /// L'adresse à utiliser pour [raw] : en HTTPS si le serveur y répond, telle
  /// quelle sinon.
  Future<String> resolve(String raw) async {
    final normalized = ServerAccount.normalizeUrl(raw);
    if (!normalized.startsWith('http://')) return normalized;
    final cached = _recent[normalized];
    if (cached != null && DateTime.now().difference(cached.$2) < _recentFor) {
      return cached.$1;
    }
    final resolved = await upgrade(normalized) ?? normalized;
    _recent[normalized] = (resolved, DateTime.now());
    return resolved;
  }

  /// La version HTTPS de [url] quand le serveur y répond, sinon null.
  Future<String?> upgrade(String url) async {
    if (!url.startsWith('http://')) return null;
    final secure = 'https://${url.substring('http://'.length)}';
    return await _speaksOnyx(secure) ? secure : null;
  }

  /// Fait passer en HTTPS chaque compte enregistré dont le serveur y répond,
  /// sessions comprises. Rend vrai quand l'adresse du compte actif a changé.
  Future<bool> upgradeAccounts(ServerRegistry registry) async {
    await registry.load();
    final insecure =
        registry.accounts.where((a) => a.url.startsWith('http://')).toList();
    if (insecure.isEmpty) return false;

    // Un sondage par serveur, tous en même temps : le lancement n'attend que
    // le plus lent.
    final secure = <String, String>{};
    await Future.wait({for (final a in insecure) a.url}.map((url) async {
      final upgraded = await upgrade(url);
      if (upgraded != null) secure[url] = upgraded;
    }));
    if (secure.isEmpty) return false;

    final activeId = registry.active?.id;
    var nextActiveId = activeId;
    for (final account in insecure) {
      final target = secure[account.url];
      if (target == null) continue;
      final moved = await registry.updateUrl(account.id, target);
      if (account.id == activeId) nextActiveId = moved?.id;
    }
    // updateUrl rend actif le compte qu'il déplace : on revient à celui
    // qu'on regardait.
    if (nextActiveId != null) await registry.activate(nextActiveId);
    return activeId != null && nextActiveId != activeId;
  }

  Future<bool> _speaksOnyx(String base) async {
    final probe = _probe;
    if (probe != null) return probe(base);
    final dio = Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      responseType: ResponseType.json,
    ));
    try {
      final response = await dio.get<dynamic>('$base/api/ping');
      final data = response.data;
      return response.statusCode == 200 && data is Map && data['status'] == 'ok';
    } catch (_) {
      // Pas de HTTPS ici (refus, certificat invalide, délai) : le serveur
      // reste à l'adresse qu'on avait.
      return false;
    } finally {
      dio.close(force: true);
    }
  }
}
