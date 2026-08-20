import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Native implementation of [ServerDiscovery] — see `server_discovery.dart`.
///
/// The default base URL for an Android build is the emulator's loopback alias,
/// which is correct on a developer machine and unreachable everywhere else. On
/// a real television that address is the whole reason pairing never starts, and
/// the fix cannot be "type the IP": the screen has a remote and no keyboard.
///
/// So the app sweeps its own /24 for something that answers like an Onyx
/// server. That is 254 TCP connects, run in slices, each with a fraction of a
/// second to answer — a couple of seconds on a home network, against a minute
/// of hunting characters on an on-screen keyboard.
abstract final class ServerDiscovery {
  static const bool isSupported = true;

  /// How many probes are in flight at once. High enough that a /24 finishes in
  /// a few rounds, low enough that a cheap TV's network stack keeps up — every
  /// probe is one socket, and sticks run out of descriptors long before a
  /// desktop would.
  static const int _concurrency = 48;

  /// The port a stock server listens on, plus the one a reverse proxy in front
  /// of it usually takes. Kept to two: every extra port multiplies the sweep,
  /// and 443 would need a certificate the home server does not have.
  static const List<int> defaultPorts = [8080, 80];

  /// Sweeps the local network for a server that answers the unauthenticated
  /// state endpoint. Returns a base URL, or null if the budget ran out first.
  ///
  /// [ports] is tried host by host rather than sweep by sweep: a machine that
  /// accepts on 8080 is answered in the same round it was found, instead of
  /// after two more full passes.
  static Future<String?> find({
    Iterable<int> ports = defaultPorts,
    Duration probeTimeout = const Duration(milliseconds: 400),
    Duration budget = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(budget);
    final candidates = await _candidates(ports.toList());
    if (candidates.isEmpty) return null;

    for (var i = 0; i < candidates.length; i += _concurrency) {
      if (DateTime.now().isAfter(deadline)) return null;

      final slice = candidates.sublist(
        i,
        math.min(i + _concurrency, candidates.length),
      );
      final results = await Future.wait(
        slice.map((candidate) => _probe(candidate, probeTimeout)),
      );
      for (final hit in results) {
        if (hit != null) return hit;
      }
    }
    return null;
  }

  /// Whether an address answers as an Onyx server right now. Used to decide
  /// whether a remembered address is still worth trying before sweeping.
  static Future<bool> reaches(String baseUrl) async {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) return false;
    return _confirm(uri.replace(path: '/api/auth/state'),
        const Duration(seconds: 3));
  }

  /// Every address on the same /24 as one of this device's own interfaces.
  ///
  /// Ordered outward from the device's own last octet: a home server sits a
  /// handful of addresses from whatever DHCP handed the television, far more
  /// often than it sits at .200.
  static Future<List<_Candidate>> _candidates(List<int> ports) async {
    final out = <_Candidate>[];
    final seen = <String>{};

    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
    } catch (_) {
      return out;
    }

    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final octets = address.address.split('.');
        if (octets.length != 4) continue;
        // 169.254.x.x is what an interface gets when DHCP failed. Nothing is
        // reachable there, and sweeping it burns the whole budget.
        if (octets[0] == '169' && octets[1] == '254') continue;

        final self = int.tryParse(octets[3]);
        if (self == null) continue;
        final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';

        for (final host in _outward(self)) {
          final ip = '$prefix.$host';
          if (!seen.add(ip)) continue;
          for (final port in ports) {
            out.add(_Candidate(ip, port));
          }
        }
      }
    }
    return out;
  }

  /// 1..254 reordered by distance from [self]: self, self±1, self±2, …
  static List<int> _outward(int self) {
    final ordered = <int>[];
    for (var distance = 0; distance < 255; distance++) {
      for (final host in distance == 0
          ? [self]
          : [self - distance, self + distance]) {
        if (host >= 1 && host <= 254) ordered.add(host);
      }
    }
    return ordered;
  }

  /// One address: a TCP connect to weed out the 250 hosts that are not there,
  /// then an HTTP round trip to tell an Onyx server from a printer.
  static Future<String?> _probe(_Candidate candidate, Duration timeout) async {
    Socket socket;
    try {
      socket = await Socket.connect(
        candidate.host,
        candidate.port,
        timeout: timeout,
      );
    } catch (_) {
      return null;
    }
    socket.destroy();

    final base = candidate.baseUrl;
    final confirmed = await _confirm(
      Uri.parse('$base/api/auth/state'),
      const Duration(seconds: 2),
    );
    return confirmed ? base : null;
  }

  /// `/api/auth/state` is the one endpoint that is unauthenticated, cheap, and
  /// shaped distinctively enough that no other service on the network answers
  /// it by accident.
  static Future<bool> _confirm(Uri uri, Duration timeout) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'Onyx/discovery';
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return false;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final decoded = jsonDecode(body);
      return decoded is Map && decoded.containsKey('setup_required');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

class _Candidate {
  final String host;
  final int port;

  const _Candidate(this.host, this.port);

  String get baseUrl => port == 80 ? 'http://$host' : 'http://$host:$port';
}
