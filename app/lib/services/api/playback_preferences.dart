part of '../api_client.dart';

/// Les réglages de lecture du compte, partagés par ses appareils (ADR-0043).
mixin _PlaybackPreferencesEndpoints {
  Dio get _dio;

  Future<AccountPlaybackPreferences> getPlaybackPreferences() async {
    final response = await _dio.get('/api/me/playback-preferences');
    return AccountPlaybackPreferences.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  /// Mise à jour partielle : seuls les champs de [fields] sont envoyés, avec
  /// les clés du serveur (`auto_skip_intro`, `default_audio_lang`).
  Future<AccountPlaybackPreferences> updatePlaybackPreferences(
    Map<String, Object> fields,
  ) async {
    final response =
        await _dio.put('/api/me/playback-preferences', data: fields);
    return AccountPlaybackPreferences.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }
}
