import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/chrome_auto_hide.dart';

void main() {
  test('le chrome reste affiché tant qu\'un menu est ouvert', () {
    expect(
      chromeMayAutoHide(
          isPlaying: true, isDraggingSlider: false, menuOpen: true),
      isFalse,
    );
  });

  test('le chrome reste affiché sur un film en pause', () {
    expect(
      chromeMayAutoHide(
          isPlaying: false, isDraggingSlider: false, menuOpen: false),
      isFalse,
    );
  });

  test('le chrome reste affiché pendant un glissé de la barre', () {
    expect(
      chromeMayAutoHide(
          isPlaying: true, isDraggingSlider: true, menuOpen: false),
      isFalse,
    );
  });

  test('le chrome s\'efface sur un film en lecture sans menu', () {
    expect(
      chromeMayAutoHide(
          isPlaying: true, isDraggingSlider: false, menuOpen: false),
      isTrue,
    );
  });
}
