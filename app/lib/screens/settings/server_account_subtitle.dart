import '../../l10n/tr.dart';
import '../../models/server_account.dart';

/// Le sous-titre d'une ligne de « Mes serveurs » : le compte, l'hôte (ou
/// « serveur actif »), le serveur principal et les comptes liés.
///
/// Chaque morceau passe par [tr] : la ligne était assemblée en français
/// brut, et l'interface anglaise affichait « tsuky · serveur actif ».
String serverAccountSubtitle(
  ServerAccount account, {
  required bool isActive,
  required bool isPrimary,
  required List<AccountLink> links,
}) {
  final host = isActive ? tr('serveur actif') : account.prettyHost;
  final primary = isPrimary ? ' · ${tr('serveur principal')}' : '';
  final head = '${account.username} · $host$primary';
  if (links.isEmpty) return head;
  final linked = links.map((l) {
    final args = [l.remoteUsername, l.displayName];
    return l.isActive
        ? tr('{0} sur le serveur {1}', args)
        : tr('{0} sur le serveur {1} (en attente des administrateurs)', args);
  }).join(', ');
  return '$head\n${tr('Lié à {0}', [linked])}';
}
