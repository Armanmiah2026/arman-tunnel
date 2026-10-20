import 'package:flutter/material.dart';

import '../theme/snapdark_tokens.dart';

/// A country marker drawn WITHOUT emoji — Android fonts often render regional
/// flag glyphs as letter pairs or missing-glyph boxes. This renders a rounded,
/// brand-tinted chip carrying the ISO-2 code (e.g. "BD"), falling back to a
/// Material [fallback] icon when the code is blank or not a clean 2-letter
/// alpha code.
class GeoGlyph extends StatelessWidget {
  const GeoGlyph({
    super.key,
    required this.iso,
    this.size = 20,
    this.color,
    this.fallback = Icons.public_rounded,
  });

  /// Upper/lower-case country code or free text; only a clean 2-letter alpha
  /// `[A-Za-z]` code gets the chip, everything else shows the fallback icon.
  final String? iso;
  final double size;
  final Color? color;
  final IconData fallback;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final code = iso?.trim().toUpperCase() ?? '';
    final valid = code.length == 2 && RegExp(r'^[A-Z]{2}$').hasMatch(code);
    if (!valid) {
      return Icon(fallback, size: size, color: color ?? t.textMuted);
    }
    final c = color ?? t.accent;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: size * 0.34,
        vertical: size * 0.12,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(color: c.withValues(alpha: 0.32)),
      ),
      child: Text(
        code,
        style: TextStyle(
          color: c,
          fontSize: size * 0.48,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}