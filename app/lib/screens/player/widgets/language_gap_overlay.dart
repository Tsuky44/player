import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../models/models.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/app_type.dart';
import '../playback/audio_language_gap.dart';
import 'end_card_chrome.dart';

/// Page levée quand un épisode n'existe pas dans la langue qu'on suit — la VF
/// d'un anime sorti d'abord en VOSTFR (ADR-0057) : au moment d'enchaîner sur
/// l'épisode suivant, ou au lancement de celui qu'on ouvre ([atLaunch]).
///
/// Comme les autres pages de fin, elle n'agit jamais seule : continuer dans une
/// autre langue ou attendre la sienne est toujours un choix, jamais un compte à
/// rebours.
class LanguageGapOverlay extends StatelessWidget {
  final AudioLanguageGap gap;

  /// L'épisode dont on parle, pour le nommer.
  final HomeMediaItem? episode;

  /// Vrai quand c'est l'épisode en cours qui n'a pas la langue, faux quand
  /// c'est le suivant.
  final bool atLaunch;

  final VoidCallback onContinue;
  final VoidCallback onWait;
  final VoidCallback onDismiss;

  /// Width reserved on the left for the shrunk video.
  final double videoInset;

  const LanguageGapOverlay({
    super.key,
    required this.gap,
    required this.onContinue,
    required this.onWait,
    required this.onDismiss,
    this.episode,
    this.atLaunch = false,
    this.videoInset = 0,
  });

  @override
  Widget build(BuildContext context) {
    final wanted = languageNameInSentence(gap.wanted);
    final offered = languageNameInSentence(gap.offered);
    final episodeTitle = episode?.episodeTitle ?? episode?.media.title;

    return EndCardPanel(
      backdropUrl: episode?.media.posterUrl,
      videoInset: videoInset,
      eyebrow: EndCardEyebrow(
        label: tr('PAS ENCORE EN {0}', [wanted.toUpperCase()]),
        onDismiss: onDismiss,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (episodeTitle != null && episodeTitle.isNotEmpty) ...[
            Text(
              episodeTitle.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: AppType.footnote,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            atLaunch
                ? tr('Cet épisode n’est pas disponible en {0}.', [wanted])
                : tr(
                    'L’épisode suivant n’est pas disponible en {0}.', [wanted]),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: AppType.largeTitle,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              EndCardPill(
                label: tr('Disponible en {0}', [offered]),
                icon: Icons.volume_up_outlined,
                accent: true,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            tr(
              'Voulez-vous le regarder en {0} ? Si vous préférez attendre, la '
              'série reviendra dans « Reprendre la lecture » dès que l’épisode sera '
              'disponible en {1}.',
              [offered, wanted],
            ),
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: AppType.body,
              height: 1.55,
            ),
          ),
        ],
      ),
      actions: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ElevatedButton.icon(
            // Le premier choix reçoit le focus : à la télécommande, la page
            // s'ouvre sur une réponse et non sur le vide.
            autofocus: true,
            onPressed: onContinue,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              textStyle: const TextStyle(
                fontSize: AppType.callout,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            icon: Icon(
              atLaunch ? Icons.play_arrow_rounded : Icons.skip_next_rounded,
              size: 19,
            ),
            label: Text(tr('Continuer en {0}', [offered])),
          ),
          OutlinedButton.icon(
            onPressed: onWait,
            // L'anneau du thème au focus : `side` posé seul le remplaçait.
            style: AppTheme.focusRinged(
                OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(
                    fontSize: AppType.callout,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                resting: const BorderSide(color: AppColors.border)),
            icon: const Icon(Icons.hourglass_top_rounded, size: 19),
            label: Text(tr('Attendre la version en {0}', [wanted])),
          ),
        ],
      ),
    );
  }
}
