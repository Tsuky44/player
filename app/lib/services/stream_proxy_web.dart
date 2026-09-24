/// Le navigateur ouvre ses flux lui-même : pas de relais sur le web.
abstract final class StreamProxy {
  static Future<String> routeFor(String url) async => '';
}
