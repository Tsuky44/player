/// Le navigateur lit ses sessions par hls.js, qui a son propre tampon : pas de
/// relais local sur le web. Voir l'implémentation io.
class HlsPreload {
  HlsPreload._();

  static Future<HlsPreload?> open(String masterUrl) async => null;

  String get masterUrl => '';
  double get readySeconds => 0;
  Future<void> warm({double seconds = 6, required Duration budget}) async {}
  void close() {}
}
