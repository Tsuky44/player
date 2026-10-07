import 'package:flutter/widgets.dart';

/// Le jeu d'icônes de l'interface de navigation : coquille, accueil,
/// catalogues, fiches, demandes, téléchargements et cartes.
///
/// Phosphor au trait régulier, et non Material : le clap, le téléviseur et le
/// « + » cerclé de Material étaient ce qui signait le plus « app Android » une
/// fois la palette et la typographie réglées (design-plans/audit-premium.md).
/// Un jeu se lit à sa cohérence : un trait unique, des terminaisons rondes, et
/// la variante pleine réservée à deux sens — l'onglet actif, et ce qui se lance
/// (lecture, note, vu).
///
/// Les écrans de navigation ne lisent que cette classe, ce que
/// `test/app_icons_guard_test.dart` vérifie. Le lecteur et les réglages gardent
/// Material pour l'instant : le lecteur a son propre chrome, et les réglages
/// sont un chantier à part.
abstract final class AppIcons {
  // Les deux polices embarquées (`pubspec.yaml`). Les glyphes portent le même
  // point de code dans l'une et l'autre ; le nom Phosphor suit chaque entrée,
  // pour retrouver l'icône sur phosphoricons.com.
  static const String _regular = 'PhosphorRegular';
  static const String _fill = 'PhosphorFill';

  // Onglets : creux au repos, pleins quand ils sont actifs.
  static const IconData home = IconData(0xe2c2, fontFamily: _regular); // house
  static const IconData homeSelected =
      IconData(0xe2c2, fontFamily: _fill); // house
  static const IconData movie =
      IconData(0xe792, fontFamily: _regular); // filmStrip
  static const IconData movieSelected =
      IconData(0xe792, fontFamily: _fill); // filmStrip
  static const IconData series =
      IconData(0xeae6, fontFamily: _regular); // televisionSimple
  static const IconData seriesSelected =
      IconData(0xeae6, fontFamily: _fill); // televisionSimple
  static const IconData request =
      IconData(0xe3d6, fontFamily: _regular); // plusCircle
  static const IconData requestSelected =
      IconData(0xe3d6, fontFamily: _fill); // plusCircle
  static const IconData offline =
      IconData(0xe20c, fontFamily: _regular); // downloadSimple
  static const IconData offlineSelected =
      IconData(0xe20c, fontFamily: _fill); // downloadSimple

  // Lecture : toujours pleines, c'est ce qui se lance.
  static const IconData play = IconData(0xe3d0, fontFamily: _fill); // play
  static const IconData playCircle =
      IconData(0xe3d2, fontFamily: _regular); // playCircle
  static const IconData playCircleFilled =
      IconData(0xe3d2, fontFamily: _fill); // playCircle
  static const IconData pauseCircle =
      IconData(0xe3a0, fontFamily: _regular); // pauseCircle
  static const IconData stop = IconData(0xe46c, fontFamily: _fill); // stop

  // « Vu » : creux pour l'action, plein pour l'état.
  static const IconData check = IconData(0xe182, fontFamily: _regular); // check
  static const IconData watched =
      IconData(0xe184, fontFamily: _regular); // checkCircle
  static const IconData watchedFilled =
      IconData(0xe184, fontFamily: _fill); // checkCircle
  static const IconData rating = IconData(0xe46a, fontFamily: _fill); // star

  // Navigation et chrome.
  static const IconData search =
      IconData(0xe30c, fontFamily: _regular); // magnifyingGlass
  static const IconData close = IconData(0xe4f6, fontFamily: _regular); // x
  static const IconData back =
      IconData(0xe138, fontFamily: _regular); // caretLeft
  static const IconData forward =
      IconData(0xe06c, fontFamily: _regular); // arrowRight
  static const IconData chevronRight =
      IconData(0xe13a, fontFamily: _regular); // caretRight
  static const IconData expand =
      IconData(0xe136, fontFamily: _regular); // caretDown
  static const IconData sort =
      IconData(0xe140, fontFamily: _regular); // caretUpDown
  static const IconData more =
      IconData(0xe1fe, fontFamily: _regular); // dotsThree
  static const IconData moreVertical =
      IconData(0xe208, fontFamily: _regular); // dotsThreeVertical
  static const IconData info = IconData(0xe2ce, fontFamily: _regular); // info
  static const IconData add = IconData(0xe3d4, fontFamily: _regular); // plus
  static const IconData refresh =
      IconData(0xe036, fontFamily: _regular); // arrowClockwise
  static const IconData sync =
      IconData(0xe094, fontFamily: _regular); // arrowsClockwise
  static const IconData reset =
      IconData(0xe038, fontFamily: _regular); // arrowCounterClockwise
  static const IconData autoscroll =
      IconData(0xe0a4, fontFamily: _regular); // arrowsOutCardinal

  // Téléchargements et état réseau.
  static const IconData download =
      IconData(0xe20c, fontFamily: _regular); // downloadSimple
  static const IconData downloaded =
      IconData(0xe184, fontFamily: _regular); // checkCircle
  static const IconData pending =
      IconData(0xe2b8, fontFamily: _regular); // hourglassMedium
  static const IconData cloudOff =
      IconData(0xe1b6, fontFamily: _regular); // cloudSlash
  static const IconData wifiOff =
      IconData(0xe4f2, fontFamily: _regular); // wifiSlash
  static const IconData error =
      IconData(0xe4e2, fontFamily: _regular); // warningCircle
  static const IconData delete =
      IconData(0xe4a6, fontFamily: _regular); // trash
  static const IconData clearAll =
      IconData(0xec54, fontFamily: _regular); // broom
  static const IconData update =
      IconData(0xe028, fontFamily: _regular); // arrowCircleDown

  // Fiches, personnes, métadonnées.
  static const IconData person = IconData(0xe4c2, fontFamily: _regular); // user
  static const IconData birthday =
      IconData(0xe780, fontFamily: _regular); // cake
  static const IconData place =
      IconData(0xe316, fontFamily: _regular); // mapPin
  static const IconData collection =
      IconData(0xe466, fontFamily: _regular); // stack
  static const IconData edit =
      IconData(0xebc6, fontFamily: _regular); // pencilSimpleLine
  static const IconData identify =
      IconData(0xe6b6, fontFamily: _regular); // magicWand
  static const IconData airDate =
      IconData(0xe712, fontFamily: _regular); // calendarCheck
  static const IconData subtitles =
      IconData(0xe1a8, fontFamily: _regular); // subtitles
  static const IconData imageBroken =
      IconData(0xe7a8, fontFamily: _regular); // imageBroken
  static const IconData folder =
      IconData(0xe24a, fontFamily: _regular); // folder
  static const IconData file = IconData(0xe230, fontFamily: _regular); // file
  static const IconData isNew = IconData(0xe6a2, fontFamily: _fill); // sparkle

  // Demandes et filtres.
  static const IconData filters =
      IconData(0xe434, fontFamily: _regular); // slidersHorizontal
  static const IconData filter =
      IconData(0xe268, fontFamily: _regular); // funnelSimple
  static const IconData sortOrder =
      IconData(0xe444, fontFamily: _regular); // sortAscending
  static const IconData calendar =
      IconData(0xe10a, fontFamily: _regular); // calendarBlank
  static const IconData language =
      IconData(0xe288, fontFamily: _regular); // globe
  static const IconData duration =
      IconData(0xe492, fontFamily: _regular); // timer
  static const IconData schedule =
      IconData(0xe19a, fontFamily: _regular); // clock
  static const IconData tag = IconData(0xe478, fontFamily: _regular); // tag
  static const IconData blocked =
      IconData(0xe3de, fontFamily: _regular); // prohibit

  // Compte et partage.
  static const IconData settings =
      IconData(0xe272, fontFamily: _regular); // gearSix
  static const IconData signOut =
      IconData(0xe42a, fontFamily: _regular); // signOut
  static const IconData switchServer =
      IconData(0xe0a0, fontFamily: _regular); // arrowsLeftRight
  static const IconData watchParty =
      IconData(0xe68e, fontFamily: _regular); // usersThree
  static const IconData scan = IconData(0xebb6, fontFamily: _regular); // scan
  static const IconData link = IconData(0xe2e2, fontFamily: _regular); // link
  static const IconData copy = IconData(0xe1ca, fontFamily: _regular); // copy
}
