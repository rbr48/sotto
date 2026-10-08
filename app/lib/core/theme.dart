import 'package:flutter/material.dart';

/// Sotto's calm, professional look: neutral surfaces, white (or deep grey)
/// cards, the brand violet for what you act on.
abstract final class SottoTheme {
  static const Color seed = Color(0xFF5B4B8A);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final light = brightness == Brightness.light;
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness)
        .copyWith(
          primary: light ? seed : const Color(0xFFC9BCF5),
          onPrimary: light ? Colors.white : const Color(0xFF2B1F55),
          // Neutral rather than lavender-tinted surfaces.
          surface: light ? const Color(0xFFF6F6F9) : const Color(0xFF0F0F14),
          onSurface: light ? const Color(0xFF16161D) : const Color(0xFFE7E6EE),
          onSurfaceVariant: light
              ? const Color(0xFF5D5B68)
              : const Color(0xFFA9A7B5),
          surfaceContainerLowest: light
              ? Colors.white
              : const Color(0xFF15151C),
          surfaceContainerLow: light ? Colors.white : const Color(0xFF18181F),
          surfaceContainer: light
              ? const Color(0xFFF0EFF4)
              : const Color(0xFF1D1D25),
          surfaceContainerHigh: light
              ? const Color(0xFFEAE9F0)
              : const Color(0xFF23232C),
          surfaceContainerHighest: light
              ? const Color(0xFFE4E3EB)
              : const Color(0xFF2A2A34),
          outline: light ? const Color(0xFF8E8C99) : const Color(0xFF6E6C7A),
          outlineVariant: light
              ? const Color(0xFFE2E1E8)
              : const Color(0xFF2E2E38),
        );
    final base = ThemeData(
      // Bundled (see pubspec.yaml), never downloaded.
      fontFamily: 'Roboto',
      colorScheme: scheme,
      useMaterial3: true,
    );
    final text = base.textTheme;
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    const buttonSize = Size(64, 48);
    const buttonText = TextStyle(
      // Named here too: a button's text style replaces the theme's font.
      fontFamily: 'Roboto',
      fontSize: 15,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
    );
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: buttonSize,
          shape: rounded,
          textStyle: buttonText,
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: buttonSize,
          shape: rounded,
          textStyle: buttonText,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.5)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: rounded,
          textStyle: buttonText.copyWith(fontSize: 14),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.outline.withValues(alpha: light ? 0.45 : 0.6),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: rounded,
        iconColor: scheme.onSurfaceVariant,
        subtitleTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: light ? 0.12 : 0.22),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelMedium?.copyWith(
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.primary.withValues(alpha: light ? 0.12 : 0.22),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle: text.labelMedium?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Icon(Icons.check, size: 14)
              : null,
        ),
      ),
    );
  }
}
