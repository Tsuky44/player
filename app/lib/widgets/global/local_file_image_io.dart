import 'dart:io';

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Affiche un fichier image local, avec un aplat en cas d'absence ou d'échec
/// de décodage — une vignette manquante ne doit pas casser une ligne de liste.
Widget localFileImage(String path, {BoxFit fit = BoxFit.cover}) {
  return Image.file(
    File(path),
    fit: fit,
    errorBuilder: (_, __, ___) =>
        const ColoredBox(color: AppColors.surfaceElevated),
  );
}
