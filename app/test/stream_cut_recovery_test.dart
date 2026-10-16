import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/playback/stream_cut_recovery.dart';

void main() {
  const episode = Duration(minutes: 42);

  StreamCutRecovery recovery({
    required Future<bool> Function(int seconds) reopenAt,
    bool Function()? alive,
  }) =>
      StreamCutRecovery(
        reopenAt: reopenAt,
        alive: alive ?? () => true,
        retryDelays: const [Duration.zero],
        steadyDelay: Duration.zero,
      );

  test('an end announced mid-episode is a cut, never the next episode', () {
    final cuts = recovery(reopenAt: (_) async => true);
    expect(
      cuts.isCut(position: const Duration(minutes: 17), duration: episode),
      isTrue,
    );
  });

  test('an end during the credits is the real end', () {
    final cuts = recovery(reopenAt: (_) async => true);
    expect(
      cuts.isCut(
          position: episode - const Duration(seconds: 12), duration: episode),
      isFalse,
    );
  });

  test('a downloaded file or an unknown duration is never second-guessed', () {
    final cuts = recovery(reopenAt: (_) async => true);
    const mid = Duration(minutes: 17);
    expect(cuts.isCut(position: mid, duration: episode, localFile: true),
        isFalse);
    expect(cuts.isCut(position: mid, duration: Duration.zero), isFalse);
  });

  test('a restarting server is retried until it answers, at the same second',
      () async {
    final asked = <int>[];
    var downFor = 3;
    final cuts = recovery(reopenAt: (seconds) async {
      asked.add(seconds);
      if (downFor-- > 0) throw StateError('connexion refusée');
      return true;
    });

    await cuts.recover(1020);

    expect(asked, [1020, 1020, 1020, 1020]);
    expect(cuts.isRecovering, isFalse);
  });

  test('a second end at the recovered point is the real end of a short file',
      () async {
    final cuts = recovery(reopenAt: (_) async => true);
    await cuts.recover(1020);
    expect(
      cuts.isCut(position: const Duration(seconds: 1022), duration: episode),
      isFalse,
    );
  });

  test('leaving the player stops the retries', () async {
    var open = true;
    var attempts = 0;
    final cuts = recovery(
      alive: () => open,
      reopenAt: (_) async {
        if (++attempts == 2) open = false;
        return false;
      },
    );
    await cuts.recover(1020);
    expect(attempts, 2);
  });
}
