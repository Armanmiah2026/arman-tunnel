import 'dart:typed_data';

import 'package:flutter/material.dart';

/// SnapDark Tunnel design tokens — "Violet Pulse" palette.
///
/// Single source of truth for every colour, radius, gap and motion duration in
/// the app. Widgets never hardcode a hex value or a magic padding: they read
/// `context.tokens` (this class, exposed as a [ThemeExtension]) so dark/light
/// resolve automatically and the palette cannot drift between screens.
///
/// Brand rule (hard requirement): the palette is **violet / lavender only** —
/// deep near-black violet surfaces with a #7C3AED primary. Emerald carries
/// success, amber caution, and rose every negative state: no other hues appear
/// anywhere in the UI.
@immutable
class SnapDarkTokens extends ThemeExtension<SnapDarkTokens> {
  // ---- Surfaces ----
  /// Page background.
  final Color bg;

  /// Glass mode: absolute path of the wallpaper behind the UI ('' = off).
  /// Cards render translucent when this is set, so the wallpaper shows
  /// through while text keeps its contrast.
  final String wallpaperPath;
  final Uint8List? wallpaperBytes;

  /// Glass tuning (meaningful only when [wallpaperPath] is set).
  final double wallpaperDim;
  final double wallpaperBlur;
  final double wallpaperCardOpacity;

  /// Secondary page background, used for the top of the page gradient.
  final Color bgAlt;

  /// Default card / panel fill.
  final Color surface;

  /// Raised or selected panel fill (rows inside a card, inputs).
  final Color surfaceAlt;

  /// Highest panel fill (menus, sheets, tooltips).
  final Color surfaceHigh;

  /// Hairline around panels.
  final Color border;

  /// Border for focused / selected panels.
  final Color borderStrong;

  // ---- Brand ----
  /// Primary violet — the single accent of the app (Violet Pulse).
  final Color accent;

  /// Electric lavender highlight, for titles and secondary emphasis.
  final Color lime;

  /// Deeper violet, used for "connected" and for gradients.
  final Color accentDeep;

  /// Bright lavender, used for transient states (connecting) and glows.
  final Color accentBright;

  /// Readable foreground on top of [accent].
  final Color onAccent;

  /// Translucent accent wash for selected rows and chips.
  final Color accentWash;

  /// Stronger accent wash for pressed / active surfaces.
  final Color accentWashStrong;

  // ---- Status (emerald / amber / rose — nothing else) ----
  /// Success / healthy.
  final Color success;

  /// Caution — softer than [alert].
  final Color warning;

  /// Errors, failures and disconnect.
  final Color alert;

  // ---- Text ----
  final Color text;
  final Color textSecondary;
  final Color textMuted;

  /// Foreground for text drawn on a light-on-dark inversion.
  final Color textInverse;

  /// True when the dark palette is active.
  final bool isDark;

  const SnapDarkTokens({
    required this.bg,
    required this.bgAlt,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceHigh,
    required this.border,
    required this.borderStrong,
    required this.accent,
    required this.lime,
    required this.accentDeep,
    required this.accentBright,
    required this.onAccent,
    required this.accentWash,
    required this.accentWashStrong,
    required this.success,
    required this.warning,
    required this.alert,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textInverse,
    required this.isDark,
    this.wallpaperPath = '',
    this.wallpaperBytes,
    this.wallpaperDim = 0.35,
    this.wallpaperBlur = 0.0,
    this.wallpaperCardOpacity = 0.55,
  });

  // ===========================================================================
  // Palettes
  // ===========================================================================

  /// Near-black + neon-violet palette (default) — Violet Pulse dark.
  static const SnapDarkTokens dark = SnapDarkTokens(
    bg: Color(0xFF0B0913),
    bgAlt: Color(0xFF120E1F),
    surface: Color(0xFF171226),
    surfaceAlt: Color(0xFF1E1733),
    surfaceHigh: Color(0xFF251D3F),
    border: Color(0xFF2C2447),
    borderStrong: Color(0xFF3E3563),
    accent: Color(0xFF7C3AED),
    lime: Color(0xFFC084FC),
    accentDeep: Color(0xFF5B21B6),
    accentBright: Color(0xFFA78BFA),
    onAccent: Color(0xFFFFFFFF),
    accentWash: Color(0x1A7C3AED),
    accentWashStrong: Color(0x337C3AED),
    success: Color(0xFF10B981),
    warning: Color(0xFFFBBF24),
    alert: Color(0xFFFB7185),
    text: Color(0xFFF4F1FB),
    textSecondary: Color(0xFFA9A0C4),
    textMuted: Color(0xFF6F6792),
    textInverse: Color(0xFF120E1F),
    isDark: true,
  );

  /// Clean violet-on-white light palette. Violet is darkened so text and icons
  /// keep a readable contrast ratio on white.
  static const SnapDarkTokens light = SnapDarkTokens(
    bg: Color(0xFFFAF8FF),
    bgAlt: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF2EEFC),
    surfaceHigh: Color(0xFFE9E3FA),
    border: Color(0xFFE2DAF6),
    borderStrong: Color(0xFFC4B5F0),
    accent: Color(0xFF6D28D9),
    lime: Color(0xFF7C3AED),
    accentDeep: Color(0xFF5B21B6),
    accentBright: Color(0xFF8B5CF6),
    onAccent: Color(0xFFFFFFFF),
    accentWash: Color(0x146D28D9),
    accentWashStrong: Color(0x296D28D9),
    success: Color(0xFF059669),
    warning: Color(0xFFB45309),
    alert: Color(0xFFE11D48),
    text: Color(0xFF16121F),
    textSecondary: Color(0xFF4A4460),
    textMuted: Color(0xFF6B6685),
    textInverse: Color(0xFFFFFFFF),
    isDark: false,
  );

  // ===========================================================================
  // Derived paint
  // ===========================================================================

  /// Glass mode flag.
  bool get glass => wallpaperPath.isNotEmpty;

  /// Page background gradient. Fully transparent in glass mode: the root
  /// wallpaper layer already applies the (user-tuned) dim scrim, so pages
  /// must not stack a second wash on top — the wallpaper stays as visible
  /// as the Dim slider says, nothing more.
  List<Color> get pageGradient =>
      glass ? const [Colors.transparent, Colors.transparent] : [bgAlt, bg];

  /// Card fill. Glass mode uses a light scrim so the wallpaper stays clearly
  /// visible behind cards while text keeps contrast.
  ///
  /// LIGHT palette floor: white at the default 55% over a bright wallpaper
  /// washes the dark text out into a haze — the floor keeps the cards
  /// readable panels (the wallpaper stays visible in the gaps, margins and
  /// translucent pages). Dark keeps the raw knob: its near-black fill has
  /// the opposite problem and low opacity over any photo stays readable.
  Color get surfaceFill {
    if (!glass) return surface;
    final o = isDark
        ? wallpaperCardOpacity
        : wallpaperCardOpacity.clamp(0.60, 1.0);
    return surface.withValues(alpha: o);
  }

  /// Secondary fill (nested surfaces). Same light-mode floor reasoning —
  /// nested rows sit ON a card, so they need at least the card's body.
  Color get surfaceAltFill {
    if (!glass) return surfaceAlt;
    final o = isDark
        ? wallpaperCardOpacity
        : (wallpaperCardOpacity * 1.0).clamp(0.66, 1.0);
    return surfaceAlt.withValues(alpha: o);
  }

  /// Scaffold background. Transparent in glass mode.
  Color get scaffoldBg => glass ? Colors.transparent : bg;

  /// Gradient for hero panels and headers. Glass mode uses the translucent
  /// fills so hero surfaces (the idle dial, header panels) show the
  /// wallpaper instead of painting an opaque slab over it.
  List<Color> get heroGradient => glass
      ? [surfaceAltFill, surfaceFill]
      : (isDark
          ? [const Color(0xFF1B1433), const Color(0xFF0E0B1A)]
          : [surface, surfaceAlt]);

  /// Gradient used on the accent CTA and the connect dial.
  List<Color> get accentGradient => [accent, isDark ? lime : accentBright];

  /// Glow used behind active elements.
  Color glow(double opacity) => accent.withValues(alpha: opacity);

  /// Colour for the given connection status, so every screen agrees.
  Color statusColor({required bool connected, required bool busy}) =>
      connected ? accent : (busy ? accentBright : textMuted);

  // ===========================================================================
  // Geometry & motion (const, palette independent)
  // ===========================================================================

  /// 4pt spacing scale.
  static const double gapXs = 4;
  static const double gapSm = 8;
  static const double gapMd = 12;
  static const double gap = 16;
  static const double gapLg = 20;
  static const double gapXl = 24;
  static const double gapXxl = 32;

  /// Horizontal page inset used by every screen body.
  static const double pageInset = 16;

  /// Corner radii.
  static const double radiusSm = 10;
  static const double radiusMd = 14;
  static const double radiusLg = 18;
  static const double radiusXl = 24;
  static const double radiusPill = 999;

  static BorderRadius get brSm => BorderRadius.circular(radiusSm);
  static BorderRadius get brMd => BorderRadius.circular(radiusMd);
  static BorderRadius get brLg => BorderRadius.circular(radiusLg);
  static BorderRadius get brXl => BorderRadius.circular(radiusXl);
  static BorderRadius get brPill => BorderRadius.circular(radiusPill);

  /// Max content width, so the UI stays readable on tablets / landscape.
  static const double maxContentWidth = 620;

  /// Motion durations.
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);

  // ===========================================================================
  // Text helpers
  // ===========================================================================

  /// Tabular / technical figures (speeds, timers, IPs, logs).
  TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w600,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: 'monospace',
        fontSize: size,
        fontWeight: weight,
        color: color ?? text,
        height: height,
        letterSpacing: letterSpacing,
      );

  /// Small uppercase section label.
  TextStyle get overline => TextStyle(
        color: textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      );

  @override
  SnapDarkTokens copyWith({
    String? wallpaperPath,
    Uint8List? wallpaperBytes,
    double? wallpaperDim,
    double? wallpaperBlur,
    double? wallpaperCardOpacity,
    Color? bg,
    Color? bgAlt,
    Color? surface,
    Color? surfaceAlt,
    Color? surfaceHigh,
    Color? border,
    Color? borderStrong,
    Color? accent,
    Color? lime,
    Color? accentDeep,
    Color? accentBright,
    Color? onAccent,
    Color? accentWash,
    Color? accentWashStrong,
    Color? success,
    Color? warning,
    Color? alert,
    Color? text,
    Color? textSecondary,
    Color? textMuted,
    Color? textInverse,
    bool? isDark,
  }) {
    return SnapDarkTokens(
      wallpaperPath: wallpaperPath ?? this.wallpaperPath,
      wallpaperBytes: wallpaperBytes ?? this.wallpaperBytes,
      wallpaperDim: wallpaperDim ?? this.wallpaperDim,
      wallpaperBlur: wallpaperBlur ?? this.wallpaperBlur,
      wallpaperCardOpacity: wallpaperCardOpacity ?? this.wallpaperCardOpacity,
      bg: bg ?? this.bg,
      bgAlt: bgAlt ?? this.bgAlt,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      accent: accent ?? this.accent,
      lime: lime ?? this.lime,
      accentDeep: accentDeep ?? this.accentDeep,
      accentBright: accentBright ?? this.accentBright,
      onAccent: onAccent ?? this.onAccent,
      accentWash: accentWash ?? this.accentWash,
      accentWashStrong: accentWashStrong ?? this.accentWashStrong,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      alert: alert ?? this.alert,
      text: text ?? this.text,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      textInverse: textInverse ?? this.textInverse,
      isDark: isDark ?? this.isDark,
    );
  }

  @override
  SnapDarkTokens lerp(ThemeExtension<SnapDarkTokens>? other, double t) {
    if (other is! SnapDarkTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return SnapDarkTokens(
      wallpaperPath: t < 0.5 ? wallpaperPath : other.wallpaperPath,
      wallpaperBytes: t < 0.5 ? wallpaperBytes : other.wallpaperBytes,
      wallpaperDim: wallpaperDim + (other.wallpaperDim - wallpaperDim) * t,
      wallpaperBlur: wallpaperBlur + (other.wallpaperBlur - wallpaperBlur) * t,
      wallpaperCardOpacity: wallpaperCardOpacity +
          (other.wallpaperCardOpacity - wallpaperCardOpacity) * t,
      bg: c(bg, other.bg),
      bgAlt: c(bgAlt, other.bgAlt),
      surface: c(surface, other.surface),
      surfaceAlt: c(surfaceAlt, other.surfaceAlt),
      surfaceHigh: c(surfaceHigh, other.surfaceHigh),
      border: c(border, other.border),
      borderStrong: c(borderStrong, other.borderStrong),
      accent: c(accent, other.accent),
      lime: c(lime, other.lime),
      accentDeep: c(accentDeep, other.accentDeep),
      accentBright: c(accentBright, other.accentBright),
      onAccent: c(onAccent, other.onAccent),
      accentWash: c(accentWash, other.accentWash),
      accentWashStrong: c(accentWashStrong, other.accentWashStrong),
      success: c(success, other.success),
      warning: c(warning, other.warning),
      alert: c(alert, other.alert),
      text: c(text, other.text),
      textSecondary: c(textSecondary, other.textSecondary),
      textMuted: c(textMuted, other.textMuted),
      textInverse: c(textInverse, other.textInverse),
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }
}

/// `context.tokens` — the only way widgets should reach a colour.
///
/// Falls back to the dark palette when used outside a themed subtree (e.g. in a
/// bare `showDialog` builder during tests).
extension SnapDarkTokensX on BuildContext {
  SnapDarkTokens get tokens =>
      Theme.of(this).extension<SnapDarkTokens>() ?? SnapDarkTokens.dark;
}
