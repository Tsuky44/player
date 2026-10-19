import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/announcement.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';

/// Le message de l'administrateur, en grand, à l'ouverture de l'app
/// (ADR-0069).
///
/// Il ne se ferme que par son bouton : un tap à côté ne doit pas faire passer
/// pour lu un message qu'on n'a pas vu. Le bouton prend le focus d'emblée, pour
/// qu'une télécommande le ferme d'un appui.
Future<void> showAnnouncementDialog(
  BuildContext context,
  ServerAnnouncement announcement,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AnnouncementDialog(announcement: announcement),
  );
}

class AnnouncementDialog extends StatelessWidget {
  const AnnouncementDialog({super.key, required this.announcement});

  final ServerAnnouncement announcement;

  @override
  Widget build(BuildContext context) {
    final title = announcement.title.isEmpty
        ? tr('Un message de votre serveur')
        : announcement.title;

    return Dialog(
      backgroundColor: AppColors.surfaceElevated,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.accent.withValues(alpha: 0.15),
                  ),
                  child: const Icon(AppIcons.announcement,
                      size: 34, color: AppColors.accent),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: AppType.display,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              // Le texte prend la place qui reste et défile au-delà : le titre
              // et le bouton restent à l'écran, même sur un téléphone.
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    announcement.message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: AppType.headline,
                      height: 1.45,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              FilledButton(
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  textStyle: const TextStyle(
                    fontSize: AppType.headline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(tr('J’ai compris')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
