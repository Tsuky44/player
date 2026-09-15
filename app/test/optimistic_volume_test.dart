import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/widgets/global/optimistic_volume.dart';

void main() {
  test('shows the engine value when the user has not touched it', () {
    expect(OptimisticVolume().resolve(40), 40);
  });

  test('shows what the user picked while the engine still reports the old value',
      () {
    final v = OptimisticVolume()..resolve(40);
    v.request(80);
    expect(v.resolve(40), 80);
    expect(v.resolve(40), 80);
  });

  test('hands back to the engine once it agrees', () {
    final v = OptimisticVolume()..resolve(40);
    v.request(80);
    expect(v.resolve(80), 80);
    // The engine is in charge again: a later change elsewhere shows at once.
    expect(v.resolve(30), 30);
  });

  test('keeps the user value when the engine lags with an intermediate value',
      () {
    final v = OptimisticVolume()..resolve(40);
    v.request(80);
    expect(v.resolve(55), 80);
  });
}
