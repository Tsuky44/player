import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/services/dns_warmup_io.dart';

void main() {
  test('warms the host of a server URL', () {
    expect(DnsWarmup.hostToWarm('https://player.yonix.me'), 'player.yonix.me');
    expect(DnsWarmup.hostToWarm(' https://Onyx.Tsuky.ovh:8443/api '),
        'onyx.tsuky.ovh');
  });

  test('skips what the DNS has nothing to say about', () {
    expect(DnsWarmup.hostToWarm('http://192.168.1.20:8080'), isNull);
    expect(DnsWarmup.hostToWarm('http://[fd7a:115c::1]:8080'), isNull);
    expect(DnsWarmup.hostToWarm('http://localhost:8080'), isNull);
    expect(DnsWarmup.hostToWarm(''), isNull);
  });
}
