/// Ce qu'un serveur dit de lui-même sur `GET /api/ping` : qu'il répond, quelle
/// version il est, et ce qu'il sait faire.
///
/// La médiathèque peut être servie par plusieurs serveurs de versions
/// différentes (ADR-0013) : « le serveur est à jour » ne se suppose jamais.
/// Plutôt que de deviner à partir d'une route qui répond 404, l'app lit ici
/// les capacités que le serveur annonce — voir `server/handlers/ping.go`, où
/// chacune est nommée.
class ServerCapabilities {
  const ServerCapabilities({
    this.version,
    this.playbackTicketVersion,
    this.capabilities = const {},
  });

  /// Null pour un serveur d'avant cette annonce.
  final String? version;

  /// Null pour un serveur d'avant les tickets de lecture (ADR-0038), qui sert
  /// encore ses flux sur des adresses publiques.
  final int? playbackTicketVersion;

  final Set<String> capabilities;

  static const progressLongPoll = 'progress_long_poll';
  static const mediaLanguage = 'media_language';
  static const watchedByCredits = 'watched_by_credits';

  /// Le serveur liste ses bibliothèques (ADR-0058). Sans elle, il n'a que
  /// ses films et ses séries.
  static const libraries = 'libraries';

  /// Le message de l'administrateur à tous les comptes (ADR-0069).
  static const announcements = 'announcements';

  /// Le serveur propose les affiches de TMDB et Fanart.tv pour une fiche, et
  /// enregistre celle qu'on choisit (ADR-0068).
  static const posterPicker = 'poster_picker';

  /// « À regarder plus tard » et les listes du compte, partagées ou non
  /// (ADR-0070).
  static const watchLists = 'watch_lists';

  /// Le serveur vérifie lui-même qu'il joint OnyxHub (ADR-0072).
  static const mediaHubLinkTest = 'mediahub_link_test';

  /// Le serveur relaie les demandes du compte chez OnyxHub (ADR-0073).
  static const myRequests = 'my_requests';

  /// Le serveur dit les droits du compte chez MediaHub, liste toutes les
  /// demandes et les modère (ADR-0087).
  static const mediaHubRequests = 'mediahub_requests';

  bool supports(String capability) => capabilities.contains(capability);

  /// Null quand la réponse n'est pas celle d'un serveur Onyx qui va bien.
  static ServerCapabilities? tryParse(dynamic data) {
    if (data is! Map || data['status'] != 'ok') return null;
    final capabilities = data['capabilities'];
    return ServerCapabilities(
      version: data['version'] as String?,
      playbackTicketVersion: (data['playback_ticket_version'] as num?)?.toInt(),
      capabilities: capabilities is List
          ? capabilities.whereType<String>().toSet()
          : const {},
    );
  }
}
