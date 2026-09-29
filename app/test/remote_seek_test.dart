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

  testWidgets('un glissé vif sur le trackpad va plus loin', (tester) async {
    final seek = RemoteSeek(onCommit: (_) {});

    seek.step(1, fromSeconds: 100, durationSeconds: 1000, boost: 4);

    expect(seek.target, 140);
    seek.dispose();
  });

  testWidgets('la cible reste dans le film', (tester) async {
    final seek = RemoteSeek(onCommit: (_) {});

    seek.step(-1, fromSeconds: 5, durationSeconds: 1000, boost: 4);
    expect(seek.target, 0);

    seek.step(1, fromSeconds: 5, durationSeconds: 20, boost: 4);
    expect(seek.target, 20);
    seek.dispose();
  });
}
