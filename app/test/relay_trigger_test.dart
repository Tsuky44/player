import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/playback/relay_trigger.dart';

void main() {
  late DateTime now;
  RelayTrigger trigger() => RelayTrigger(now: () => now);
  void after(int seconds) => now = now.add(Duration(seconds: seconds));

  setUp(() => now = DateTime(2026, 9, 24, 20));

  test('a playback that shows its pictures never looks for a relay', () {
    final relay = trigger();
    after(3600);
    expect(relay.inTrouble(hasFirstFrame: true), isFalse);
  });

  test('a slow start is not a dead server: an 11 s DNS wait stays local', () {
    final relay = trigger();
    after(12);
    expect(relay.inTrouble(hasFirstFrame: false), isFalse);
  });

  test('a start with no picture past the grace may look for a relay', () {
    final relay = trigger();
    after(20);
    expect(relay.inTrouble(hasFirstFrame: false), isTrue);
  });

  test('only a long stall mid-film counts, and it ends when data comes back',
      () {
    final relay = trigger();
    relay.noteBuffering(true);
    after(10);
    expect(relay.inTrouble(hasFirstFrame: true), isFalse);
    after(10);
    expect(relay.inTrouble(hasFirstFrame: true), isTrue);
    relay.noteBuffering(false);
    expect(relay.inTrouble(hasFirstFrame: true), isFalse);
  });

  test('a stall is timed from its start, not from its latest report', () {
    final relay = trigger();
    relay.noteBuffering(true);
    after(15);
    relay.noteBuffering(true);
    after(5);
    expect(relay.inTrouble(hasFirstFrame: true), isTrue);
  });
}
