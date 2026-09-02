import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/playback_session.dart';
import 'package:onyx/screens/player/widgets/emby/emby_settings_menu.dart';
import 'package:onyx/tv/tv_focus.dart';
import 'package:onyx/tv/tv_mode.dart';

/// Le défaut que ce fichier verrouille : sur un téléviseur, le menu de réglages
/// du chrome Emby s'ouvrait, la télécommande y déplaçait bien le focus — mais
/// rien à l'écran ne le montrait. L'`InkWell` de chaque ligne faisait peindre
/// son halo par le [Material] du menu, c'est-à-dire *sous* le fond opaque du
/// panneau. Impossible, dès lors, de savoir où l'on est, donc impossible de
/// changer de langue : le menu passait pour bloqué.
void main() {
  setUp(() => TvMode.enabled.value = true);
  tearDown(() => TvMode.enabled.value = false);

  testWidgets('la ligne où se trouve la télécommande se voit', (tester) async {
    await _pumpMenu(tester);

    // Une seule, et c'est bien celle qui détient le focus : deux lignes
    // allumées, ou zéro, et l'écran ment sur ce que fera la touche OK.
    expect(_highlighted(tester), 'Audio');
  });

  testWidgets('les flèches parcourent le menu', (tester) async {
    await _pumpMenu(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_highlighted(tester), 'Sous-titres');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_highlighted(tester), 'Audio');
  });

  testWidgets('OK ouvre la section et la télécommande arrive sur la piste en '
      'cours', (tester) async {
    await _pumpMenu(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    // Pas la première ligne de la liste : celle qui est déjà jouée. C'est de
    // là que l'utilisateur compte se déplacer.
    expect(_highlighted(tester), 'English');
  });

  testWidgets('retour remonte à l’index, sur la ligne d’où l’on vient',
      (tester) async {
    await _pumpMenu(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    // Gauche : le menu est une colonne, la touche n'y a rien d'autre à faire
    // et c'est le geste que le chevron du bandeau annonce.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(find.text('Vitesse de lecture'), findsOneWidget);
    expect(_highlighted(tester), 'Audio');
  });

  testWidgets('OK sur une piste la choisit', (tester) async {
    final session = _FakeSession();
    await _pumpMenu(tester, session: session);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(session.chosen?.title, 'Français');
  });
}

/// Le remplissage que [_EmbyMenuTile] pose sur la ligne focalisée.
final Color _focusFill = Colors.white.withValues(alpha: 0.14);

/// Le libellé de la ligne mise en évidence à l'écran — pas celle qui détient le
/// focus : ce qui est en cause ici est ce que l'utilisateur voit.
String _highlighted(WidgetTester tester) {
  final fill = find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).color == _focusFill,
  );
  expect(fill, findsOneWidget);
  return tester
      .widget<Text>(find.descendant(of: fill, matching: find.byType(Text)).first)
      .data!;
}

/// Monte le menu comme le lecteur le fait : dans un scope de popup où la
/// télécommande est poussée, et sous les raccourcis de l'app.
Future<void> _pumpMenu(WidgetTester tester, {_FakeSession? session}) async {
  final scope = FocusScopeNode(debugLabel: 'popup');
  addTearDown(scope.dispose);

  // Ce que fait `_insertPlayerPopup` : le popup n'est pas une route, donc rien
  // n'y amène le focus tout seul, et il pousse la télécommande sur la première
  // ligne venue. Posé *avant* la frame, comme dans le lecteur — le menu, lui,
  // s'inscrit pendant sa construction, donc après. L'ordre est ce qui donne le
  // dernier mot au menu, qui seul sait quelle ligne compte.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    scope.requestFocus();
    scope.nextFocus();
  });

  await tester.pumpWidget(
    MaterialApp(
      shortcuts: <ShortcutActivator, Intent>{
        ...WidgetsApp.defaultShortcuts,
        ...tvSelectShortcuts,
      },
      home: TvScope(
        isTv: true,
        child: Scaffold(
          body: MediaQuery(
            // La police de test est à chasse fixe et bien plus large que la
            // vraie : sans ça les libellés débordent des 292 px du panneau.
            data: const MediaQueryData(textScaler: TextScaler.linear(0.4)),
            child: FocusScope(
              node: scope,
              child: EmbySettingsMenu(
                session: session ?? _FakeSession(),
                currentFit: BoxFit.contain,
                onFitChanged: (_) {},
                playbackRate: 1.0,
                playbackRates: const [0.5, 1.0, 1.5, 2.0],
                onRateChanged: (_) {},
                onClose: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.pumpAndSettle();
}

class _FakeSession implements PlaybackSession {
  PlaybackTrack? chosen;

  @override
  List<PlaybackTrack> get audioTracks => const [
        PlaybackTrack(id: '1', title: 'Français', language: 'fra'),
        PlaybackTrack(id: '2', title: 'English', language: 'eng'),
      ];

  @override
  List<PlaybackTrack> get subtitleTracks => const [
        PlaybackTrack(id: 'no'),
        PlaybackTrack(id: '3', title: 'Français', language: 'fra'),
      ];

  /// Pas la première de la liste : c'est ce qui permet de distinguer « la piste
  /// en cours » de « la première ligne venue ».
  @override
  PlaybackTrack? get currentAudioTrack => audioTracks[1];

  @override
  PlaybackTrack? get currentSubtitleTrack => subtitleTracks.first;

  @override
  Future<void> setAudioTrack(PlaybackTrack track) async => chosen = track;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
