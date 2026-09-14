import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/library/movie_detail_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:onyx/services/media_details_cache.dart';
import 'package:onyx/widgets/global/media_download_button.dart';

class _Api extends ApiClient {
  final tracksRequested = <int>[];
  @override
  Future<MediaDetails> getMediaDetails(int mediaId) async =>
      MediaDetails.fromJson({
        'id': mediaId,
        'type': 'movie',
        'title': 'Film',
        'versions': [
          {
            'id': 2,
            'type': 'movie',
            'title': 'Film',
            'duration': 7200,
            'label': '4K',
            'intro_end': 12
          },
          {
            'id': 1,
            'type': 'movie',
            'title': 'Film',
            'duration': 7100,
            'label': '1080p',
            'intro_end': 15
          },
        ],
      });
  @override
  Future<MediaTracks> getMediaTracks(int mediaId) async {
    tracksRequested.add(mediaId);
    return MediaTracks.fromJson({});
  }

  @override
  Future<Map<String, dynamic>> getProgress(int mediaId) async =>
      {'current_position_seconds': 0, 'is_finished': false};
}

void main() {
  testWidgets('best version is selected and changing it updates playback',
      (tester) async {
    MediaDetailsCache.clear();
    final api = _Api();
    final auth = AuthProvider(api);
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      auth.dispose();
      MediaDetailsCache.clear();
    });
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<DownloadManager>.value(
            value: DownloadManager.instance),
      ],
      child: MaterialApp(
          home: MovieDetailScreen(
              movie: Media(
        id: 1,
        type: MediaType.movie,
        title: 'Film',
        duration: 7100,
        createdAt: DateTime(2026),
      ))),
    ));
    await tester.pumpAndSettle();
    HomeMediaItem selected() => tester
        .widget<MediaDownloadButton>(find.byType(MediaDownloadButton))
        .item;
    expect(selected().media.id, 2);
    expect(selected().introEnd, 12);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1080p').last);
    await tester.pumpAndSettle();
    expect(selected().media.id, 1);
    expect(selected().duration, 7100);
    expect(selected().introEnd, 15);
    expect(api.tracksRequested.last, 1);
    expect(tester.takeException(), isNull);
  });
}
