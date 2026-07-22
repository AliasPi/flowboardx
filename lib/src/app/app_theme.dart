import 'package:flutter/material.dart';

abstract final class FlowboardColors {
  static const background = Color(0xFF111416);
  static const panel = Color(0xFF1A1F22);
  static const panelElevated = Color(0xFF252B2F);
  static const canvas = Color(0xFFF8F7F2);
  static const ink = Color(0xFF101113);
  static const mint = Color(0xFF4DE2B1);
  static const blue = Color(0xFF62A8FF);
  static const warning = Color(0xFFFFC857);
  static const danger = Color(0xFFFF6B72);
  static const textPrimary = Color(0xFFF4F7F8);
  static const textSecondary = Color(0xFFAAB4BA);
  static const divider = Color(0xFF343B40);
}

ThemeData buildFlowboardTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: FlowboardColors.mint,
    brightness: Brightness.dark,
    surface: FlowboardColors.panel,
    error: FlowboardColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: FlowboardColors.background,
    fontFamily: 'sans-serif',
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    appBarTheme: const AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: Colors.transparent,
      foregroundColor: FlowboardColors.textPrimary,
      titleTextStyle: TextStyle(
        color: FlowboardColors.textPrimary,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
      ),
    ),
    cardTheme: CardThemeData(
      color: FlowboardColors.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: FlowboardColors.divider),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: FlowboardColors.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: FlowboardColors.panelElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: FlowboardColors.divider),
      ),
      textStyle: const TextStyle(color: FlowboardColors.textPrimary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(56, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(52, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: FlowboardColors.panelElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
  );
}
