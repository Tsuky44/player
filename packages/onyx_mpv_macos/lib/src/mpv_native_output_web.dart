/// Version web de `MpvNativeOutput` : un navigateur n'a ni libmpv ni FFI.
///
/// Jamais construite — la vue native n'est active que sur macOS. Elle existe
/// pour que le code partagé avec le web compile.
final class MpvNativeOutput {
  MpvNativeOutput({required this.libmpvPath, required this.mpvHandle});

  final String libmpvPath;
  final int mpvHandle;

  Future<void> attach(int viewHandle) => _unsupported();

  Future<void> detach(int viewHandle) => _unsupported();

  Future<void> setProperty(String name, String value) => _unsupported();

  static Future<void> _unsupported() =>
      Future.error(UnsupportedError('libmpv est indisponible sur le web'));
}
