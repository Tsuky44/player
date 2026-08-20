/// Web implementation of [ServerDiscovery] — see `server_discovery.dart`.
///
/// A browser cannot open raw sockets, and it does not need to: the page is
/// served *by* the server, so `Uri.base.origin` is already the answer.
abstract final class ServerDiscovery {
  static const bool isSupported = false;

  static Future<String?> find({
    Iterable<int> ports = const [8080],
    Duration probeTimeout = const Duration(milliseconds: 400),
    Duration budget = const Duration(seconds: 15),
  }) async =>
      null;

  static Future<bool> reaches(String baseUrl) async => true;
}
