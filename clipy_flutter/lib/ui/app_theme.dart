import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppAppearance extends ChangeNotifier {
  AppAppearance._();
  static final instance = AppAppearance._();
  ThemeMode mode = ThemeMode.system;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('appearance');
    mode = ThemeMode.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setMode(ThemeMode next) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appearance', next.name);
    mode = next;
    notifyListeners();
  }
}

abstract final class ClipyTheme {
  static const blue = Color(0xFF0A6CFF);

  /// Windows V3 palette and compact Fluent-style controls.
  static ThemeData windows(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      platform: TargetPlatform.windows,
      splashFactory: NoSplash.splashFactory,
      fontFamily: 'Segoe UI',
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xFF0A6CFF),
            brightness: brightness,
          ).copyWith(
            primary: dark ? const Color(0xFF4C9BFF) : const Color(0xFF0A6CFF),
            surface: dark ? const Color(0xFF202020) : const Color(0xFFF3F3F3),
            onPrimary: dark ? const Color(0xFF001A3D) : Colors.white,
            onSurface: dark ? Colors.white : const Color(0xFF1A1A1A),
            onSurfaceVariant: dark
                ? const Color(0xFFC5C5C5)
                : const Color(0xFF5D5D5D),
            surfaceContainerLowest: dark
                ? const Color(0xFF2D2D2D)
                : Colors.white,
            surfaceContainerLow: dark
                ? const Color(0xFF292929)
                : const Color(0xFFF9F9F9),
            surfaceContainerHigh: dark
                ? const Color(0xFF2C2C2C)
                : const Color(0xFFFCFCFC),
            outlineVariant: dark
                ? const Color(0xFF383838)
                : const Color(0xFFE5E5E5),
          ),
      scaffoldBackgroundColor: dark
          ? const Color(0xFF202020)
          : const Color(0xFFF3F3F3),
    );
    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: base.scaffoldBackgroundColor,
        foregroundColor: base.colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 48,
        titleTextStyle: TextStyle(
          fontFamily: 'Segoe UI',
          fontSize: 12,
          color: base.colorScheme.onSurface,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: base.colorScheme.onSurface,
        titleTextStyle: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
        subtitleTextStyle: base.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          color: base.colorScheme.onSurfaceVariant,
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(32, 32),
          padding: const EdgeInsets.all(6),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: base.colorScheme.outlineVariant,
        thickness: 1,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          foregroundColor: base.colorScheme.onSurface,
          minimumSize: const Size(32, 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xFF2D2D2D) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: base.colorScheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(32, 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(32, 32),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          side: BorderSide(
            color: base.colorScheme.onSurface.withValues(alpha: .14),
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        prefixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
        filled: true,
        fillColor: dark ? const Color(0xFF2D2D2D) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(
            color: base.colorScheme.onSurface.withValues(alpha: .16),
          ),
        ),
      ),
      textTheme: base.textTheme.copyWith(
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          fontSize: 14,
          height: 1.4,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// HIG semantic surfaces for shared content hosted by the Cupertino shell.
  static ThemeData ios(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final base = build(brightness);
    final background = dark ? Colors.black : const Color(0xFFF2F2F7);
    final surface = dark ? const Color(0xFF1C1C1E) : Colors.white;
    final tint = dark ? const Color(0xFF3D8BFF) : blue;
    return base.copyWith(
      platform: TargetPlatform.iOS,
      scaffoldBackgroundColor: background,
      cupertinoOverrideTheme: CupertinoThemeData(
        brightness: brightness,
        primaryColor: tint,
        scaffoldBackgroundColor: background,
      ),
      colorScheme: base.colorScheme.copyWith(
        primary: tint,
        surface: surface,
        surfaceContainerLowest: surface,
        surfaceContainerLow: dark
            ? const Color(0xFF2C2C2E)
            : const Color(0xFFE9E9EE),
        onSurface: dark ? Colors.white : Colors.black,
        onSurfaceVariant: dark
            ? const Color(0xFFAAAAAF)
            : const Color(0xFF6C6C70),
      ),
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontSize: 34,
          fontWeight: FontWeight.w700,
          letterSpacing: -.7,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      appBarTheme: base.appBarTheme.copyWith(backgroundColor: background),
    );
  }

  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: blue, brightness: brightness)
        .copyWith(
          primary: dark ? const Color(0xFFB0C6FF) : const Color(0xFF1F5FC9),
          onPrimary: dark ? const Color(0xFF002D6C) : Colors.white,
          primaryContainer: dark
              ? const Color(0xFF004398)
              : const Color(0xFFD9E2FF),
          onPrimaryContainer: dark
              ? const Color(0xFFD9E2FF)
              : const Color(0xFF001A43),
          secondaryContainer: dark
              ? const Color(0xFF3F4759)
              : const Color(0xFFDBE2F9),
          onSecondaryContainer: dark
              ? const Color(0xFFDBE2F9)
              : const Color(0xFF141B2C),
          surface: dark ? const Color(0xFF121318) : const Color(0xFFF9F9FF),
          surfaceContainerLowest: dark ? const Color(0xFF0D0E13) : Colors.white,
          surfaceContainerLow: dark
              ? const Color(0xFF1A1B20)
              : const Color(0xFFF3F3FA),
          surfaceContainer: dark
              ? const Color(0xFF1E1F25)
              : const Color(0xFFEDEDF4),
          surfaceContainerHigh: dark
              ? const Color(0xFF292A2F)
              : const Color(0xFFE7E8EE),
          surfaceContainerHighest: dark
              ? const Color(0xFF33353A)
              : const Color(0xFFE2E2E9),
          onSurface: dark ? const Color(0xFFE2E2E9) : const Color(0xFF1A1B20),
          onSurfaceVariant: dark
              ? const Color(0xFFC4C6D0)
              : const Color(0xFF44474F),
          outline: dark ? const Color(0xFF8E9099) : const Color(0xFF74777F),
          outlineVariant: dark
              ? const Color(0xFF44474F)
              : const Color(0xFFC4C6D0),
          tertiary: dark ? const Color(0xFFE6B4F6) : const Color(0xFF7A4E8C),
          tertiaryContainer: dark
              ? const Color(0xFF5F3772)
              : const Color(0xFFFAD8FF),
          onTertiaryContainer: dark
              ? const Color(0xFFFAD8FF)
              : const Color(0xFF30073F),
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: scheme.surface,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: -.2,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w500,
          letterSpacing: -.2,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.5),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: base.scaffoldBackgroundColor,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLowest,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shape,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        elevation: 0,
        height: 76,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          base.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: shape,
        backgroundColor: scheme.surface,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: .55),
        space: 1,
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
