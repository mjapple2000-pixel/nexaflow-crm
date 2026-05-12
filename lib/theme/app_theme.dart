import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // ─────────────────────────────────────────────
  //  COLORS
  // ─────────────────────────────────────────────
  static const Color sidebarBg      = Color(0xFF0F1117);
  static const Color brand          = Color(0xFF6C63FF);
  static const Color brandActive    = Color(0x296C63FF);
  static const Color textActive     = Color(0xFFA89CFF);
  static const Color textNormal     = Color(0x8CFFFFFF);
  static const Color textMuted      = Color(0x4DFFFFFF);
  static const Color textSub        = Color(0x66FFFFFF);
  static const Color divider        = Color(0x14FFFFFF);
  static const Color badgeBg        = Color(0x4D6C63FF);
  static const Color pageBg         = Color(0xFFF5F5F7);
  static const Color cardBg         = Color(0xFFFFFFFF);
  static const Color textPrimary    = Color(0xFF111111);
  static const Color textSecondary  = Color(0xFF6B6B6B);
  static const Color borderColor    = Color(0xFFE5E5EA);
  static const Color success        = Color(0xFF34C759);
  static const Color error          = Color(0xFFFF3B30);

  // ─────────────────────────────────────────────
  //  THEME
  // ─────────────────────────────────────────────
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: pageBg,
      colorScheme: ColorScheme.light(
        primary: brand,
        secondary: brand,
        surface: cardBg,
        error: error,
      ),
      textTheme: GoogleFonts.interTextTheme().copyWith(
        displayLarge: GoogleFonts.inter(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: textPrimary,
        ),
        headlineLarge: GoogleFonts.inter(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        headlineMedium: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: textPrimary,
        ),
        bodyLarge: GoogleFonts.inter(
          fontSize: 14,
          color: textPrimary,
        ),
        bodyMedium: GoogleFonts.inter(
          fontSize: 12,
          color: textSecondary,
        ),
        labelLarge: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: textPrimary,
        ),
        labelSmall: GoogleFonts.inter(
          fontSize: 11,
          color: textSecondary,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: borderColor),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: brand,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: brand, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: GoogleFonts.inter(
          fontSize: 14,
          color: textSecondary,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: borderColor,
        thickness: 1,
      ),
    );
  }
}