import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/playback_session.dart';
import 'package:onyx/screens/player/playback/playback_stats.dart';

/// Un moteur qui répond ce qu'on lui a dit de répondre.
///
/// Seul `readDiagnostics` est appelé par le collecteur ; le reste du contrat
/// n'a pas à exister pour que la mesure soit vérifiable.
class _FakeSession implements PlaybackSession {
  _FakeSession(this._answers);

  final List<PlaybackDiagnostics> _answers;
  int _index = 0;

  @override
  Future<PlaybackDiagnostics> readDiagnostics() async {
    final answer = _answers[_index.clamp(0, _answers.length - 1)];
    _index++;
    return answer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  test('moyenne la cadence sur les échantillons, pas sur le dernier', () async {
    final collector = PlaybackStatsCollector();
    final session = _FakeSession([
      const PlaybackDiagnostics(estimatedFps: 24, containerFps: 23.976),
      const PlaybackDiagnostics(estimatedFps: 12, containerFps: 23.976),
    ]);
    collector.start(session);
    // `start` prend le premier échantillon ; `finish` prend le second.
    final stats = await collector.finish();

    expect(stats.sampleCount, 2);
    expect(stats.averageFps, 18);
    expect(stats.containerFps, 23.976);
  });

  test('rattrape un compteur que le moteur a remis à zéro', () async {
    // Un changement de qualité rouvre le flux : ExoPlayer comme mpv repartent
    // de zéro. Sans rattrapage, une séance de 900 images perdues en
    // rapporterait 20 — celles d'après la bascule.
    final collector = PlaybackStatsCollector();
    final session = _FakeSession([
      const PlaybackDiagnostics(droppedByDisplay: 500, bytesLoaded: 1000),
      const PlaybackDiagnostics(droppedByDisplay: 880, bytesLoaded: 4000),
      const PlaybackDiagnostics(droppedByDisplay: 20, bytesLoaded: 700),
    ]);
    collector.start(session);
    await collector.sampleNow();
    final stats = await collector.finish();

    expect(stats.droppedFrames, 900);
  });

  test('ne rend aucune moyenne quand rien n’a été mesuré', () async {
    final collector = PlaybackStatsCollector();
    final session = _FakeSession([const PlaybackDiagnostics()]);
    collector.start(session);
    final stats = await collector.finish();

    expect(stats.averageFps, isNull);
    expect(stats.averageBitrateBps, isNull);
    expect(stats.droppedFrames, isNull);
  });

  test('compte les mises en tampon sans compter deux fois la même', () {
    final collector = PlaybackStatsCollector();
    collector.noteBuffering(true);
    collector.noteBuffering(true);
    collector.noteBuffering(false);
    collector.noteBuffering(true);

    expect(collector.summary.bufferingEvents, 2);
  });

  test('un résumé sans échantillon se dit vide', () {
    expect(PlaybackStatsCollector().summary.isEmpty, isTrue);
  });

  test('la proportion d’images perdues tient compte des deux compteurs', () {
    const stats = PlaybackStatsSummary(
      sampledSeconds: 60,
      sampleCount: 12,
      droppedFrames: 10,
      renderedFrames: 990,
    );
    expect(stats.dropRatio, 0.01);
  });
}
