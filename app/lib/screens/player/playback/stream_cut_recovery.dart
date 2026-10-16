import 'dart:async';

/// Ce qu'on fait d'une « fin » que le moteur annonce loin de la fin du média.
///
/// Quand le serveur s'arrête en pleine lecture — un conteneur qui se met à
/// jour, une machine qui redémarre — la connexion se ferme. mpv tente de se
/// reconnecter quelques secondes, abandonne, lit ce qu'il avait en mémoire et
/// annonce la fin du fichier, exactement comme au générique. L'écran
/// enchaînait alors sur l'épisode suivant au milieu de celui-ci.
///
/// Une fin à plus de [endTolerance] de la durée connue est donc une coupure :
/// on rouvre le flux à la seconde atteinte, en réessayant jusqu'à ce que le
/// serveur réponde à nouveau. Une seconde fin au même endroit juste après une
/// reprise réussie est une vraie fin — un fichier plus court que la durée
/// qu'il annonce — sans quoi la lecture tournerait en boucle sur ce point.
class StreamCutRecovery {
  StreamCutRecovery({
    required this.reopenAt,
    required this.alive,
    this.endTolerance = const Duration(seconds: 30),
    this.retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 3),
      Duration(seconds: 5),
    ],
    this.steadyDelay = const Duration(seconds: 10),
  });

  /// Rouvre la lecture à cette seconde. Vrai si le serveur a répondu.
  final Future<bool> Function(int seconds) reopenAt;

  /// Faux dès que le lecteur est démonté : on cesse alors de réessayer.
  final bool Function() alive;

  /// Ce qui reste à lire en deçà duquel une fin est la vraie : un générique
  /// coupé ne mérite pas qu'on le rejoue.
  final Duration endTolerance;

  /// Les premiers délais entre deux tentatives, puis [steadyDelay] tant que le
  /// serveur ne répond pas. Un conteneur mis à jour revient en quelques
  /// dizaines de secondes ; quitter le lecteur arrête l'attente.
  final List<Duration> retryDelays;
  final Duration steadyDelay;

  bool _recovering = false;
  int? _recoveredAt;

  bool get isRecovering => _recovering;

  /// Si la fin annoncée à [position] est une coupure plutôt que la fin du
  /// média. Une durée inconnue ou un fichier local ne se discutent pas.
  bool isCut({
    required Duration position,
    required Duration duration,
    bool localFile = false,
  }) {
    if (localFile || duration <= Duration.zero) return false;
    if (duration - position <= endTolerance) return false;
    final previous = _recoveredAt;
    if (previous != null && (position.inSeconds - previous).abs() <= 5) {
      return false;
    }
    return true;
  }

  /// Rouvre à [seconds], en réessayant jusqu'à ce que le serveur réponde.
  /// Un appel pendant une reprise en cours est ignoré.
  Future<void> recover(int seconds) async {
    if (_recovering) return;
    _recovering = true;
    try {
      for (var attempt = 0; alive(); attempt++) {
        if (await _tryReopen(seconds)) {
          _recoveredAt = seconds;
          return;
        }
        if (!alive()) return;
        await Future<void>.delayed(attempt < retryDelays.length
            ? retryDelays[attempt]
            : steadyDelay);
      }
    } finally {
      _recovering = false;
    }
  }

  Future<bool> _tryReopen(int seconds) async {
    try {
      return await reopenAt(seconds);
    } catch (_) {
      // Serveur encore injoignable : la tentative suivante le redemandera.
      return false;
    }
  }
}
