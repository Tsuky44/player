import 'package:flutter/material.dart';

import '../../../l10n/tr.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_type.dart';

/// Le cadre d'import sous les boutons, comme celui d'OnyxHub : une pastille
/// ambre, le message du serveur et l'étiquette « Importation ».
class RequestImportNotice extends StatelessWidget {
  const RequestImportNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 4),
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppColors.warning,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: AppColors.warning,
                  fontWeight: FontWeight.w600,
                  fontSize: AppType.footnote,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: AppColors.warning.withValues(alpha: 0.2)),
              ),
              child: Text(
                tr('Importation').toUpperCase(),
                style: TextStyle(
                  color: AppColors.warning.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w700,
                  fontSize: AppType.micro,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
