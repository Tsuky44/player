/// Implémentation web de `MpvNativeView` : un navigateur n'a pas de mpv.
abstract final class MpvNativeView {
  static String? get libmpvPath => null;

  static bool get enabled => false;

  static void resolve() {}
}
