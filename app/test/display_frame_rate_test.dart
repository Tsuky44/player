import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/display_frame_rate.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('matching is on when nothing was ever chosen', () async {
    SharedPreferences.setMockInitialValues({});
    await DisplayFrameRate.initialize();
    // The default is the feature: removing 3:2 judder is the whole point, and
    // the toggle exists for the sets that come back badly from a mode switch.
    expect(DisplayFrameRate.enabled, isTrue);
  });

  test('the choice survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    await DisplayFrameRate.initialize();

    await DisplayFrameRate.setEnabled(false);
    expect(DisplayFrameRate.enabled, isFalse);

    // A fresh read of what was stored, as a cold start would do.
    await DisplayFrameRate.setEnabled(true);
    SharedPreferences.setMockInitialValues(
      {'display_frame_rate_matching': false},
    );
    await DisplayFrameRate.initialize();
    expect(DisplayFrameRate.enabled, isFalse);
  });

  test('a disabled matcher asks the panel for nothing', () async {
    SharedPreferences.setMockInitialValues(
      {'display_frame_rate_matching': false},
    );
    await DisplayFrameRate.initialize();

    // No method channel is mocked here: reaching the platform at all would
    // throw, so a null answer is the proof it never tried.
    expect(await DisplayFrameRate.matchTo(23.976), isNull);
    expect(DisplayFrameRate.requested, isNull);
  });
}
