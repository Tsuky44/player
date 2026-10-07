import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/offline_download.dart';
import '../../services/download_manager.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import '../../l10n/tr.dart';

/// Efface une saison ou une série entière de l'appareil, après confirmation.
///
/// Partagée par le bouton de saison de la fiche et par l'écran des
/// téléchargements : la question est posée dans les mêmes termes des deux
/// côtés, et le lot passe par [DownloadManager.deleteAll] plutôt que par vingt
/// suppressions successives. [what] complète le titre, par exemple
/// « la saison 2 » ou « Severance ».
Future<void> confirmDeleteDownloads(
  BuildContext context, {
  required String what,
  required List<OfflineDownload> entries,
}) async {
  if (entries.isEmpty) return;
  final manager = context.read<DownloadManager>();
  final messenger = ScaffoldMessenger.of(context);
  final count = entries.length;
  final bytes = entries.fold<int>(0, (sum, e) => sum + e.bytesReceived);
  final unsynced = entries.any((e) => e.needsSync);
  final items = tr('{0} élément{1}', [count, count > 1 ? 's' : '']);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(tr('Supprimer {0} ?', [what])),
      content: Text(
        '$items (${formatBytes(bytes)}) ${count > 1 ? 'seront effacés' : 'sera effacé'} '
        'de cet appareil. '
        '${unsynced ? 'L’avancement non synchronisé sera envoyé au serveur dès que possible.' : 'Tout reste disponible sur le serveur.'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('Annuler')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          child: Text(tr('Supprimer')),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  final deleted = await manager.deleteAll([for (final e in entries) e.mediaId]);
  if (deleted == 0) return;
  messenger.showSnackBar(SnackBar(
    content: Text(
      tr('{0} élément{1}', [deleted, deleted > 1 ? tr('s supprimés') : tr(' supprimé')]),
    ),
  ));
}
