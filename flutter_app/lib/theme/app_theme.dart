import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF081521);
  static const backgroundAlt = Color(0xFF102235);
  static const surface = Color(0xFF15283B);
  static const surfaceLight = Color(0xFF1D3349);
  static const border = Color(0xFF2A4963);
  static const textPrimary = Color(0xFFF3F6FA);
  static const textSecondary = Color(0xFFAAB7C4);
  static const pressedBlue = Color(0xFF1E88E5);
  static const pressedBlueLight = Color(0xFF4DA3F7);
  static const pressedBlueDark = Color(0xFF1565C0);
  static const connectedBlueGrey = Color(0xFF738AA3);
  static const connectedBlueGreyLight = Color(0xFF8FA4BB);
  static const connectedBlueGreyDark = Color(0xFF5C7189);
  static const disconnectedGrey = Color(0xFF3E434A);
  static const disconnectedGreyLight = Color(0xFF505860);
  static const disconnectedGreyDark = Color(0xFF2A2F35);
  static const success = Color(0xFF4DD29A);
  static const warning = Color(0xFFF0A94A);
  static const error = Color(0xFFE57373);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.pressedBlue,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.pressedBlue,
    secondary: AppColors.connectedBlueGrey,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    error: AppColors.error,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    cardColor: AppColors.surface,
    dividerColor: AppColors.border,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.backgroundAlt,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.backgroundAlt,
      labelStyle: const TextStyle(color: AppColors.textSecondary),
      hintStyle: const TextStyle(color: AppColors.textSecondary),
      prefixIconColor: AppColors.connectedBlueGreyLight,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.pressedBlue, width: 1.5),
      ),
    ),
  );
}

ButtonStyle raisedButtonStyle({
  Color normalColor = AppColors.connectedBlueGrey,
  double radius = 12,
}) {
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.disconnectedGrey.withValues(alpha: 0.45);
      }
      if (states.contains(WidgetState.pressed)) {
        return AppColors.pressedBlue;
      }
      return normalColor;
    }),
    foregroundColor: WidgetStateProperty.all(AppColors.textPrimary),
    shadowColor: WidgetStateProperty.all(
      Colors.black.withValues(alpha: 0.45),
    ),
    elevation: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return 0;
      return states.contains(WidgetState.pressed) ? 2 : 8;
    }),
    padding: WidgetStateProperty.all(
      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    ),
    shape: WidgetStateProperty.all(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
    ),
    side: WidgetStateProperty.resolveWith((states) {
      final color = states.contains(WidgetState.pressed)
          ? AppColors.pressedBlueLight
          : normalColor.withValues(alpha: 0.9);
      return BorderSide(color: color, width: 1.2);
    }),
    surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
  );
}
