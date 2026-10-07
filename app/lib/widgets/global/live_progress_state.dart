import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../services/progress_revision_watch.dart';
import '../../utils/on_screen.dart';

/// Pour un écran qui montre où le compte en est (accueil, fiche d'un film ou
/// d'une série) : tant qu'on le voit, il apprend en quelques secondes ce qui a
/// été regardé sur un autre appareil, au lieu d'attendre un redémarrage.
///
/// L'écran dit seulement quoi relire, dans [onProgressChanged]. Le sondage
/// s'arrête dès qu'il n'est plus vu ([OnScreenState]) : sous le lecteur, ses
/// propres battements de coeur le feraient se relire pour rien.
mixin LiveProgressState<T extends StatefulWidget> on OnScreenState<T> {
  late final ProgressRevisionWatch _progressWatch = ProgressRevisionWatch(
    fetch: () => Provider.of<AuthProvider>(context, listen: false)
        .apiClient
        .getProgressRevision(),
    onChanged: () {
      if (mounted) onProgressChanged();
    },
  );

  /// La progression du compte a changé : relire ce que l'écran en montre,
  /// sans indicateur de chargement.
  void onProgressChanged();

  /// Vrai pour l'écran qui relit déjà ses données à chaque retour au premier
  /// plan : il n'a pas à être prévenu une seconde fois à ce moment-là.
  @protected
  bool get reloadsOnReturn => false;

  @override
  @mustCallSuper
  void didChangeOnScreen(bool onScreen) {
    if (onScreen) {
      _progressWatch.start(adoptFirst: reloadsOnReturn);
    } else {
      _progressWatch.stop();
    }
  }

  @override
  void dispose() {
    _progressWatch.stop();
    super.dispose();
  }
}
