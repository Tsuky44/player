/// Quand le lecteur a le droit d'envisager un relais vers un serveur lié.
///
/// Le relais (ADR-0017) reprend la lecture sur un autre serveur quand celui du
/// compte ne répond plus, et bascule toute l'app dessus. Il sondait le serveur
/// toutes les dix secondes quoi qu'il arrive, film en cours compris, avec un
/// délai de connexion de trois secondes — résolution DNS incluse. Sur un poste
/// dont le DNS met onze secondes à répondre dès qu'un nom sort du cache, un
/// démarrage bloqué sur cette même résolution faisait échouer la sonde à la
/// dixième seconde : le serveur « ne répondait plus », et la lecture partait
/// sur le serveur lié alors que le film était là, sur le serveur du compte.
///
/// Un lecteur qui reçoit ses images n'a pas de serveur à remplacer. Le relais
/// ne s'envisage donc que quand la lecture est réellement en panne : pas
/// d'image passé [startupGrace], ou un tampon vide depuis [stallGrace].
class RelayTrigger {
  RelayTrigger({
    DateTime Function()? now,
    this.startupGrace = const Duration(seconds: 20),
    this.stallGrace = const Duration(seconds: 20),
  })  : _now = now ?? DateTime.now,
        _openedAt = (now ?? DateTime.now)();

  final DateTime Function() _now;
  final Duration startupGrace;
  final Duration stallGrace;
  final DateTime _openedAt;
  DateTime? _bufferingSince;

  void noteBuffering(bool buffering) {
    if (!buffering) {
      _bufferingSince = null;
    } else {
      _bufferingSince ??= _now();
    }
  }

  /// Vrai quand la lecture est assez en panne pour sonder le serveur.
  bool inTrouble({required bool hasFirstFrame}) {
    final now = _now();
    if (!hasFirstFrame) return now.difference(_openedAt) >= startupGrace;
    final since = _bufferingSince;
    return since != null && now.difference(since) >= stallGrace;
  }
}
