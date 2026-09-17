import 'package:flutter/material.dart';
import 'app_colors.dart';

abstract final class AppTheme {
  /// La police de l'application, embarquée dans le paquet — voir l'ADR-0025.
  ///
  /// Elle l'était auparavant par `google_fonts`, qui allait chercher les mêmes
  /// fichiers sur le réseau au premier lancement et les relisait depuis un
  /// cache disque aux suivants. Entre les deux, le texte s'affichait dans la
  /// police du système puis sautait : une application qui doit ouvrir un film
  /// sans serveur joignable ne peut pas dépendre de Google pour écrire un
  /// titre.
  static const String fontFamily = 'Manrope';

  /// The outline a focused control wears.
  ///
  /// Material's own focus treatment is a ten-percent wash of the primary
  /// colour — legible at arm's length on a phone, invisible from a sofa. A
  /// remote-driven UI lives or dies on the user being able to find the cursor,
  /// so focus gets a real ring, on every button, everywhere.
  static WidgetStateProperty<BorderSide?> _focusSide(BorderSide? resting) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(color: AppColors.accent, width: 2.5);
      }
      return resting;
    });
  }

  /// Le thème, construit une fois.
  ///
  /// C'était un getter : chaque lecture reconstruisait `ThemeData` et toutes
  /// ses déclinaisons — et en rendait une *autre instance*, ce qui fait
  /// reconstruire tout ce qui lit `Theme.of(context)`. La racine le lit deux
  /// fois sur un téléviseur.
  static ThemeData? _dark;
  static ThemeData get dark => _dark ??= _buildDark();

  static ThemeData _buildDark() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      // Posé sur le thème et non sur le seul `textTheme` : un `TextStyle`
      // construit à la main, sans partir d'un style du thème, hérite alors de
      // la police lui aussi au lieu de retomber sur celle du système.
      fontFamily: fontFamily,
      scaffoldBackgroundColor: AppColors.background,
      primaryColor: AppColors.primary,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        secondary: AppColors.accentMuted,
        surface: AppColors.surface,
        error: AppColors.error,
        onPrimary: AppColors.onAccent,
        onSecondary: AppColors.onAccent,
        onSurface: AppColors.textPrimary,
        outline: AppColors.border,
      ),
    );

    final textTheme = base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 20,
          letterSpacing: -0.02 * 20,
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surfaceElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceElevated,
        selectedColor: AppColors.primary.withValues(alpha: 0.22),
        labelStyle: textTheme.labelLarge?.copyWith(color: AppColors.textSecondary),
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: AppColors.glassBorder),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      dividerTheme: DividerThemeData(
        color: AppColors.glassBorder,
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceElevated,
        hintStyle: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
        labelStyle: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: _focusRinged(ElevatedButton.styleFrom(
          backgroundColor: AppColors.textPrimary,
          foregroundColor: AppColors.background,
          disabledBackgroundColor: AppColors.surfaceHover,
          disabledForegroundColor: AppColors.textMuted,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        )),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _focusRinged(
          OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: BorderSide(color: AppColors.glassBorder),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
          resting: BorderSide(color: AppColors.glassBorder),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _focusRinged(TextButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500),
        )),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceElevated,
        contentTextStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.textPrimary,
        foregroundColor: AppColors.background,
        elevation: 0,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surfaceElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      focusColor: AppColors.primary.withValues(alpha: 0.24),
    );
  }

  /// Adds the focus ring to a button style without disturbing anything else it
  /// declares. [resting] is the border the button wears when it is not focused.
  static ButtonStyle _focusRinged(ButtonStyle style, {BorderSide? resting}) {
    return style.copyWith(side: _focusSide(resting));
  }
}
