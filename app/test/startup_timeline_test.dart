import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/playback/startup_timeline.dart';

void main() {
  late Duration now;
  StartupTimeline timeline() => StartupTimeline(elapsed: () => now)..start();
  void at(int millis) => now = Duration(milliseconds: millis);

  setUp(() => now = Duration.zero);

  test('playing reports the total once, without closing the line', () {
    final startup = timeline();
    at(280);
    startup.mark('play');
    at(11800);
    expect(startup.notePlaying(), 11800);
    expect(startup.notePlaying(), isNull);
    at(12000);
    startup.mark('shown');
    expect(startup.close(),
        startsWith('PLAYER STARTUP: play=280ms playing=11800ms shown=12000ms'));
  });

  test('the line names the slowest step, where to look first', () {
    final startup = timeline();
    at(280);
    startup.mark('play');
    at(9380);
    startup.mark('loaded');
    at(11800);
    startup.mark('decoder');
    expect(startup.close(), contains('plus long : play→loaded +9100ms'));
  });

  test('a milestone marked twice keeps its first time', () {
    final startup = timeline();
    at(100);
    startup.mark('decoder');
    at(900);
    startup.mark('decoder');
    final line = startup.close()!;
    expect(line, contains('decoder=100ms'));
    expect(line, isNot(contains('decoder=900ms')));
  });

  test('closes once: later marks and closes are ignored', () {
    final startup = timeline();
    expect(startup.close(), isNotNull);
    startup.mark('late');
    expect(startup.close(), isNull);
    expect(startup.describe(), isNot(contains('late')));
  });

  test('an abandoned start says so and when, to show the step that never came',
      () {
    final startup = timeline();
    at(300);
    startup.mark('play');
    at(25000);
    final line = startup.close(complete: false)!;
    expect(line, startsWith('PLAYER STARTUP (inachevé): play=300ms'));
    expect(line, contains('abandonné à 25000ms'));
  });

  test('notes accumulate, since each changes what the numbers mean', () {
    final startup = timeline()
      ..note('reprise à 1520s')
      ..note('audio changée pendant le démarrage');
    expect(startup.close(),
        endsWith(' · reprise à 1520s · audio changée pendant le démarrage'));
  });
}
