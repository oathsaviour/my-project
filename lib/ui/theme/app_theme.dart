import 'package:flutter/material.dart';

/// Cyber-Radar design system for Universal Cross-Platform Transfer.
class AppTheme {
  // Brand colors
  static const Color darkBackground = Color(0xFF0D1117);
  static const Color darkSurface = Color(0xFF161B22);
  static const Color darkCard = Color(0xFF21262D);
  static const Color accentNeon = Color(0xFF00E5FF);
  static const Color accentGreen = Color(0xFF00E676);
  static const Color androidGreen = Color(0xFF3DDC84);
  static const Color appleBlue = Color(0xFF007AFF);
  static const Color warningAmber = Color(0xFFFFB300);
  static const Color textPrimary = Color(0xFFF0F6FC);
  static const Color textSecondary = Color(0xFF8B949E);

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBackground,
      colorScheme: const ColorScheme.dark(
        primary: accentNeon,
        secondary: accentGreen,
        surface: darkSurface,
        background: darkBackground,
        error: Color(0xFFFF5252),
      ),
      cardTheme: CardTheme(
        color: darkCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF30363D), width: 1),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkSurface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
      ),
      useMaterial3: true,
    );
  }
}
