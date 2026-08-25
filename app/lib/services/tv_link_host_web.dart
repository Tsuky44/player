import 'dart:async';

import 'tv_link.dart';

/// Web stub — a browser tab cannot listen on a socket. See `tv_link_host.dart`.
class TvLinkHost implements TvLinkSession {
  static bool get isSupported => false;

  @override
  Future<TvLinkOffer?> start({required String deviceName}) async => null;

  /// Never resolves: nothing can deliver to a browser tab. The screen never
  /// reaches the point of awaiting it, because [isSupported] is false.
  @override
  Future<TvLinkPayload> get linked => Completer<TvLinkPayload>().future;

  @override
  Future<void> stop() async {}
}
