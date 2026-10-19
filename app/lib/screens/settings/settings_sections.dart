/// Les adresses des pages des paramètres, pour les ouvrir d'ailleurs : une
/// entrée du menu du compte, l'accueil vide vers la bibliothèque, le tableau de
/// bord vers l'historique.
///
/// Une adresse désigne une page, pas une entrée de la navigation : plusieurs
/// pages partagent une catégorie (voir `settings_categories.dart`), et ouvrir
/// l'une ouvre sa catégorie à cet endroit.
abstract final class SettingsSections {
  static const account = 'account';
  static const playback = 'playback';
  static const downloads = 'downloads';
  static const servers = 'servers';
  static const shares = 'shares';
  static const emby = 'emby';
  static const device = 'device';
  static const dashboard = 'dashboard';
  static const activity = 'activity';
  static const stats = 'stats';
  static const users = 'users';
  static const devices = 'devices';
  static const library = 'library';
  static const integrations = 'integrations';
  static const linkedServers = 'linked-servers';
  static const announcement = 'announcement';
}
