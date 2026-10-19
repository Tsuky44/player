/// Le message qu'un administrateur adresse à tous les comptes du serveur
/// (ADR-0069). Chaque publication a un nouvel [id] : c'est lui que l'app
/// renvoie pour dire « fermé ».
class ServerAnnouncement {
  const ServerAnnouncement({
    required this.id,
    required this.title,
    required this.message,
    this.createdAt,
  });

  final int id;

  /// Vide quand l'administrateur n'a pas donné de titre.
  final String title;
  final String message;
  final DateTime? createdAt;

  factory ServerAnnouncement.fromJson(Map<String, dynamic> json) =>
      ServerAnnouncement(
        id: (json['id'] as num).toInt(),
        title: json['title'] as String? ?? '',
        message: json['message'] as String? ?? '',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );

  /// Lit `{"announcement": {…} | null}`, la forme de toutes les routes
  /// d'annonce : null veut dire « rien à montrer ».
  static ServerAnnouncement? fromEnvelope(Map<String, dynamic> json) {
    final announcement = json['announcement'];
    if (announcement is! Map) return null;
    return ServerAnnouncement.fromJson(Map<String, dynamic>.from(announcement));
  }
}
