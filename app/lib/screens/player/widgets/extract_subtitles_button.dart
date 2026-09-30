import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../theme/app_colors.dart';
import '../hooks/use_player_controller.dart';

/// « Extraire les sous-titres », au pied de la liste des pistes du lecteur.
///
/// Le serveur réserve l'extraction à `manage_library` (voir ADR-0001) : un
/// compte sans ce droit ne voit pas le bouton, plutôt que de le presser pour
/// lire un refus. Il était recopié dans deux menus du lecteur, avec deux jeux
/// de couleurs ; il n'existe plus qu'ici.
class ExtractSubtitlesButton extends StatefulWidget {
  final PlayerController controller;

  const ExtractSubtitlesButton({super.key, required this.controller});

  @override
  State<ExtractSubtitlesButton> createState() => _ExtractSubtitlesButtonState();
}

class _ExtractSubtitlesButtonState extends State<ExtractSubtitlesButton> {
  bool _extracting = false;

  Future<void> _extract() async {
    setState(() => _extracting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final subs = await widget.controller.forceExtractSubtitles();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            subs.isEmpty
                ? 'Aucun sous-titre texte trouvé dans ce fichier'
                : '${subs.length} piste${subs.length > 1 ? 's' : ''} extraite${subs.length > 1 ? 's' : ''}',
          ),
          backgroundColor: subs.isEmpty ? AppColors.warning : AppColors.success,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Extraction échouée : $e'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canExtract =
        context.select<AuthProvider, bool>((a) => a.permissions.manageLibrary);
    if (!canExtract) return const SizedBox.shrink();

    final busy = _extracting || widget.controller.isExtractingSubtitles;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        width: double.infinity,
        child: TextButton.icon(
          onPressed: busy ? null : _extract,
          icon: busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined, size: 16),
          label: Text(
            busy ? 'Extraction en cours…' : 'Extraire les sous-titres',
            style: const TextStyle(fontSize: 12),
          ),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.accent,
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );
  }
}
