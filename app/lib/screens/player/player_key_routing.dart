import 'package:flutter/services.dart';

import '../../tv/tv_focus.dart';
import 'player_shortcuts.dart';

/// Ce qu'une touche demande au lecteur.
///
/// La décision est séparée de son exécution pour se lire d'un bloc, et se
/// tester sans monter l'écran : un clavier d'ordinateur et une télécommande
/// partagent les mêmes touches, et ne leur font pas faire la même chose.
sealed class PlayerKeyAction {
  const PlayerKeyAction();
}

/// La touche n'est pas pour le lecteur : elle continue son chemin (un bouton
/// sous le focus répond lui-même à OK, par exemple).
final class PlayerKeyIgnored extends PlayerKeyAction {
  const PlayerKeyIgnored();
}

/// La touche est prise, et il n'y a rien à faire.
final class PlayerKeyConsumed extends PlayerKeyAction {
  const PlayerKeyConsumed();
}

final class PlayerKeySkipIntro extends PlayerKeyAction {
  const PlayerKeySkipIntro();
}

/// Le chrome monte, la télécommande posée sur lecture/pause.
final class PlayerKeyEnterControlBar extends PlayerKeyAction {
  const PlayerKeyEnterControlBar();
}

final class PlayerKeyTogglePlayback extends PlayerKeyAction {
  const PlayerKeyTogglePlayback();
}

final class PlayerKeyShortcut extends PlayerKeyAction {
  const PlayerKeyShortcut(this.match);
  final PlayerShortcutMatch match;
}

/// Un pas de recherche à la télécommande, le chrome posé sur la barre.
final class PlayerKeyRemoteSeek extends PlayerKeyAction {
  const PlayerKeyRemoteSeek(this.direction);
  final int direction;
}

final class PlayerKeySeek extends PlayerKeyAction {
  const PlayerKeySeek(this.seconds);
  final int seconds;
}

final class PlayerKeyVolume extends PlayerKeyAction {
  const PlayerKeyVolume(this.delta);
  final double delta;
}

/// Retour : le plus intérieur d'abord (menu, panneau, barre de contrôle).
final class PlayerKeyBack extends PlayerKeyAction {
  const PlayerKeyBack();
}

const double _volumeStep = 5.0;

/// Ce que [event] demande au lecteur.
///
/// [browsingControls] : la télécommande parcourt les boutons du chrome au lieu
/// de piloter la lecture. [chromeVisible] et [skipIntroShown] décident de ce
/// que fait OK sur un téléviseur.
PlayerKeyAction routePlayerKey(
  KeyEvent event, {
  required bool isTv,
  required bool browsingControls,
  required bool chromeVisible,
  required bool skipIntroShown,
}) {
  final key = event.logicalKey;

  // OK / D-pad centre / controller A. Space keeps its own branch below,
  // because a keyboard user expects it to be play-pause and nothing else.
  if (key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    if (event is KeyRepeatEvent) return const PlayerKeyConsumed();
    // A focused button answers for itself — the app-wide shortcut turns this
    // very key into its activation.
    if (browsingControls) return const PlayerKeyIgnored();
    // Chrome caché et « Passer l'intro » seul à l'écran : OK le presse,
    // au lieu de réveiller un chrome dont personne n'a besoin. Chrome
    // visible, c'est lui qui répond (le bouton y est atteignable).
    if (isTv && !chromeVisible && skipIntroShown) {
      return const PlayerKeySkipIntro();
    }
    // On a television OK never toggles playback from here: it
    // wakes the HUD with the remote on play/pause, so the next OK pauses.
    // Reaching this branch with the HUD already up means the focus slipped,
    // and putting it back is the repair.
    return isTv
        ? const PlayerKeyEnterControlBar()
        : const PlayerKeyTogglePlayback();
  }

  if (key == LogicalKeyboardKey.space) {
    if (event is KeyRepeatEvent) return const PlayerKeyConsumed();
    return const PlayerKeyTogglePlayback();
  }

  // Les lettres et les chiffres d'un clavier d'ordinateur (voir
  // [matchPlayerShortcut]). Pas sur un téléviseur : une télécommande n'en a
  // pas, et ses touches de couleur ne doivent rien déclencher par surprise.
  if (!isTv) {
    final shortcut = matchPlayerShortcut(event);
    if (shortcut != null) return PlayerKeyShortcut(shortcut);
  }

  // While the remote is on the control bar the arrows belong to focus
  // traversal, or the buttons would be unreachable.
  final isArrow = key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown;

  if (!browsingControls && isArrow) {
    // Left and right seek at once — the press is not spent
    // waking the HUD — and the HUD comes up on the scrubber, showing where
    // the seek is going, so the next press goes on from there. Up and down
    // only bring the HUD up, on play/pause. Volume is untouched: the set owns
    // it and its remote has the keys for it.
    if (isTv) {
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        return PlayerKeyRemoteSeek(
            key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      }
      // Held down, the wake-up press must not queue forty more of itself.
      if (event is KeyRepeatEvent) return const PlayerKeyConsumed();
      return const PlayerKeyEnterControlBar();
    }

    if (key == LogicalKeyboardKey.arrowLeft) return const PlayerKeySeek(-10);
    if (key == LogicalKeyboardKey.arrowRight) return const PlayerKeySeek(10);
    return PlayerKeyVolume(
      key == LogicalKeyboardKey.arrowUp ? _volumeStep : -_volumeStep,
    );
  }

  if (kTvBackKeys.contains(key)) return const PlayerKeyBack();

  return const PlayerKeyIgnored();
}
