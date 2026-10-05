part of '../api_client.dart';

/// La langue audio et le sous-titre choisis pour une série (ADR-0044).
///
/// Les routes prennent un épisode : c'est le serveur qui sait à quelle série
/// il appartient.
mixin _SeriesTrackPreferencesEndpoints {
  Dio get _dio;

  Future<SeriesTrackPreferences> getSeriesTrackPreferences(
    int episodeId,
  ) async {
    final response =
        await _dio.get('/api/episodes/$episodeId/track-preferences');
    return SeriesTrackPreferences.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  /// Mise à jour partielle : seuls les champs de [fields] sont envoyés, avec
  /// les clés du serveur (`audio_lang`, `subtitle`).
  Future<SeriesTrackPreferences> updateSeriesTrackPreferences(
    int episodeId,
    Map<String, Object> fields,
  ) async {
    final response = await _dio.put(
      '/api/episodes/$episodeId/track-preferences',
      data: fields,
    );
    return SeriesTrackPreferences.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }
}
