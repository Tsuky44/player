import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../../services/playback_preferences_storage.dart';

/// « Vous regardez encore ? » : compte les épisodes qui s'enchaînent sans que
/// personne ne touche à rien, et dit au lecteur quand cesser d'enchaîner.
///
/// La panne d'origine : s'endormir devant un épisode, et retrouver au réveil
/// la série dix heures plus loin — la progression perdue, le serveur et
/// l'écran allumés pour personne. Voir ADR-0045.
///
/// Comme [SleepTimer], il vit hors du lecteur : chaque épisode a son propre
/// écran, qui remplace le précédent, et un compte rangé dedans repartirait de
/// zéro à chaque générique.
///
/// Il écoute lui-même le clavier, la télécommande et le pointeur, à la racine
/// de l'app et non dans le lecteur : un menu ouvert par-dessus l'image vit
/// dans un autre arbre, et y choisir une piste est bien « être là ».
class StillWatching {
  StillWatching._();

  static final StillWatching instance = StillWatching._();

  int _unattended = 0;
  int _players = 0;

  /// Les épisodes enchaînés depuis le dernier geste de quelqu'un.
  @visibleForTesting
  int get unattendedEpisodes => _unattended;

  /// Un lecteur s'ouvre. Voir [release].
  void retain() {
    if (_players++ == 0) _listen();
  }

  /// Un lecteur se ferme. Quand c'était le dernier, le compte repart de zéro :
  /// la série lancée le lendemain n'hérite pas de la soirée de la veille.
  ///
  /// Entre deux épisodes le suivant est déjà ouvert quand le précédent se
  /// ferme, si bien que le compte ne passe pas par zéro.
  void release() {
    if (_players > 0) _players--;
    if (_players > 0) return;
    _unlisten();
    _unattended = 0;
  }

  /// Quelqu'un est là. Pour ce que l'écoute globale ne voit pas : une touche
  /// de casque, la réponse à la question elle-même.
  void noteActivity() => _unattended = 0;

  /// Le lecteur s'apprête à lancer l'épisode suivant de lui-même. Faux : il
  /// doit poser la question et attendre, au lieu d'enchaîner.
  ///
  /// Hors de la plage horaire le compte continue de monter sans rien
  /// demander : celui qui s'endort à 21 h devant une plage qui commence à
  /// 22 h est arrêté au premier générique qui tombe dedans.
  bool allowAutoAdvance({DateTime? now}) {
    final settings = PlaybackPreferencesStorage.stillWatching;
    final chained = _unattended + 1;
    if (chained >= settings.episodes &&
        settings.appliesAt(now ?? DateTime.now())) {
      return false;
    }
    _unattended = chained;
    return true;
  }

  void _listen() {
    HardwareKeyboard.instance.addHandler(_handleKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointer);
  }

  void _unlisten() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handlePointer);
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent) noteActivity();
    // Jamais consommée : écouter n'est pas répondre à la touche.
    return false;
  }

  void _handlePointer(PointerEvent event) {
    final present = event is PointerDownEvent ||
        event is PointerSignalEvent ||
        // Un survol sans déplacement est celui que le moteur fabrique quand
        // l'image change sous une souris immobile : il ne prouve personne.
        (event is PointerHoverEvent &&
            !event.synthesized &&
            event.delta != Offset.zero);
    if (present) noteActivity();
  }

  @visibleForTesting
  void resetForTest() {
    if (_players > 0) _unlisten();
    _players = 0;
    _unattended = 0;
  }
}
