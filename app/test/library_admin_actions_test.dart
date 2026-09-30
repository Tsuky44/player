import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/library/movie_detail_screen.dart';
import 'package:onyx/screens/library/widgets/show_metadata_menu.dart';
import 'package:onyx/screens/player/hooks/use_player_controller.dart';
import 'package:onyx/screens/player/widgets/extract_subtitles_button.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:onyx/services/media_details_cache.dart';
import 'package:onyx/services/media_tracks_cache.dart';

/// Les routes que le serveur réserve à `manage_library` (`server/main.go`),
/// telles que l'interface les appelle.
final RegExp _libraryAdminCall = RegExp(
  r'\b(rematchMediaMetadata|redetectMediaMetadata|forceExtractSubtitles|'
  r'forceMediaSubtitleExtract|triggerLibraryScan|triggerSubtitleExtract|'
  r'triggerRedetectAllMatches|MetadataFixSheet\.show)\(',
);

/// Fichiers qui appellent ces routes sans lire le droit eux-mêmes, et pourquoi.
///
/// La liste doit rester courte : chaque entrée nomme l'endroit où le droit est
/// vérifié à sa place.
const Map<String, String> _gatedElsewhere = {
  'lib/screens/library/show_detail_screen.dart':
      'ses deux actions ne s’ouvrent que depuis ShowMetadataMenu',
  'lib/screens/settings/media_review_screen.dart':
      'atteint seulement depuis la page Bibliothèque, sous perms.manageLibrary',
  'lib/screens/player/hooks/use_player_controller.dart':
      'appelé par ExtractSubtitlesButton ; l’extraction de fond échoue en silence',
};

class _Api extends ApiClient {
  @override
  Future<MediaDetails> getMediaDetails(int mediaId) async =>
      MediaDetails.fromJson({'id': mediaId, 'type': 'movie', 'title': 'Film'});

  @override
  Future<MediaTracks> getMediaTracks(int mediaId) async =>
      MediaTracks.fromJson({});

  @override
  Future<Map<String, dynamic>> getProgress(int mediaId) async =>
      {'current_position_seconds': 0, 'is_finished': false};
}

class _FakeAuth extends AuthProvider {
  _FakeAuth(super.api, this._permissions);

  final Permissions _permissions;

  @override
  User? get currentUser =>
      User(id: 1, username: 'mathis', permissions: _permissions);

  @override
  Permissions get permissions => _permissions;
}

class _IdleController implements PlayerController {
  @override
  bool get isExtractingSubtitles => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _member = Permissions(requestMedia: true);
const _librarian = Permissions(manageLibrary: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  Future<void> pump(
    WidgetTester tester,
    Permissions permissions,
    Widget home,
  ) async {
    final api = _Api();
    final auth = _FakeAuth(api, permissions);
    addTearDown(auth.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<DownloadManager>.value(
            value: DownloadManager.instance),
      ],
      child: MaterialApp(home: Scaffold(body: home)),
    ));
    await tester.pumpAndSettle();
  }

  group('une action réservée à manage_library n’est pas montrée sans ce droit',
      () {
    Future<void> pumpMovie(WidgetTester tester, Permissions permissions) async {
      MediaDetailsCache.clear();
      MediaTracksCache.clear();
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        MediaDetailsCache.clear();
        MediaTracksCache.clear();
      });
      await pump(
        tester,
        permissions,
        MovieDetailScreen(
          movie: Media(
            id: 1,
            type: MediaType.movie,
            title: 'Film',
            duration: 7100,
            createdAt: DateTime(2026),
          ),
        ),
      );
    }

    testWidgets('fiche film : « Corriger la fiche »', (tester) async {
      await pumpMovie(tester, _member);
      expect(find.byTooltip('Corriger la fiche'), findsNothing);

      await pumpMovie(tester, _librarian);
      expect(find.byTooltip('Corriger la fiche'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fiche série : menu « Métadonnées série »', (tester) async {
      Widget menu() => ShowMetadataMenu(onRedetect: () {}, onPickOnTmdb: () {});

      await pump(tester, _member, menu());
      expect(find.byTooltip('Métadonnées série'), findsNothing);

      await pump(tester, _librarian, menu());
      expect(find.byTooltip('Métadonnées série'), findsOneWidget);
    });

    testWidgets('lecteur : « Extraire les sous-titres »', (tester) async {
      Widget button() => ExtractSubtitlesButton(controller: _IdleController());

      await pump(tester, _member, button());
      expect(find.text('Extraire les sous-titres'), findsNothing);

      await pump(tester, _librarian, button());
      expect(find.text('Extraire les sous-titres'), findsOneWidget);
    });
  });

  test('chaque appel d’une route manage_library vérifie le droit', () {
    final offenders = <String>[];

    for (final root in ['lib/screens', 'lib/widgets']) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        if (!_libraryAdminCall.hasMatch(source)) continue;
        if (source.contains('manageLibrary')) continue;
        // La liste est écrite en barres obliques ; Windows rend des barres
        // inverses.
        final path = entity.path.replaceAll('\\', '/');
        if (_gatedElsewhere.containsKey(path)) continue;
        offenders.add(path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Le serveur refuse ces routes à un compte sans manage_library '
          '(ADR-0001). Un bouton qui les appelle sans lire '
          'permissions.manageLibrary est montré à toute la famille, qui le '
          'presse et lit un refus :\n\n${offenders.join('\n')}',
    );
  });

  test('la liste d’exceptions ne contient que des fichiers existants', () {
    for (final path in _gatedElsewhere.keys) {
      expect(File(path).existsSync(), isTrue, reason: '$path n’existe plus');
    }
  });
}
