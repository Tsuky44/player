/// Web stub for the in-place updater — see `app_updater.dart`.
library;

///
/// A browser always loads whatever the server currently serves, so there is no
/// installed copy to replace: [AppUpdater.supports] is false everywhere and the
/// header offers a plain download instead.

class UpdateException implements Exception {
  final String message;

  UpdateException(this.message);

  @override
  String toString() => message;
}

class PreparedUpdate {
  const PreparedUpdate._();

  Future<void> discard() async {}
}

abstract final class AppUpdater {
  static bool supports(String platform) => false;

  static Future<String> createWorkDir() => _unsupported();

  static void discardWorkDir(String path) {}

  static Future<PreparedUpdate> prepare({
    required String archivePath,
    required String workDir,
  }) =>
      _unsupported();

  static Future<void> applyAndRestart(PreparedUpdate update) => _unsupported();

  static Future<Never> _unsupported() {
    throw UpdateException(
      'La mise à jour automatique n’existe pas dans le navigateur.',
    );
  }
}
