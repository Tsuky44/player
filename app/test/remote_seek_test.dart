import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/remote_seek.dart';

void main() {
  // testWidgets pour son temps simulé : le compte à rebours est un Timer.
  testWidgets('les appuis se cumulent et ne cherchent qu’une fois arrêtés',
      (tester) async {
    var now = DateTime(2026, 9, 29);
    final commits = <int>[];
    final seek = RemoteSeek(onCommit: commits.add, clock: () => now);
    addTearDown(seek.dispose);

    for (var i = 0; i < 3; i++) {
      seek.step(1, fromSeconds: 100, durationSeconds: 1000);
      now = now.add(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(seek.target, 130);
    expect(commits, isEmpty);

    await tester.pump(RemoteSeek.settle);
    expect(commits, [130]);
    expect(seek.target, isNull);
  });

  testWidgets('un glissé lent sur le trackpad avance finement', (tester) async {
    final seek = RemoteSeek(onCommit: (_) {});

    // Un demi-trackpad, doigt posé.
    seek.scrub(1, speed: 1.5, fromSeconds: 100, durationSeconds: 7200);

    expect(seek.target, 120);
    seek.dispose();
  });

  testWidgets('le même glissé, plus vif, va bien plus loin', (tester) async {
    final slow = RemoteSeek(onCommit: (_) {});
    final fast = RemoteSeek(onCommit: (_) {});

    // Point par point, comme le trackpad le rapporte.
    for (var i = 0; i < 10; i++) {
      slow.scrub(0.1, speed: 2, fromSeconds: 100, durationSeconds: 7200);
      fast.scrub(0.1, speed: 8, fromSeconds: 100, durationSeconds: 7200);
    }

    expect(slow.target, 120);
    expect(fast.target, 100 + 320);
    slow.dispose();
    fast.dispose();
  });

  testWidgets('un geste, aussi vif soit-il, ne traverse pas tout le film',
      (tester) async {
    final seek = RemoteSeek(onCommit: (_) {});

    seek.scrub(0.5, speed: 40, fromSeconds: 0, durationSeconds: 1200);

    expect(seek.target, 300);
    seek.dispose();
  });

  testWidgets('la cible reste dans le film', (tester) async {
    final seek = RemoteSeek(onCommit: (_) {});

    seek.step(-1, fromSeconds: 5, durationSeconds: 1000);
    expect(seek.target, 0);

    seek.scrub(-1, speed: 1, fromSeconds: 5, durationSeconds: 1000);
    expect(seek.target, 0);

    seek.scrub(3, speed: 20, fromSeconds: 5, durationSeconds: 1000);
    expect(seek.target, 1000);
    seek.dispose();
  });
}
