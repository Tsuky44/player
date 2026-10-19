part of '../api_client.dart';

/// Le message de l'administrateur à tous les comptes (ADR-0069).
mixin _AnnouncementEndpoints {
  Dio get _dio;

  /// L'annonce que ce compte n'a pas encore fermée, ou null.
  ///
  /// Un serveur qui n'annonce pas `announcements` sur `/api/ping` n'a pas la
  /// route : il n'a rien à montrer, et on ne lui pose pas la question.
  Future<ServerAnnouncement?> getPendingAnnouncement() async {
    final ping = await _dio.get('/api/ping');
    final info = ServerCapabilities.tryParse(ping.data);
    if (info == null || !info.supports(ServerCapabilities.announcements)) {
      return null;
    }
    final response = await _dio.get('/api/me/announcement');
    return ServerAnnouncement.fromEnvelope(
        Map<String, dynamic>.from(response.data as Map));
  }

  Future<void> markAnnouncementSeen(int id) async {
    await _dio.post('/api/me/announcement/seen', data: {'id': id});
  }

  /// L'annonce en cours, lue ou non, pour l'éditeur (`manage_settings`).
  Future<ServerAnnouncement?> getCurrentAnnouncement() async {
    final response = await _dio.get('/api/announcement');
    return ServerAnnouncement.fromEnvelope(
        Map<String, dynamic>.from(response.data as Map));
  }

  /// Remplace l'annonce : tous les comptes la reverront, sauf son auteur.
  Future<ServerAnnouncement?> publishAnnouncement({
    required String title,
    required String message,
  }) async {
    final response = await _dio.put('/api/announcement',
        data: {'title': title, 'message': message});
    return ServerAnnouncement.fromEnvelope(
        Map<String, dynamic>.from(response.data as Map));
  }

  Future<void> clearAnnouncement() async {
    await _dio.delete('/api/announcement');
  }
}
