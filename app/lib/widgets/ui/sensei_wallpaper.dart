import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/sensei_theme.dart';

/// Full-screen wallpaper layer painted at the ROOT of the app (inside
/// `MaterialApp.builder`), so it sits behind the whole Navigator — tabs AND
/// pushed routes — instead of only behind the shell's IndexedStack.
///
/// Rendering order matches the preview in the Wallpaper sheet exactly:
/// image (cover, edge to edge) → optional gaussian blur → theme-aware dim
/// scrim. Pages paint nothing on top (`pageGradient` is transparent in glass
/// mode), so the wallpaper's visibility is controlled by ONE dim knob.
class SenseiWallpaperLayer extends StatelessWidget {
  const SenseiWallpaperLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (!t.glass) return const SizedBox.shrink();
    // Decode at screen resolution, not sensor resolution: a 12MP photo is
    // ~48 MB as raw RGBA, which this full-screen layer would keep resident
    // forever. `cacheWidth` downsamples during decode (~8 MB at 1080p) with
    // no visible loss under the cover fit + optional blur.
    final cacheWidth =
        (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context))
            .round();
    final bytes = t.wallpaperBytes;
    Widget image = bytes == null
        ? ColoredBox(color: t.bg)
        : Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: cacheWidth,
            errorBuilder: (_, __, ___) => ColoredBox(color: t.bg),
          );
    if (t.wallpaperBlur > 0) {
      image = ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: t.wallpaperBlur,
          sigmaY: t.wallpaperBlur,
        ),
        child: image,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        // DIM = darkness, in BOTH themes: a black scrim whose opacity is
        // the user's Dim knob. (The old theme-aware colour made light mode
        // BRIGHTEN as Dim rose — a white scrim over a light wallpaper.)
        ColoredBox(color: Colors.black.withValues(alpha: t.wallpaperDim)),
      ],
    );
  }
}
