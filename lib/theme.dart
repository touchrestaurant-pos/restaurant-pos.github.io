import 'package:flutter/material.dart';

/// Navy and gold colour scheme used across every screen.
class Brand {
  static const navy = Color(0xFF1A2F6C);
  static const navyLight = Color(0xFF2C4585);
  static const gold = Color(0xFFE8A900);
  static const background = Color(0xFFE9EDF5);
  static const border = Color(0xFFD5DBE8);
  static const muted = Color(0xFF4F5F83);
  static const green = Color(0xFF17794A);
  static const red = Color(0xFFC8283A);
  static const amber = Color(0xFFF2B230);
}

ThemeData buildTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Brand.navy,
    onPrimary: Colors.white,
    secondary: Brand.gold,
    onSecondary: Brand.navy,
    error: Brand.red,
    onError: Colors.white,
    surface: Colors.white,
    onSurface: Brand.navy,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Brand.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: Brand.navy,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Brand.gold,
        foregroundColor: Brand.navy,
        minimumSize: const Size(0, 52),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Brand.border),
      ),
    ),
  );
}
