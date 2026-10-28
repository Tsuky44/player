import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/tv/tv_focus.dart';
import 'package:onyx/tv/tv_focus_caption.dart';
import 'package:onyx/tv/tv_mode.dart';
import 'package:onyx/utils/hero_slides.dart';
import 'package:onyx/widgets/global/episode_tile.dart';
import 'package:onyx/widgets/global/hero_carousel.dart';
import 'package:provider/provider.dart';

/// Le parcours à la télécommande des écrans corrigés sur l'émulateur Android
/// TV : un appui, un pas, et le focus toujours là où on le voit.
void main() {
  setUp(() => TvMode.enabled.value = true);
  tearDown(() => TvMode.enabled.value = false);

  Future<void> pumpTv(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient();
    final auth = AuthProvider(api);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(
          home: TvScope(isTv: true, child: Scaffold(body: child)),
        ),
      ),
    );
    await tester.pump();
  }

  /// Le premier élément focalisable de l'écran, dans l'ordre de lecture.
  Future<void> focusFirst(WidgetTester tester) async {
    final nodes = FocusManager.instance.rootScope.traversalDescendants
        .where((node) => node is! FocusScopeNode)
        .where((node) => node.context != null && !node.rect.isEmpty)
        .toList()
      ..sort((a, b) {
        final byTop = a.rect.top.compareTo(b.rect.top);
        return byTop != 0 ? byTop : a.rect.left.compareTo(b.rect.left);
      });
    nodes.first.requestFocus();
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  /// L'épisode qui tient le focus, par son numéro, et si c'est la ligne elle-
  /// même ou l'une de ses icônes.
  ({int number, bool onRow}) focusedEpisode() {
    final focused = FocusManager.instance.primaryFocus!;
    final tile = focused.context!.findAncestorWidgetOfExactType<EpisodeTile>()!;
    return (
      number: tile.episodeNumber,
      onRow: focused.debugLabel == 'episode-row',
    );
  }

  group('liste des épisodes', () {
    HomeMediaItem episode(int id) => HomeMediaItem(
          media: Media(
            id: id,
            type: MediaType.episode,
            title: 'Épisode $id',
            duration: 2400,
            createdAt: DateTime(2026),
          ),
          currentPositionSeconds: 0,
          isFinished: false,
          duration: 2400,
        );

    Widget episodes() => Column(
          children: [
            for (var n = 1; n <= 3; n++)
              EpisodeTile(
                episode: episode(n),
                episodeNumber: n,
                allowDownload: false,
                onTap: () {},
                onToggleWatched: (_) async {},
              ),
          ],
        );

    testWidgets(
        'bas passe d’une ligne à la suivante, sans arrêt sur ses icônes',
        (tester) async {
      await pumpTv(tester, episodes());
      await focusFirst(tester);
      expect(focusedEpisode(), (number: 1, onRow: true));

      // La panne : Bas tombait d'abord sur une icône de la ligne suivante,
      // puis sur la ligne — deux appuis par épisode.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedEpisode(), (number: 2, onRow: true));
    });

    testWidgets('droite entre dans les icônes, gauche en ressort',
        (tester) async {
      await pumpTv(tester, episodes());
      await focusFirst(tester);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedEpisode(), (number: 1, onRow: false));

      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusedEpisode(), (number: 1, onRow: true));
    });

    testWidgets('bas depuis une icône mène à l’épisode suivant',
        (tester) async {
      await pumpTv(tester, episodes());
      await focusFirst(tester);
      await press(tester, LogicalKeyboardKey.arrowRight);

      // Le parcours partait du haut de la ligne et retombait sur elle.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedEpisode(), (number: 2, onRow: true));
    });
  });

  group('bandeau de l’accueil', () {
    List<HeroSlide> slides() => [
          for (var i = 1; i <= 3; i++)
            HeroSlide(
              // Négatifs : aucune fiche TMDB à aller chercher.
              media: Media(
                id: -i,
                type: MediaType.movie,
                title: 'Film $i',
                duration: 6000,
                createdAt: DateTime(2026),
              ),
              title: 'Film $i',
            ),
        ];

    /// Le focus est sur un bouton de la diapositive affichée, pas sur une
    /// voisine construite hors écran.
    bool focusOnShownSlide() {
      final banner = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<ExcludeFocus>();
      return banner != null && !banner.excluding;
    }

    testWidgets('seule la diapositive affichée se parcourt', (tester) async {
      await pumpTv(
        tester,
        HeroCarousel(slides: slides(), onPlay: (_) {}, onInfo: (_) {}),
      );
      final focusable = FocusManager.instance.rootScope.traversalDescendants
          .where((node) => node.context != null)
          .where((node) =>
              node.context!.findAncestorWidgetOfExactType<ElevatedButton>() !=
              null);
      // Lecture de la première, pas celles construites hors écran.
      expect(focusable, hasLength(1));
    });

    testWidgets('droite au bord passe à la diapositive suivante, focus compris',
        (tester) async {
      await pumpTv(
        tester,
        HeroCarousel(slides: slides(), onPlay: (_) {}, onInfo: (_) {}),
      );
      await focusFirst(tester);
      expect(find.text('Film 1'), findsWidgets);

      // Lecture, puis Plus d'infos, puis le bord : la diapositive change.
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);

      final controller =
          tester.widget<PageView>(find.byType(PageView)).controller!;
      expect(controller.page, 1);
      // Le focus a suivi : il est sur la nouvelle page, pas perdu.
      expect(focusOnShownSlide(), isTrue);
    });
  });

  testWidgets('la légende nomme l’icône qui a le focus', (tester) async {
    await pumpTv(
      tester,
      TvFocusCaption(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Ajouter à une liste',
              onPressed: () {},
              icon: const Icon(Icons.bookmark),
            ),
            IconButton(
              tooltip: 'Partager',
              onPressed: () {},
              icon: const Icon(Icons.share),
            ),
          ],
        ),
      ),
    );
    await focusFirst(tester);
    expect(find.text('Ajouter à une liste'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Partager'), findsOneWidget);
  });

  test('hors Android, Retour au clavier ou à la manette reste une touche', () {
    // Les tests tournent hors Android : toutes les touches Retour y sont à
    // traiter par le widget. Sur Android, `goBack` est laissé au système.
    expect(isSelfHandledBackKey(LogicalKeyboardKey.escape), isTrue);
    expect(isSelfHandledBackKey(LogicalKeyboardKey.gameButtonB), isTrue);
    expect(isSelfHandledBackKey(LogicalKeyboardKey.arrowLeft), isFalse);
  });
}
