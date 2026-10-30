import 'package:flutter/material.dart';

class NovaSemanticColors extends ThemeExtension<NovaSemanticColors> {
  const NovaSemanticColors({required this.success, required this.warning});
  final Color success;
  final Color warning;
  @override
  NovaSemanticColors copyWith({Color? success, Color? warning}) =>
      NovaSemanticColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
      );
  @override
  NovaSemanticColors lerp(ThemeExtension<NovaSemanticColors>? other, double t) {
    if (other is! NovaSemanticColors) return this;
    return NovaSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}

extension NovaSemanticColorsContext on BuildContext {
  NovaSemanticColors get nova =>
      Theme.of(this).extension<NovaSemanticColors>() ??
      const NovaSemanticColors(
        success: Color(0xFF3C7660),
        warning: Color(0xFF916420),
      );
}

/// Neutral surfaces keep the artwork prominent. Blue is reserved for actions.
class AppTheme {
  static const seedColor = Color(0xFF35667A);
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    ).copyWith(
      primary: dark ? const Color(0xFFA0CCDF) : seedColor,
      onPrimary: dark ? const Color(0xFF103442) : Colors.white,
      primaryContainer:
          dark ? const Color(0xFF273E49) : const Color(0xFFE1EBF0),
      onPrimaryContainer:
          dark ? const Color(0xFFD0E9F3) : const Color(0xFF244A5C),
      secondaryContainer:
          dark ? const Color(0xFF2B353D) : const Color(0xFFE7ECEE),
      onSecondaryContainer:
          dark ? const Color(0xFFD6E1E6) : const Color(0xFF344B56),
      surface: dark ? const Color(0xFF171B1F) : const Color(0xFFFAFAF8),
      surfaceContainerLowest: dark ? const Color(0xFF121619) : Colors.white,
      surfaceContainerLow:
          dark ? const Color(0xFF1E2328) : const Color(0xFFF3F4F2),
      surfaceContainer:
          dark ? const Color(0xFF23292E) : const Color(0xFFEDEFED),
      surfaceContainerHigh:
          dark ? const Color(0xFF2B3238) : const Color(0xFFE6EAE8),
      surfaceContainerHighest:
          dark ? const Color(0xFF353D44) : const Color(0xFFDBE1DE),
      onSurface: dark ? const Color(0xFFE8EDF0) : const Color(0xFF20282D),
      onSurfaceVariant:
          dark ? const Color(0xFFADB7BF) : const Color(0xFF5B6870),
      outline: dark ? const Color(0xFF74838D) : const Color(0xFF75828A),
      outlineVariant: dark ? const Color(0xFF354049) : const Color(0xFFD7DEDD),
    );
    final text = ThemeData(brightness: brightness).textTheme
        .apply(
          fontFamily: 'Segoe UI',
          fontFamilyFallback: const [
            'Microsoft YaHei UI',
            'Microsoft YaHei',
            'sans-serif',
          ],
          bodyColor: colors.onSurface,
          displayColor: colors.onSurface,
        )
        .copyWith(
          headlineMedium: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.6,
          ),
          headlineSmall: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
          ),
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
          titleMedium: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
          titleSmall: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: const TextStyle(fontSize: 15, height: 1.6),
          bodyMedium: const TextStyle(fontSize: 14, height: 1.5),
          bodySmall: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: colors.onSurfaceVariant,
          ),
          labelLarge: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          labelMedium: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'sans-serif',
      ],
      textTheme: text,
      scaffoldBackgroundColor: colors.surface,
      extensions: [
        NovaSemanticColors(
          success: dark ? const Color(0xFF91CBB3) : const Color(0xFF3C7660),
          warning: dark ? const Color(0xFFE0BE83) : const Color(0xFF916420),
        ),
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 28,
        toolbarHeight: 76,
        titleTextStyle: text.headlineSmall?.copyWith(color: colors.onSurface),
      ),
      cardTheme: CardTheme(
        color: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shape,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: shape,
          minimumSize: const Size(64, 42),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: shape,
          elevation: 0,
          backgroundColor: colors.primary,
          foregroundColor: colors.onPrimary,
          minimumSize: const Size(64, 42),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: shape,
          side: BorderSide(color: colors.outlineVariant),
          minimumSize: const Size(64, 42),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: shape),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
        hintStyle: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: colors.secondaryContainer,
        side: BorderSide(color: colors.outlineVariant),
        shape: shape,
        labelStyle: text.labelLarge?.copyWith(color: colors.onSurfaceVariant),
        showCheckmark: false,
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.primary,
        linearTrackColor: colors.surfaceContainerHighest,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colors.primary,
        thumbColor: colors.primary,
        inactiveTrackColor: colors.surfaceContainerHighest,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.inverseSurface,
          borderRadius: BorderRadius.circular(4),
        ),
        textStyle: text.bodySmall?.copyWith(color: colors.onInverseSurface),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceContainerHigh,
        shape: shape,
      ),
      dialogTheme: DialogTheme(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: colors.onInverseSurface,
        ),
        behavior: SnackBarBehavior.floating,
        shape: shape,
      ),
    );
  }
}
