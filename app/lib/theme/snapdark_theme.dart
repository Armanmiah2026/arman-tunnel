import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'snapdark_tokens.dart';

export 'snapdark_scale.dart';
export 'snapdark_tokens.dart';

/// Builds the app's [ThemeData] from [SnapDarkTokens].
///
/// Everything a Material widget resolves on its own — AppBar, Card, Switch,
/// TextField, Dialog, SnackBar, BottomSheet — is configured here once, so
/// screens can use plain Material widgets and still look native to the brand
/// without repeating decoration code.
class SnapDarkTheme {
  const SnapDarkTheme._();

  static ThemeData get dark => buildFor(SnapDarkTokens.dark);
  static ThemeData get light => buildFor(SnapDarkTokens.light);

  /// Public entry point: the app root decorates the base palette with the
  /// wallpaper (glass) knobs from [SettingsProvider] and rebuilds the theme
  /// through this, so EVERY Material surface — Scaffold backgrounds, dialogs,
  /// sheets, menus — goes translucent together with the cards when Wallpaper
  /// Mode is active, and stays exactly as before when it is off.
  static ThemeData buildFor(SnapDarkTokens t) {
    final scheme = ColorScheme(
      brightness: t.isDark ? Brightness.dark : Brightness.light,
      primary: t.accent,
      onPrimary: t.onAccent,
      primaryContainer: t.accentWashStrong,
      onPrimaryContainer: t.accent,
      secondary: t.lime,
      onSecondary: t.isDark ? t.onAccent : Colors.white,
      secondaryContainer: t.accentWash,
      onSecondaryContainer: t.accent,
      // No red in the brand: errors are amber.
      error: t.alert,
      onError: t.isDark ? t.onAccent : Colors.white,
      errorContainer: t.alert.withValues(alpha: 0.16),
      onErrorContainer: t.alert,
      surface: t.surfaceFill,
      onSurface: t.text,
      surfaceContainerHighest: t.surfaceAltFill,
      onSurfaceVariant: t.textSecondary,
      outline: t.border,
      outlineVariant: t.borderStrong,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: t.text,
      onInverseSurface: t.bg,
      inversePrimary: t.accentDeep,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      // Transparent in glass mode so the root wallpaper layer shows through
      // any Scaffold that does not paint its own background.
      scaffoldBackgroundColor: t.scaffoldBg,
      canvasColor: t.scaffoldBg,
      dividerColor: t.border,
      splashFactory: InkSparkle.splashFactory,
      extensions: <ThemeExtension<dynamic>>[t],

      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: t.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: SnapDarkTokens.gap,
        iconTheme: IconThemeData(color: t.text, size: 22),
        actionsIconTheme: IconThemeData(color: t.accent, size: 22),
        titleTextStyle: TextStyle(
          color: t.text,
          fontSize: 19,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),

      cardTheme: CardThemeData(
        // Glass-aware: translucent over the wallpaper instead of opaque.
        color: t.surfaceFill,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: SnapDarkTokens.brLg,
          side: BorderSide(color: t.border),
        ),
      ),

      drawerTheme: DrawerThemeData(
        backgroundColor: t.glass ? Colors.transparent : t.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        scrimColor: Colors.black.withValues(alpha: t.isDark ? 0.66 : 0.48),
        elevation: 0,
        shape: const RoundedRectangleBorder(),
      ),

      dialogTheme: DialogThemeData(
        // Glass mode: translucent fill (same treatment as cards) so the
        // wallpaper reads through dialogs; the hairline keeps the edge.
        backgroundColor: t.surfaceFill,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: SnapDarkTokens.brXl,
          side: BorderSide(color: t.border),
        ),
        titleTextStyle: TextStyle(
          color: t.text,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
        contentTextStyle: TextStyle(
          color: t.textSecondary,
          fontSize: 14,
          height: 1.45,
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surfaceFill,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: t.surfaceFill,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: t.borderStrong,
        dragHandleSize: const Size(38, 4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(SnapDarkTokens.radiusXl),
          ),
        ),
      ),

      popupMenuTheme: PopupMenuThemeData(
        // Glass mode: translucent like the cards. Non-glass keeps the
        // original raised-panel colour (surfaceHigh, NOT surface).
        color: t.glass ? t.surfaceFill : t.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: SnapDarkTokens.brMd,
          side: BorderSide(color: t.border),
        ),
        textStyle: TextStyle(color: t.text, fontSize: 14),
      ),

      listTileTheme: ListTileThemeData(
        iconColor: t.accent,
        textColor: t.text,
        titleTextStyle: TextStyle(
          color: t.text,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: TextStyle(color: t.textMuted, fontSize: 12.5),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: SnapDarkTokens.gap,
          vertical: 2,
        ),
        minVerticalPadding: 10,
        shape: RoundedRectangleBorder(borderRadius: SnapDarkTokens.brMd),
      ),

      iconTheme: IconThemeData(color: t.textSecondary, size: 22),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          disabledBackgroundColor: t.surfaceAlt,
          disabledForegroundColor: t.textMuted,
          elevation: 0,
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: SnapDarkTokens.gapXl),
          shape: RoundedRectangleBorder(borderRadius: SnapDarkTokens.brMd),
          textStyle: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: t.onAccent,
          disabledBackgroundColor: t.surfaceAlt,
          disabledForegroundColor: t.textMuted,
          minimumSize: const Size(0, 50),
          shape: RoundedRectangleBorder(borderRadius: SnapDarkTokens.brMd),
          textStyle: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.accent,
          disabledForegroundColor: t.textMuted,
          minimumSize: const Size(0, 48),
          side: BorderSide(color: t.border),
          shape: RoundedRectangleBorder(borderRadius: SnapDarkTokens.brMd),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.accent,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: t.textSecondary,
          highlightColor: t.accentWash,
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        extendedTextStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
        shape: RoundedRectangleBorder(borderRadius: SnapDarkTokens.brMd),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.surfaceAlt,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: SnapDarkTokens.gapMd + 2,
          vertical: SnapDarkTokens.gapMd,
        ),
        hintStyle: TextStyle(color: t.textMuted, fontSize: 13.5),
        labelStyle: TextStyle(color: t.textSecondary, fontSize: 13.5),
        floatingLabelStyle: TextStyle(color: t.accent, fontSize: 13.5),
        prefixIconColor: t.textMuted,
        suffixIconColor: t.textMuted,
        border: OutlineInputBorder(
          borderRadius: SnapDarkTokens.brSm,
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: SnapDarkTokens.brSm,
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: SnapDarkTokens.brSm,
          borderSide: BorderSide(color: t.accent, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: SnapDarkTokens.brSm,
          borderSide: BorderSide(color: t.alert),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: SnapDarkTokens.brSm,
          borderSide: BorderSide(color: t.alert, width: 1.4),
        ),
        errorStyle: TextStyle(color: t.alert, fontSize: 12),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return t.textMuted;
          if (states.contains(WidgetState.selected)) return t.onAccent;
          return t.textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return t.surfaceAltFill;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return t.accent;
          return t.border;
        }),
      ),

      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? t.accent : Colors.transparent),
        checkColor: WidgetStatePropertyAll(t.onAccent),
        side: BorderSide(color: t.borderStrong, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),

      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? t.accent : t.borderStrong),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: t.accent,
        inactiveTrackColor: t.surfaceAltFill,
        thumbColor: t.accent,
        overlayColor: t.accentWash,
        trackHeight: 4,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.accent,
        linearTrackColor: t.surfaceAltFill,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 6,
      ),

      chipTheme: ChipThemeData(
        backgroundColor: t.surfaceAlt,
        selectedColor: t.accentWashStrong,
        side: BorderSide(color: t.border),
        labelStyle: TextStyle(
          color: t.text,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: TextStyle(color: t.accent, fontSize: 12.5),
        padding: const EdgeInsets.symmetric(horizontal: SnapDarkTokens.gapSm),
        shape: RoundedRectangleBorder(borderRadius: SnapDarkTokens.brPill),
      ),

      dividerTheme: DividerThemeData(
        color: t.border,
        thickness: 1,
        space: 1,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: t.surfaceFill,
        contentTextStyle: TextStyle(color: t.text, fontSize: 13.5),
        actionTextColor: t.accent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: SnapDarkTokens.brMd),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: t.surfaceFill,
          borderRadius: SnapDarkTokens.brSm,
          border: Border.all(color: t.border),
        ),
        textStyle: TextStyle(color: t.text, fontSize: 12),
      ),

      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(t.borderStrong),
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(4),
      ),

      splashColor: t.accentWash,
      highlightColor: t.accentWash,
    );

    return base.copyWith(textTheme: _textTheme(base.textTheme, t));
  }

  /// Nunito everywhere. `google_fonts` degrades to the platform font when it
  /// cannot fetch/serve the asset, so this is safe offline.
  static TextTheme _textTheme(TextTheme base, SnapDarkTokens t) {
    final nunito = GoogleFonts.nunitoTextTheme(base);
    return nunito
        .copyWith(
          displaySmall: nunito.displaySmall?.copyWith(fontWeight: FontWeight.w800),
          headlineMedium:
              nunito.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
          headlineSmall: nunito.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.1,
          ),
          titleLarge: nunito.titleLarge?.copyWith(
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
          titleMedium: nunito.titleMedium?.copyWith(
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
          ),
          titleSmall: nunito.titleSmall?.copyWith(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
          bodyLarge: nunito.bodyLarge?.copyWith(fontSize: 15, height: 1.4),
          bodyMedium: nunito.bodyMedium?.copyWith(fontSize: 13.5, height: 1.45),
          bodySmall: nunito.bodySmall?.copyWith(
            fontSize: 12,
            height: 1.4,
            color: t.textSecondary,
          ),
          labelLarge: nunito.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
          labelMedium: nunito.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: t.textSecondary,
          ),
          labelSmall: nunito.labelSmall?.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: t.textMuted,
            letterSpacing: 0.4,
          ),
        )
        .apply(bodyColor: t.text, displayColor: t.text);
  }
}
