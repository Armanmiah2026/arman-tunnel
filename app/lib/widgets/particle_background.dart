import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/sensei_theme.dart';

/// Animated particle-network background used by the splash screen.
///
/// Deliberately cheap: one ticker, O(n²) neighbour pass over <= 90 points, and a
/// [RepaintBoundary] so it never invalidates the widgets above it.
class ParticleBackground extends StatefulWidget {
  /// Pixels² per particle — higher means *fewer* particles.
  final int density;
  final Widget? child;

  const ParticleBackground({super.key, this.density = 9000, this.child});

  @override
  State<ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<ParticleBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final List<_Particle> _particles = [];
  final Random _rng = Random();
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  void _seed(Size size, List<Color> palette) {
    if (_size == size && _particles.isNotEmpty) return;
    _size = size;
    _particles.clear();
    var count = (size.width * size.height / widget.density).round();
    count = count.clamp(22, 90);
    for (var i = 0; i < count; i++) {
      _particles.add(_Particle(
        x: _rng.nextDouble() * size.width,
        y: _rng.nextDouble() * size.height,
        dx: _rng.nextDouble() * 0.4 - 0.2,
        dy: _rng.nextDouble() * 0.4 - 0.2,
        radius: _rng.nextDouble() * 1.8 + 0.6,
        color: palette[_rng.nextInt(palette.length)],
        opacity: _rng.nextDouble() * 0.45 + 0.25,
      ));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Green/lime ramp only — the brand forbids cyan/blue accents.
    final palette = [t.accent, t.accentBright, t.lime, t.accentDeep];
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _seed(size, palette);
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (_, __) {
                  for (final p in _particles) {
                    p.step(size);
                  }
                  return CustomPaint(
                    painter: _ParticlePainter(
                      particles: _particles,
                      linkColor: t.accent,
                    ),
                    size: size,
                  );
                },
              ),
            ),
            if (widget.child != null) widget.child!,
          ],
        );
      },
    );
  }
}

class _Particle {
  double x, y, dx, dy, radius, opacity;
  final Color color;

  _Particle({
    required this.x,
    required this.y,
    required this.dx,
    required this.dy,
    required this.radius,
    required this.color,
    required this.opacity,
  });

  void step(Size bounds) {
    if (x + radius > bounds.width || x - radius < 0) dx = -dx;
    if (y + radius > bounds.height || y - radius < 0) dy = -dy;
    x += dx;
    y += dy;
  }
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final Color linkColor;

  _ParticlePainter({required this.particles, required this.linkColor});

  @override
  void paint(Canvas canvas, Size size) {
    final maxDistSq = (size.width / 7) * (size.height / 7);
    final line = Paint()
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;

    for (var a = 0; a < particles.length; a++) {
      final pa = particles[a];
      for (var b = a + 1; b < particles.length; b++) {
        final pb = particles[b];
        final dx = pa.x - pb.x;
        final dy = pa.y - pb.y;
        final distSq = dx * dx + dy * dy;
        if (distSq >= maxDistSq) continue;
        final op = (1 - distSq / maxDistSq).clamp(0.0, 1.0) * 0.28;
        line.color = linkColor.withValues(alpha: op);
        canvas.drawLine(Offset(pa.x, pa.y), Offset(pb.x, pb.y), line);
      }
    }

    final dot = Paint()..style = PaintingStyle.fill;
    for (final p in particles) {
      dot.color = p.color.withValues(alpha: p.opacity);
      canvas.drawCircle(Offset(p.x, p.y), p.radius, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}
