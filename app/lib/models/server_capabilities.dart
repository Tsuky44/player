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
