import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/library_provider.dart';
import 'package:onyx/screens/settings/widgets/libraries_group.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_doubles.dart';

/// Les bibliothèques sont celles que le serveur liste, sous le nom que leur
/// administrateur a choisi (ADR-0058). L'app n'en suppose aucune.

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// Un serveur réduit à ce que l'app demande pour ses bibliothèques. [requests]
/// garde, dans l'ordre, ce qui lui a été demandé.
ApiClient _server(
  List<String> requests, {
  required List<String> capabilities,
  Object libraries = const <Object>[],
}) {
  final dio = Dio()
    ..httpClientAdapter = Adapter((options) {
      requests.add('${options.method} ${options.uri.path}'
          '${options.uri.hasQuery ? '?${options.uri.query}' : ''}');
      return switch (options.uri.path) {
        '/api/ping' => _json({'status': 'ok', 'capabilities': capabilities}),
        '/api/libraries' => _json(libraries),
        _ => _json(const <Object>[]),
      };
    });
  return ApiClient(httpClient: dio);
}

class _Api extends ApiClient {
  List<MediaLibrary> listed = const [];
  final List<String> calls = [];
  Exception? failure;

  @override
  Future<List<MediaLibrary>> getLibraries() async => listed;

  @override
  Future<MediaLibrary> createLibrary({
    required String name,
    required LibraryKind kind,
    required String path,
  }) async {
    final error = failure;
    if (error != null) throw error;
    calls.add('create $name ${kind.wire} $path');
    final created = MediaLibrary(
        id: listed.length + 1, name: name, kind: kind, path: path);
    listed = [...listed, created];
    return created;
  }

  @override
  Future<MediaLibrary> updateLibrary(
    int id, {
    required String name,
    required String path,
  }) async {
    calls.add('update $id $name $path');
    listed = [
      for (final library in listed)
        if (library.id == id)
          MediaLibrary(id: id, name: name, kind: library.kind, path: path)
        else
          library,
    ];
    return listed.firstWhere((library) => library.id == id);
  }

  @override
  Future<void> deleteLibrary(int id) async {
    calls.add('delete $id');
    listed = [
      for (final library in listed)
        if (library.id != id) library,
    ];
  }

  @override
  Future<List<HomeMediaItem>> getMovies() async => [];

  @override
  Future<List<Media>> getShows() async => [];
}

Future<LibraryProvider> _pumpGroup(WidgetTester tester, _Api api) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final provider = LibraryProvider(api);
  addTearDown(provider.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<LibraryProvider>.value(
    value: provider,
    child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: LibrariesGroup())),
    ),
  ));
  await tester.pumpAndSettle();
  return provider;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('contrat : une bibliothèque telle que le serveur l’écrit', () {
    final listed = jsonDecode(
        File('../contract/libraries.json').readAsStringSync()) as List<dynamic>;
    final library =
        MediaLibrary.fromJson(listed.single as Map<String, dynamic>);

    expect(library.id, greaterThan(0));
    expect(library.name, 'name-value');
    expect(library.kind, LibraryKind.shows);
    expect(library.path, 'path-value');
    expect(library.isLegacy, isFalse);
  });

  test('un compte sans droit d’administration ne reçoit pas le dossier', () {
    final library =
        MediaLibrary.fromJson({'id': 3, 'name': 'Animés', 'kind': 'shows'});
    expect(library.path, isNull);
  });

  test('les trois types de bibliothèque, et un type inconnu', () {
    LibraryKind kind(String wire) =>
        MediaLibrary.fromJson({'id': 1, 'name': 'x', 'kind': wire}).kind;
    expect(kind('movies'), LibraryKind.movies);
    expect(kind('shows'), LibraryKind.shows);
    expect(kind('other'), LibraryKind.other);
    // Un type ajouté par un serveur plus récent reste une grille de vidéos.
    expect(kind('music'), LibraryKind.movies);
  });

  test('les bibliothèques sont lues sur le serveur, et chacune a sa liste',
      () async {
    final requests = <String>[];
    final api = _server(requests, capabilities: [
      'libraries'
    ], libraries: [
      {'id': 4, 'name': 'Vidéos de famille', 'kind': 'movies'},
      {'id': 7, 'name': 'Animés', 'kind': 'shows'},
    ]);

    final libraries = await api.getLibraries();
    expect([for (final library in libraries) library.name],
        ['Vidéos de famille', 'Animés']);

    await api.getLibraryMovies(libraries[0]);
    await api.getLibraryShows(libraries[1]);
    expect(requests, [
      'GET /api/ping',
      'GET /api/libraries',
      'GET /api/movies?library=4',
      'GET /api/shows?library=7',
    ]);

    // La capacité annoncée ne se redemande pas à chaque rechargement.
    await api.getLibraries();
    expect(requests.where((request) => request == 'GET /api/ping'),
        hasLength(1));
  });

  // Plusieurs serveurs de versions différentes coexistent (ADR-0013) : celui
  // qui ne liste pas ses bibliothèques garde ses deux listes entières.
  test('un serveur plus ancien garde ses films et ses séries', () async {
    final requests = <String>[];
    final api = _server(requests, capabilities: ['media_language']);

    final libraries = await api.getLibraries();
    expect(libraries, MediaLibrary.legacy);
    expect(libraries.every((library) => library.isLegacy), isTrue);

    await api.getLibraryMovies(libraries[0]);
    await api.getLibraryShows(libraries[1]);
    expect(requests, [
      'GET /api/ping',
      'GET /api/movies',
      'GET /api/shows',
    ]);
  });

  test('une liste qui n’arrive pas laisse les onglets en place', () async {
    final api = _Api()
      ..listed = const [
        MediaLibrary(id: 1, name: 'Films', kind: LibraryKind.movies),
      ];
    final provider = LibraryProvider(api);
    expect(provider.librariesLoaded, isFalse);
    await provider.loadLibraries();
    expect(provider.libraries.single.name, 'Films');
    expect(provider.firstLibraryOf(LibraryKind.movies)?.id, 1);
    expect(provider.firstLibraryOf(LibraryKind.shows), isNull);

    final failing = _FailingApi();
    final offline = LibraryProvider(failing);
    await offline.loadLibraries();
    expect(offline.librariesLoaded, isTrue);
    expect(offline.libraries, isEmpty);
    provider.dispose();
    offline.dispose();
  });

  testWidgets('ajouter une bibliothèque : un nom libre, un dossier, un type',
      (tester) async {
    final api = _Api();
    final provider = await _pumpGroup(tester, api);
    expect(find.textContaining('Aucune bibliothèque'), findsOneWidget);

    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Vidéos de famille');
    await tester.enterText(find.byType(TextField).at(1), '/media/famille');
    // Ni films ni séries : le troisième type, sans recherche de fiche.
    await tester.tap(find.text('Autre'));
    await tester.pump();
    expect(find.textContaining('garde le nom de son fichier'), findsOneWidget);
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(api.calls, ['create Vidéos de famille other /media/famille']);
    expect(provider.libraries.single.name, 'Vidéos de famille');
    expect(find.text('Vidéos de famille'), findsOneWidget);
    expect(find.text('/media/famille'), findsOneWidget);
  });

  testWidgets('le refus du serveur reste sous le formulaire, la saisie aussi',
      (tester) async {
    final api = _Api()
      ..failure = DioException(
        requestOptions: RequestOptions(path: '/api/libraries'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/libraries'),
          statusCode: 400,
          data: {'error': 'Ce dossier n\'existe pas sur le serveur'},
        ),
      );
    await _pumpGroup(tester, api);

    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Concerts');
    await tester.enterText(find.byType(TextField).at(1), '/media/absent');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(find.text('Ce dossier n\'existe pas sur le serveur'), findsOneWidget);
    expect(find.text('/media/absent'), findsOneWidget);
    expect(find.text('Nouvelle bibliothèque'), findsOneWidget);
  });

  testWidgets('renommer et supprimer une bibliothèque', (tester) async {
    final api = _Api()
      ..listed = const [
        MediaLibrary(
            id: 1, name: 'Films', kind: LibraryKind.movies, path: '/media/f'),
        MediaLibrary(
            id: 2, name: 'Séries', kind: LibraryKind.shows, path: '/media/s'),
      ];
    final provider = await _pumpGroup(tester, api);

    await tester.tap(find.text('Films'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Cinéma du dimanche');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(api.calls, ['update 1 Cinéma du dimanche /media/f']);
    expect(find.text('Cinéma du dimanche'), findsOneWidget);

    await tester.tap(find.byTooltip('Supprimer « Séries »'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Les fichiers restent sur le disque'),
        findsOneWidget);
    await tester.tap(find.text('Supprimer'));
    await tester.pumpAndSettle();

    expect(api.calls.last, 'delete 2');
    expect([for (final library in provider.libraries) library.name],
        ['Cinéma du dimanche']);
  });

  testWidgets('un serveur plus ancien ne propose pas d’en ajouter',
      (tester) async {
    final api = _Api()..listed = MediaLibrary.legacy;
    await _pumpGroup(tester, api);

    expect(find.text('Ajouter'), findsNothing);
    expect(find.textContaining('trop ancien'), findsOneWidget);
  });
}

class _FailingApi extends ApiClient {
  @override
  Future<List<MediaLibrary>> getLibraries() async =>
      throw Exception('hors ligne');
}
