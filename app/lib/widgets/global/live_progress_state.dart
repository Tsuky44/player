import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../services/progress_revision_watch.dart';
import '../../utils/on_screen.dart';

/// Pour un écran qui montre où le compte en est (accueil, fiche d'un film ou
/// d'une série) : tant qu'on le voit, il apprend à l'instant ce qui a été
/// regardé sur un autre appareil, au lieu d'attendre un redémarrage.
///
/// L'écran dit seulement quoi relire, dans [onProgressChanged]. Il y est
/// appelé à chaque changement venu d'ailleurs, et d'office à chaque retour à
/// l'écran — à la sortie du lecteur, au retour d'une fiche, au réveil de
/// l'app. La toute première apparition n'en fait pas partie : l'écran charge
/// alors lui-même ses données.
///
/// L'attente s'arrête dès qu'il n'est plus vu ([OnScreenState]) : sous le
/// lecteur, ses propres battements de coeur le feraient se relire pour rien.
mixin LiveProgressState<T extends StatefulWidget> on OnScreenState<T> {
  late final ProgressRevisionWatch _progressWatch = ProgressRevisionWatch(
    fetch: (since, cancelToken) =>
        Provider.of<AuthProvider>(context, listen: false)
            .apiClient
            .getProgressRevision(since: since, cancelToken: cancelToken),
    onChanged: () {
      if (mounted) onProgressChanged();
    },
  );

  bool _shownBefore = false;

  /// Relire ce que l'écran montre de la progression, sans indicateur de
  /// chargement.
  void onProgressChanged();

  @override
  @mustCallSuper
  void didChangeOnScreen(bool onScreen) {
    if (onScreen) {
      _progressWatch.start(refresh: _shownBefore);
      _shownBefore = true;
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
