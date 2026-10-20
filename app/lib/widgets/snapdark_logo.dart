import 'package:flutter/material.dart';

import '../theme/snapdark_theme.dart';

/// The app's brand mark: the transparent SnapDark emblem PNG.
///
/// Use this anywhere the *app itself* is being represented (splash, drawer
/// header, about screen/dialog) instead of a generic `Icons.shield_rounded`.
/// Material icons stay reserved for protocol/feature rows.
///
/// The asset is lime artwork on full transparency, so it is never placed on the
/// lime accent gradient — that would erase it. With [glow] on, a soft accent
/// halo sits behind the transparent mark instead of a filled plate, which keeps
/// the cut-out silhouette visible in both themes.
class SnapDarkLogo extends StatelessWidget {
  /// Side length of the logo box, in logical pixels.
  final double size;

  /// Paint the soft accent halo behind the mark.
  final bool glow;

  const SnapDarkLogo({super.key, this.size = 96, this.glow = true});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final mark = Image.asset(
      'assets/images/snapdark_mark.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'SnapDark Tunnel',
    );
    if (!glow) return mark;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Radial bloom, not a plate: the mark is transparent, so anything
          // opaque behind it would swallow the artwork.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    t.accent.withValues(alpha: 0.30),
                    t.accent.withValues(alpha: 0.10),
                    t.accent.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.55, 1],
                ),
              ),
            ),
          ),
          mark,
        ],
      ),
    );
  }
}
