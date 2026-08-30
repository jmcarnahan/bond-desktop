import 'package:flutter/material.dart';

import 'tokens.dart';

/// Bond app theme, assembled ONLY from `lib/theme/` tokens. Material 3,
/// light-only. Ported from a sibling CRM app's theme; the
/// component themes for widgets this app does not build are dropped.
class BondTheme {
  static ThemeData get themeData {
    final textTheme = TextTheme(
      displayLarge: BondType.hero,
      displayMedium: BondType.title,
      displaySmall: BondType.titleSm,
      headlineMedium: BondType.heading,
      headlineSmall: BondType.heading,
      titleLarge: BondType.heading,
      titleMedium: BondType.body.copyWith(fontWeight: FontWeight.w600),
      titleSmall: BondType.small.copyWith(color: BondColors.ink),
      bodyLarge: BondType.body,
      bodyMedium: BondType.small,
      bodySmall: BondType.caption,
      labelLarge: BondType.small.copyWith(
        fontWeight: FontWeight.w600,
        color: BondColors.ink,
      ),
      labelSmall: BondType.label,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: BondType.workFamily,
      primaryColor: BondColors.primary,
      colorScheme: const ColorScheme(
        brightness: Brightness.light,
        primary: BondColors.primary,
        onPrimary: BondColors.surface,
        primaryContainer: BondColors.primaryTint,
        onPrimaryContainer: BondColors.primaryDeep,
        secondary: BondColors.ink,
        onSecondary: BondColors.surface,
        secondaryContainer: BondColors.neutralTint,
        onSecondaryContainer: BondColors.ink,
        error: BondColors.error,
        onError: BondColors.surface,
        surface: BondColors.surface,
        onSurface: BondColors.ink,
        surfaceContainerHighest: BondColors.faintGround,
        onSurfaceVariant: BondColors.inkSecondary,
        surfaceTint: Colors.transparent,
        outline: BondColors.border,
        outlineVariant: BondColors.border,
        shadow: BondColors.ink,
      ),
      scaffoldBackgroundColor: BondColors.ground,
      textTheme: textTheme,

      appBarTheme: const AppBarTheme(
        backgroundColor: BondColors.surface,
        foregroundColor: BondColors.ink,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: BondType.heading,
      ),

      // Elevation 0 + 1px border is the deliberate break from Material
      // elevation-2 cards.
      cardTheme: const CardThemeData(
        color: BondColors.surface,
        elevation: 0,
        margin: EdgeInsets.all(BondSpacing.s12),
        shape: RoundedRectangleBorder(
          borderRadius: BondRadii.mdAll,
          side: BorderSide(color: BondColors.border),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          foregroundColor:
              const WidgetStatePropertyAll<Color>(BondColors.surface),
          backgroundColor: WidgetStateProperty.resolveWith<Color>(
            (states) => states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.pressed)
                ? BondColors.primaryDeep
                : BondColors.primary,
          ),
          elevation: const WidgetStatePropertyAll<double>(0),
          padding: const WidgetStatePropertyAll<EdgeInsets>(
            EdgeInsets.symmetric(
              horizontal: BondSpacing.s24,
              vertical: BondSpacing.s12,
            ),
          ),
          shape: const WidgetStatePropertyAll<RoundedRectangleBorder>(
            RoundedRectangleBorder(borderRadius: BondRadii.smAll),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (states) => states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.pressed)
                ? BondColors.primaryDeep
                : BondColors.primary,
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(
            BondType.small.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),

      outlinedButtonTheme: const OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll<Color>(BondColors.ink),
          backgroundColor: WidgetStatePropertyAll<Color>(BondColors.surface),
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: BondColors.border),
          ),
          shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
            RoundedRectangleBorder(borderRadius: BondRadii.smAll),
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: BondColors.surface,
        hintStyle: BondType.body.copyWith(color: BondColors.inkMuted),
        labelStyle: BondType.small,
        border: const OutlineInputBorder(
          borderSide: BorderSide(color: BondColors.border),
          borderRadius: BondRadii.smAll,
        ),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: BondColors.border),
          borderRadius: BondRadii.smAll,
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: BondColors.primary, width: 2),
          borderRadius: BondRadii.smAll,
        ),
        errorBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: BondColors.error),
          borderRadius: BondRadii.smAll,
        ),
        focusedErrorBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: BondColors.error, width: 2),
          borderRadius: BondRadii.smAll,
        ),
      ),

      dividerTheme: const DividerThemeData(
        color: BondColors.border,
        thickness: 1,
        space: BondSpacing.s32,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: BondColors.ink,
        contentTextStyle: BondType.small.copyWith(color: BondColors.surface),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: BondRadii.mdAll),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: const BoxDecoration(
          color: BondColors.ink,
          borderRadius: BondRadii.smAll,
        ),
        textStyle: BondType.label.copyWith(
          color: BondColors.surface,
          letterSpacing: 0,
        ),
      ),

      popupMenuTheme: const PopupMenuThemeData(
        color: BondColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BondRadii.mdAll,
          side: BorderSide(color: BondColors.border),
        ),
      ),

      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: BondColors.primary),
    );
  }
}
