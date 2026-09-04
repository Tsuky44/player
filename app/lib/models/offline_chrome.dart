import 'player_layout.dart';

/// Le playeur d'un compte, figé sur le disque à côté de ses téléchargements.
///
/// Le chrome du lecteur vit sur le compte, côté serveur. Hors ligne il n'y a
/// personne pour le dire, et un média rapatrié se lisait donc avec le HUD par
/// défaut — un lecteur que l'utilisateur n'a jamais choisi.
///
/// L'instantané est rangé **par serveur**, pas par média : c'est un réglage de
/// compte, et une bibliothèque de cent épisodes n'a pas à en garder cent
/// copies. C'est aussi ce qui donne la bonne réponse quand l'app a été
/// pointée vers un autre serveur depuis : chaque téléchargement retrouve le
/// playeur du compte d'où il vient.
class OfflineChrome {
  /// Adresse du serveur d'origine, normalisée (sans barre oblique finale).
  final String serverUrl;

  /// Identifiant du playeur côté compte, pour reconnaître le même après une
  /// resynchronisation.
  final String presetId;

  /// Nom affiché du playeur, utile pour dire *lequel* est appliqué.
  final String name;

  final bool useModular;
  final PlayerLayoutConfig config;
  final DateTime savedAt;

  const OfflineChrome({
    required this.serverUrl,
    required this.presetId,
    required this.name,
    required this.useModular,
    required this.config,
    required this.savedAt,
  });

  /// Normalise une adresse de serveur pour servir de clé.
  ///
  /// `http://nas:8080/` et `http://nas:8080` désignent le même compte ; sans
  /// ça ils rangeraient deux instantanés et un téléchargement sur deux
  /// retomberait sur le HUD par défaut.
  static String normalizeServerUrl(String url) {
    var value = url.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  factory OfflineChrome.fromJson(Map<String, dynamic> json) {
    final rawConfig = json['config'];
    return OfflineChrome(
      serverUrl: json['server_url'] as String? ?? '',
      presetId: json['preset_id'] as String? ?? '',
      name: json['name'] as String? ?? 'Mon playeur',
      useModular: json['use_modular'] == true,
      config: rawConfig is Map<String, dynamic>
          ? PlayerLayoutConfig.fromJson(rawConfig)
          : PlayerLayoutConfig.standard(),
      savedAt: DateTime.tryParse(json['saved_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, dynamic> toJson() => {
        'server_url': serverUrl,
        'preset_id': presetId,
        'name': name,
        'use_modular': useModular,
        'config': config.toJson(),
        'saved_at': savedAt.toIso8601String(),
      };
}
