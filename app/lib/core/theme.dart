import 'package:flutter/material.dart';

/// Sotto's calm, low-contrast palette.
abstract final class SottoTheme {
  static const Color seed = Color(0xFF5B4B8A);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      // Bundled (see pubspec.yaml), never downloaded.
      fontFamily: 'Roboto',
      colorScheme: scheme,
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    );
  }
}
