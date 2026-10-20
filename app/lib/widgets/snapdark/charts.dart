import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/snapdark_theme.dart';

/// Tiny line chart for ping history. Draws nothing below two samples.
class SnapDarkSparkline extends StatelessWidget {
  final List<double> points;
  final Color color;
  final Size size;

  /// Fill the area under the line with a fading gradient.
  final bool filled;

  const SnapDarkSparkline({
    super.key,
    required this.points,
    required this.color,
    this.size = const Size(48, 18),
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: size,
      painter: _SparklinePainter(
        points: points,
        color: color,
        filled: filled,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> points;
  final Color color;
  final bool filled;

  _SparklinePainter({
    required this.points,
    required this.color,
    required this.filled,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final minVal = points.reduce(math.min) - 4;
    final maxVal = points.reduce(math.max) + 4;
    final range = math.max(maxVal - minVal, 1.0);
    final stepX = size.width / (points.length - 1);

    final line = Path();
    for (var i = 0; i < points.length; i++) {
      final x = i * stepX;
      final y = size.height - ((points[i] - minVal) / range) * size.height;
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }

    if (filled) {
      final area = Path.from(line)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0)],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
      );
    }

    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter o) =>
      o.points != points || o.color != color || o.filled != filled;
}

/// 4-bar signal strength indicator.
class SnapDarkSignalBars extends StatelessWidget {
  /// 0..4 filled bars.
  final int strength;
  final Color? color;

  /// Responsive shrink factor (dashboard scaling on small screens).
  final double scale;

  const SnapDarkSignalBars({
    super.key,
    required this.strength,
    this.color,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return CustomPaint(
      size: Size(20 * scale, 16 * scale),
      painter: _SignalBarsPainter(
        strength: strength,
        on: color ?? t.accent,
        off: t.border,
        scale: scale,
      ),
    );
  }
}

class _SignalBarsPainter extends CustomPainter {
  final int strength;
  final Color on;
  final Color off;

  /// Bar geometry is drawn in the reference 20x16 box and scaled with the
  /// canvas, so the indicator keeps its exact proportions at any size.
  final double scale;

  _SignalBarsPainter({
    required this.strength,
    required this.on,
    required this.off,
    this.scale = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(scale, scale);
    const heights = [0.35, 0.56, 0.78, 1.0];
    const barWidth = 3.0;
    const spacing = 2.0;
    final startX =
        (20 - (heights.length * barWidth + 3 * spacing)) / 2;
    final paint = Paint()..isAntiAlias = true;
    for (var i = 0; i < heights.length; i++) {
      final h = 16 * heights[i];
      paint.color = (i + 1) <= strength ? on : off;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(startX + i * (barWidth + spacing), 16 - h,
              barWidth, h),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SignalBarsPainter o) =>
      o.strength != strength ||
      o.on != on ||
      o.off != off ||
      o.scale != scale;
}
