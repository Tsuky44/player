import 'package:dio/dio.dart';

/// Relit un document seulement s'il a changé, grâce à son ETag.
///
/// Les listes de la médiathèque renvoient tout le catalogue à chaque ouverture
/// de l'écran. Le serveur les accompagne d'un ETag et répond 304, sans corps,
/// quand l'appareil a déjà la dernière version : c'est alors celle d'ici qui
/// sert. Le navigateur le fait tout seul pour le web ; ailleurs, c'est ce
/// cache.
///
/// La clé porte le compte : deux comptes du même serveur n'ont pas la même
/// progression, donc pas le même document.
class ConditionalGetCache {
  final Map<String, ({String etag, Object? data})> _entries = {};

  Future<Object?> get(Dio dio, String path, {required String scope}) async {
    final key = '$scope|$path';
    final cached = _entries[key];
    final response = await dio.get<Object?>(
      path,
      options: Options(
        headers: cached == null ? null : {'If-None-Match': cached.etag},
        validateStatus: (status) =>
            status != null &&
            ((status >= 200 && status < 300) || status == 304),
      ),
    );
    if (response.statusCode == 304 && cached != null) return cached.data;
    final etag = response.headers.value('etag');
    if (etag != null && etag.isNotEmpty) {
      _entries[key] = (etag: etag, data: response.data);
    } else {
      _entries.remove(key);
    }
    return response.data;
  }
}
