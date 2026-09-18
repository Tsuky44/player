import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/download_manager.dart';
import '../../services/download_preferences.dart';
import '../../services/network_status.dart';
import '../../theme/app_colors.dart';

/// Ce qui a été répondu à « ce réseau se paie à l'octet ».
enum _MeteredChoice { now, later, cancel }

/// Pose la question avant de mettre quoi que ce soit en file sur un réseau
/// facturé — données mobiles, ou partage de connexion.
///
/// Trois réponses, parce qu'il y a trois intentions distinctes et qu'en fondre
/// deux en ferait perdre une :
///
/// - **maintenant** : on sait ce qu'on fait, l'autorisation vaut pour la session ;
/// - **attendre le Wi-Fi** : le téléchargement est bien demandé, il part plus
///   tard tout seul — c'est le cas qui rend la question supportable, personne
///   n'a à revenir le relancer ;
/// - **annuler** : rien n'est demandé.
///
/// Renvoie vrai quand l'appelant doit mettre en file. Le transfert lui-même,
/// lui, reste arbitré à chaque tour de file par le magasin hors ligne : dire
/// « maintenant » ne grave rien, et repasser en 4G demain reposera la question.
Future<bool> confirmDownloadOnThisNetwork(
  BuildContext context, {
  /// Ce qu'on s'apprête à rapatrier, écrit pour être lu dans une phrase :
  /// « cet épisode », « les 12 épisodes de la saison 2 ».
  required String what,
}) async {
  final network = context.read<NetworkStatus>();
  final preferences = context.read<DownloadPreferences>();
  final manager = context.read<DownloadManager>();

  if (!network.isMetered) return true;
  if (preferences.allowsMeteredNow) return true;

  // Réglé une fois pour toutes sur « Wi-Fi uniquement » : on ne repose pas la
  // question à chaque épisode. La mise en file a lieu, le transfert attend, et
  // le bandeau de l'écran des téléchargements dit ce qu'il attend.
  if (preferences.meteredPolicy == MeteredPolicy.never) return true;

  final choice = await showDialog<_MeteredChoice>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Télécharger sur ce réseau ?'),
      content: Text(
        network.kind == NetworkKind.mobile
            ? 'Vous êtes en données mobiles. Télécharger $what peut consommer '
                'plusieurs gigaoctets de votre forfait — un épisode est '
                'rapatrié dans sa qualité d’origine, sans compression.\n\n'
                'En Wi-Fi, le téléchargement repartira tout seul.'
            : 'Ce réseau est signalé comme limité — un partage de connexion, '
                'par exemple. Télécharger $what peut consommer plusieurs '
                'gigaoctets du forfait qui le fournit : un épisode est '
                'rapatrié dans sa qualité d’origine, sans compression.\n\n'
                'Sur un réseau non limité, le téléchargement repartira tout '
                'seul.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_MeteredChoice.cancel),
          child: const Text('Annuler'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_MeteredChoice.later),
          child: const Text('Attendre le Wi-Fi'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_MeteredChoice.now),
          style: TextButton.styleFrom(foregroundColor: AppColors.warning),
          child: const Text('Télécharger quand même'),
        ),
      ],
    ),
  );

  switch (choice) {
    case null:
    case _MeteredChoice.cancel:
      return false;
    case _MeteredChoice.later:
      return true;
    case _MeteredChoice.now:
      // Les deux objets ont été lus avant la boîte de dialogue : le contexte
      // qui l'a ouverte peut très bien avoir disparu pendant qu'elle était là.
      preferences.allowMeteredForSession();
      manager.onNetworkChanged();
      return true;
  }
}

/// Lève la garde pour cette session et relance ce qui attendait.
///
/// Partagé par la boîte de dialogue et le bandeau « en attente du Wi-Fi » de
/// l'écran des téléchargements, pour que les deux chemins fassent exactement la
/// même chose.
void allowMeteredDownloadsNow(BuildContext context) {
  context.read<DownloadPreferences>().allowMeteredForSession();
  context.read<DownloadManager>().onNetworkChanged();
}
