import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_colors.dart';
import 'playback/playback_session.dart';

/// Les raccourcis clavier du lecteur au-delà d'Espace et des flèches.
///
/// Ce sont ceux que tout le monde tape par réflexe après YouTube, VLC ou Plex :
/// sans eux, le clavier d'un ordinateur ne savait que mettre en pause et
/// avancer de dix secondes. `?` les affiche — ceux qui existaient déjà ne
/// l'étaient nulle part.
enum PlayerShortcut {
  playPause,
  seekBack,
  seekForward,
  toggleFullscreen,
  toggleMute,
  nextEpisode,
  seekToFraction,
  showHelp,
}

/// Un raccourci reconnu, avec la fraction visée pour les chiffres.
typedef PlayerShortcutMatch = ({PlayerShortcut shortcut, double fraction});

/// Le raccourci que [event] déclenche, ou null. Seuls les appuis comptent :
/// une touche maintenue ne rebascule pas le plein écran à chaque répétition.
PlayerShortcutMatch? matchPlayerShortcut(KeyEvent event) {
  if (event is! KeyDownEvent) return null;
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isControlPressed ||
      keyboard.isMetaPressed ||
      keyboard.isAltPressed) {
    return null;
  }
  // `?` se lit au caractère : selon la disposition du clavier, ce n'est pas la
  // même touche (Maj + / en QWERTY, Maj + , en AZERTY).
  if (event.character == '?') {
    return (shortcut: PlayerShortcut.showHelp, fraction: 0);
  }

  final key = event.logicalKey;
  final letter = _letters[key];
  if (letter != null) return (shortcut: letter, fraction: 0);

  final digit = _digits[key];
  if (digit != null) {
    return (shortcut: PlayerShortcut.seekToFraction, fraction: digit / 10);
  }
  return null;
}

final Map<LogicalKeyboardKey, PlayerShortcut> _letters = {
  LogicalKeyboardKey.keyK: PlayerShortcut.playPause,
  LogicalKeyboardKey.keyJ: PlayerShortcut.seekBack,
  LogicalKeyboardKey.keyL: PlayerShortcut.seekForward,
  LogicalKeyboardKey.keyF: PlayerShortcut.toggleFullscreen,
  LogicalKeyboardKey.keyM: PlayerShortcut.toggleMute,
  LogicalKeyboardKey.keyN: PlayerShortcut.nextEpisode,
};

final Map<LogicalKeyboardKey, int> _digits = {
  LogicalKeyboardKey.digit0: 0,
  LogicalKeyboardKey.digit1: 1,
  LogicalKeyboardKey.digit2: 2,
  LogicalKeyboardKey.digit3: 3,
  LogicalKeyboardKey.digit4: 4,
  LogicalKeyboardKey.digit5: 5,
  LogicalKeyboardKey.digit6: 6,
  LogicalKeyboardKey.digit7: 7,
  LogicalKeyboardKey.digit8: 8,
  LogicalKeyboardKey.digit9: 9,
  LogicalKeyboardKey.numpad0: 0,
  LogicalKeyboardKey.numpad1: 1,
  LogicalKeyboardKey.numpad2: 2,
  LogicalKeyboardKey.numpad3: 3,
  LogicalKeyboardKey.numpad4: 4,
  LogicalKeyboardKey.numpad5: 5,
  LogicalKeyboardKey.numpad6: 6,
  LogicalKeyboardKey.numpad7: 7,
  LogicalKeyboardKey.numpad8: 8,
  LogicalKeyboardKey.numpad9: 9,
};

/// Le volume d'avant la coupure, par session : `M` le rend tel qu'il était.
final Expando<double> _volumeBeforeMute = Expando('volumeBeforeMute');

/// Coupe le son, ou le rend au volume d'avant la coupure.
void togglePlayerMute(PlaybackSession session) {
  if (session.volume > 0) {
    _volumeBeforeMute[session] = session.volume;
    session.setVolume(0);
    return;
  }
  session.setVolume(_volumeBeforeMute[session] ?? 100);
}

const List<(String, String)> _helpRows = [
  ('Espace  ·  K', 'Lecture / pause'),
  ('←  ·  J', 'Reculer de 10 s'),
  ('→  ·  L', 'Avancer de 10 s'),
  ('↑  ↓', 'Volume'),
  ('M', 'Couper le son'),
  ('F', 'Plein écran'),
  ('N', 'Épisode suivant'),
  ('0 – 9', 'Aller à 0 % – 90 %'),
  ('Échap', 'Quitter le plein écran'),
  ('?', 'Afficher ces raccourcis'),
];

/// La fiche des raccourcis, ouverte par `?`.
Future<void> showPlayerShortcutsHelp(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Raccourcis clavier'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (keys, action) in _helpRows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        keys,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        action,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
}
