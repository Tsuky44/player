import 'package:flutter/foundation.dart';

import '../../models/announcement.dart';

/// Montre le message de l'administrateur une fois par ouverture de session
/// (ADR-0069).
///
/// La coquille demande à chaque compte qui s'ouvre — au lancement, à une
/// bascule de serveur — et le serveur répond ce qui reste à voir : c'est lui
/// qui sait si le compte l'a déjà fermé, sur cet appareil ou un autre. La
/// marque n'est posée qu'une fois le message affiché puis fermé ; un message
/// qui n'a pas pu s'afficher revient au lancement suivant.
class PendingAnnouncementCheck {
  PendingAnnouncementCheck({
    required this.fetch,
    required this.markSeen,
    required this.show,
  });

  final Future<ServerAnnouncement?> Function() fetch;
  final Future<void> Function(int id) markSeen;

  /// Affiche le message et rend la main quand il est fermé ; faux s'il n'a
  /// pas pu l'être (écran démonté entre-temps).
  final Future<bool> Function(ServerAnnouncement announcement) show;

  String? _checkedFor;
  bool _busy = false;

  Future<void> run(String? accountId) async {
    if (accountId == null || accountId == _checkedFor || _busy) return;
    _checkedFor = accountId;
    _busy = true;
    try {
      final ServerAnnouncement? announcement;
      try {
        announcement = await fetch();
      } catch (e) {
        // Hors ligne ou serveur injoignable : rien n'est perdu, la question
        // se reposera à la prochaine ouverture de ce compte.
        debugPrint('Annonce : lecture impossible ($e)');
        _checkedFor = null;
        return;
      }
      if (announcement == null) return;
      if (!await show(announcement)) {
        _checkedFor = null;
        return;
      }
      try {
        await markSeen(announcement.id);
      } catch (e) {
        // Le message a été lu ; sans la marque, il reviendra une fois de
        // plus, ce qui vaut mieux que de bloquer la coquille.
        debugPrint('Annonce : marque « vu » non envoyée ($e)');
      }
    } finally {
      _busy = false;
    }
  }
}
