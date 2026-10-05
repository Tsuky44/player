import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

/// La valeur courante d'un menu déroulant de réglages, avec son chevron : ce
/// qu'on pose comme `child` d'un `PopupMenuButton` dans une `SettingsTile`.
class SettingsDropdownLabel extends StatelessWidget {
  const SettingsDropdownLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          const Icon(Icons.unfold_more_rounded,
              size: 18, color: AppColors.textSecondary),
        ],
      ),
    );
  }
}
