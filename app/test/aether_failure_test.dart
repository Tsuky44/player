import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/aether_failure.dart';
import 'package:onyx/screens/player/playback/playback_session.dart';
import 'package:onyx_player_apple/onyx_player_apple.dart';

void main() {
  test('un segment que le moteur ne sait pas produire déclenche le repli HLS', () {
    final failure = aetherFailureOf(
      OnyxApplePlayerErrorKind.source,
      'Source segment could not be produced (code -5)',
    );
    expect(failure.kind, PlaybackFailureKind.unsupported);
  });

  test('une vraie source perdue reste une source', () {
    final failure = aetherFailureOf(
      OnyxApplePlayerErrorKind.source,
      'Connection lost',
    );
    expect(failure.kind, PlaybackFailureKind.source);
  });

  test('sans message, le nom du genre sert de texte', () {
    final failure = aetherFailureOf(OnyxApplePlayerErrorKind.unknown, null);
    expect(failure.kind, PlaybackFailureKind.unknown);
    expect(failure.toString(), contains('unknown'));
  });
}
