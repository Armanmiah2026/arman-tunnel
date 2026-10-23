import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Majestic golden-lion connect scene — the story told inside the dial.
///
///   connecting → a golden lion sprints along a glowing jungle pathway
///   success    → the lion plants its feet and ROARS; a radiant golden
///                aura wave bursts outward in a circle around it
///   connected  → the lion sprints on, now running with a pride — a deer,
///                a tiger and a leopard — all glowing in the same gold
///
/// Everything is drawn procedurally with [CustomPainter]s: no image assets
/// and no extra packages, so it costs nothing at build time and works
/// fully offline. Two [AnimationController]s drive it:
///
///   _clock – repeating gallop/parallax ticker; runs ONLY while the tunnel
///            is busy or up (battery discipline mirrors the dial itself)
///   _roar  – one-shot burst fired the instant the tunnel connects
///
/// World scroll is accumulated in a running total instead of being read
/// straight from a controller value, so pausing for the roar and resuming
/// afterwards is seamless — the jungle never jumps.
enum LionScenePhase { idle, connecting, roar, connected }

class GoldenLionScene extends StatefulWidget {
  const GoldenLionScene({
    super.key,
    required this.isConnected,
    required this.isConnecting,
  });

  final bool isConnected;
  final bool isConnecting;

  @override
  GoldenLionSceneState createState() => GoldenLionSceneState();
}

class GoldenLionSceneState extends State<GoldenLionScene>
    with TickerProviderStateMixin {
  static const _kRoar = Duration(milliseconds: 1500);
  static const _kGallop = Duration(milliseconds: 900);

  late final AnimationController _clock;
  late final AnimationController _roar;

  /// Accumulated world scroll in scene "cycles" — a running total so the
  /// roar's pause resumes from exactly where the run left off.
  double _scroll = 0;
  double _prevClock = 0;
  double _prevRoar = 0;

  /// Free-running seconds for shimmers and particles (advances mid-roar too).
  double _time = 0;

  /// 0→1 fade for the pride that joins after a successful roar.
  double _companionFade = 0;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: _kGallop)
      ..addListener(_onClockTick);
    _roar = AnimationController(vsync: this, duration: _kRoar)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _sync();
      })
      ..addListener(_onRoarTick);
    if (widget.isConnected) {
      // Restored session (app reopened while already up): show the pride
      // straight away — the roar burst belongs to the fresh-connect moment.
      _companionFade = 1;
    }
    _sync();
  }

  @override
  void didUpdateWidget(covariant GoldenLionScene old) {
    super.didUpdateWidget(old);
    if (widget.isConnected && !old.isConnected) {
      // THE moment: tunnel came up → the lion plants its feet and roars.
      _companionFade = 0;
      _roar.forward(from: 0);
    }
    if (!widget.isConnected && !widget.isConnecting) {
      _companionFade = 0;
    }
    _sync();
  }

  void _onClockTick() {
    var v = _clock.value;
    if (v < _prevClock) _prevClock -= 1.0; // controller wrapped
    final dt = v - _prevClock;
    _prevClock = v;
    _scroll += dt;
    _time += dt * _kGallop.inMilliseconds / 1000;
    if (!_roar.isAnimating && widget.isConnected && _companionFade < 1) {
      _companionFade =
          (_companionFade + dt * _kGallop.inMilliseconds / 600).clamp(0.0, 1.0);
    }
  }

  void _onRoarTick() {
    final v = _roar.value;
    var dt = v - _prevRoar;
    if (dt < 0) dt = v; // reset from 0
    _prevRoar = v;
    _time += dt * _kRoar.inMilliseconds / 1000;
  }

  /// Battery discipline, same rule as the dial itself: a ticker runs only
  /// while the tunnel is actually busy or up — never on an idle dial.
  void _sync() {
    if ((widget.isConnecting || widget.isConnected) && !_roar.isAnimating) {
      if (!_clock.isAnimating) _clock.repeat();
    } else {
      _clock.stop();
    }
  }

  LionScenePhase get phase {
    if (_roar.isAnimating) return LionScenePhase.roar;
    if (widget.isConnected) return LionScenePhase.connected;
    if (widget.isConnecting) return LionScenePhase.connecting;
    return LionScenePhase.idle;
  }

  @override
  void dispose() {
    _clock.dispose();
    _roar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([_clock, _roar]),
        builder: (context, _) {
          final v = _roar.value;
          return CustomPaint(
            painter: _ScenePainter(
              scroll: _scroll,
              time: _time,
              headRaise: _pulse(v, 0, .18, .72, .95),
              jawOpen: _pulse(v, .08, .20, .62, .85),
              aura: v <= 0 || v >= 1 ? 0.0 : ((v - .08) / .84).clamp(0.0, 1.0),
              flash: _pulse(v, .02, .12, .30, .55),
              companions: _companionFade,
            ),
          );
        },
      ),
    );
  }

  /// Smooth 0→1→0 envelope between the given control points.
  static double _pulse(double v, double a, double b, double c, double d) {
    if (v <= a || v >= d) return 0;
    if (v < b) return Curves.easeOutCubic.transform((v - a) / (b - a));
    if (v <= c) return 1;
    return Curves.easeInCubic.transform(1 - (v - c) / (d - c));
  }
}

// =============================================================================
// Palette — scene-local "majestic gold". The scene is a self-contained golden
// illustration dropped into the violet dial; it never leaks into app tokens.
// =============================================================================
abstract final class LionGold {
  static const bright = Color(0xFFFFE89A);
  static const core = Color(0xFFF7C948);
  static const deep = Color(0xFFDE8B22);
  static const shade = Color(0xFF9C5A0E);
}

/// Paints the golden jungle in a 100×100 unit space, scaled to fit.
class _ScenePainter extends CustomPainter {
  const _ScenePainter({
    required this.scroll,
    required this.time,
    required this.headRaise,
    required this.jawOpen,
    required this.aura,
    required this.flash,
    required this.companions,
  });

  /// World scroll in cycles (gallop phase = scroll × strides per cycle).
  final double scroll;

  /// Free-running seconds for shimmers.
  final double time;

  /// 0→1 lion head raise for the roar.
  final double headRaise;

  /// 0→1 jaw gape for the roar.
  final double jawOpen;

  /// 0→1 expanding aura wave.
  final double aura;

  /// 0→1 golden burst flash.
  final double flash;

  /// 0→1 pride fade-in after success.
  final double companions;

  static const double _horizon = 60;
  static const double _pathTop = 66;
  static const double _lionX = 54;
  static const double _groundY = 80;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.shortestSide / 100;
    canvas.save();
    // Center the 100-unit art box; layers may bleed a couple of units.
    canvas.translate((size.width - 100 * u) / 2, (size.height - 100 * u) / 2);
    canvas.scale(u);
    canvas.clipRect(Rect.fromLTWH(-2, -2, 104, 104));

    _sky(canvas);
    _hills(canvas);
    _canopy(canvas);
    _glow(canvas);
    _path(canvas);
    _midTrees(canvas);
    if (companions > 0.01) _pride(canvas);
    _lion(canvas);
    if (aura > 0) _aura(canvas);
    if (flash > 0) _flash(canvas);
    _grass(canvas);
    _fireflies(canvas);
    _vignette(canvas);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScenePainter o) =>
      o.scroll != scroll ||
      o.time != time ||
      o.headRaise != headRaise ||
      o.jawOpen != jawOpen ||
      o.aura != aura ||
      o.flash != flash ||
      o.companions != companions;

  /// Deterministic 0..1 hash — same tree at the same index every frame.
  static double _hash(int i) {
    final x = math.sin(i * 127.1) * 43758.5453;
    return x - x.floorToDouble();
  }

  /// Draws one tileable parallax row across the scene.
  void _parallax(
    Canvas c, {
    required double tile,
    required double speed,
    required void Function(double x, int idx) draw,
  }) {
    final raw = scroll * speed;
    final off = raw % tile;
    final base = raw ~/ tile;
    final count = (108 / tile).ceil() + 1;
    for (var k = -1; k <= count; k++) {
      draw(k * tile - off, base + k);
    }
  }

  void _sky(Canvas c) {
    final rect = Rect.fromLTWH(-4, -4, 112, 112);
    c.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF1E0F03),
            Color(0xFF4A2A07),
            Color(0xFF8A5A12),
            Color(0xFF6B4310),
          ],
          stops: [0, .38, .58, 1],
        ).createShader(rect),
    );
    // Low golden sun haze behind the treeline.
    final sun = Rect.fromCircle(const Offset(64, 50), 30);
    c.drawRect(
      sun,
      Paint()
        ..shader = RadialGradient(
          colors: [
            LionGold.bright.withValues(alpha: .35),
            LionGold.core.withValues(alpha: .12),
            Colors.transparent,
          ],
          stops: const [0, .45, 1],
        ).createShader(sun),
    );
  }

  void _hills(Canvas c) {
    final p = Path()..moveTo(-4, _horizon + 4);
    for (var x = -4.0; x <= 106; x += 4) {
      final shift = scroll * 3;
      final y = _horizon - 1.5 -
          math.sin((x + shift) * 0.09) * 2.6 -
          math.sin((x + shift) * 0.031) * 1.8;
      p.lineTo(x, y);
    }
    p
      ..lineTo(106, _horizon + 6)
      ..lineTo(-4, _horizon + 6)
      ..close();
    c.drawPath(p, Paint()..color = const Color(0xFF3A2109));
  }

  void _canopy(Canvas c) {
    final trunk = Paint()..color = const Color(0xFF2E1A06);
    final leaf = Paint()..color = const Color(0xFF3E2409);
    _parallax(
      c,
      tile: 24,
      speed: 7,
      draw: (x, idx) {
        final h = _hash(idx);
        final top = 40 + h * 6;
        c.drawRect(Rect.fromLTWH(x + 9, top, 2.4 + h, _horizon - top + 3), trunk);
        for (var i = 0; i < 3; i++) {
          c.drawCircle(
            Offset(x + 6 + i * 4.5, top + (i.isEven ? 0 : 3) + h * 2),
            6.5 + _hash(idx * 3 + i) * 3,
            leaf,
          );
        }
      },
    );
  }

  void _midTrees(Canvas c) {
    final trunk = Paint()..color = const Color(0xFF241205);
    final frond = Paint()
      ..color = const Color(0xFF2A1605)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.6;
    final tip = Paint()..color = const Color(0xFF2A1605);
    _parallax(
      c,
      tile: 34,
      speed: 17,
      draw: (x, idx) {
        final h = _hash(idx + 77);
        if (h < 0.45) return; // gaps in the treeline
        final baseX = x + 8 + h * 12;
        final top = 24 + h * 12;
        c.drawRect(Rect.fromLTWH(baseX, top, 3.2, _horizon - top + 6), trunk);
        for (var i = 0; i < 5; i++) {
          final a = -math.pi / 2 + (i - 2) * 0.52;
          final end = Offset(
            baseX + 1.6 + math.cos(a) * 9.5,
            top + math.sin(a) * 8,
          );
          c.drawLine(Offset(baseX + 1.6, top), end, frond);
          c.drawCircle(end, 2.2, tip);
        }
      },
    );
  }

  void _glow(Canvas c) {
    final r = Rect.fromCircle(const Offset(_lionX + 2, _groundY - 12), 44);
    c.drawRect(
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            LionGold.core.withValues(alpha: .22 + companions * .06),
            LionGold.deep.withValues(alpha: .08),
            Colors.transparent,
          ],
          stops: const [0, .55, 1],
        ).createShader(r),
    );
  }

  void _path(Canvas c) {
    final ground = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF8A5A16), Color(0xFF5B340C), Color(0xFF3A2108)],
        stops: [0, .55, 1],
      ).createShader(Rect.fromLTWH(-4, _pathTop, 112, 108 - _pathTop));
    c.drawRect(Rect.fromLTWH(-4, _pathTop, 112, 108 - _pathTop), ground);
    // Glowing rim where the path meets the jungle.
    c.drawLine(
      const Offset(-4, _pathTop),
      const Offset(108, _pathTop),
      Paint()
        ..color = const Color(0x88F3CE7A)
        ..strokeWidth = .9,
    );
    // Centre dashes streaming past — the strongest speed cue.
    final dash = Paint()..color = const Color(0x99F3CE7A);
    final off = (scroll * 46) % 13;
    for (var x = -13.0; x < 112; x += 13) {
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x - off, 77.4, 7, 1.3),
          const Radius.circular(.7),
        ),
        dash,
      );
    }
    // Side streaks at varied depths.
    final streak = Paint()
      ..color = const Color(0x2EF3CE7A)
      ..strokeWidth = .5;
    for (var i = 0; i < 9; i++) {
      final y = _pathTop + 3 + _hash(i * 5) * 17;
      final len = 6 + _hash(i * 9) * 12;
      final speed = 40 + _hash(i) * 30;
      final x = (((_hash(i) * 120) - scroll * speed) % 120 + 120) % 120 - 10;
      c.drawLine(Offset(x, y), Offset(x + len, y), streak);
    }
  }

  void _grass(Canvas c) {
    final blade = Paint()..color = const Color(0xF01A0D03);
    final back = Paint()..color = const Color(0xB3241205);
    _parallax(
      c,
      tile: 9,
      speed: 74,
      draw: (x, idx) {
        for (var i = 0; i < 4; i++) {
          final bx = x + i * 2.3 + _hash(idx * 4 + i) * 1.4;
          final hgt = 5 + _hash(idx * 9 + i) * 8;
          final sway = math.sin(time * 3 + idx + i) * 1.1;
          final p = Path()
            ..moveTo(bx - .9, 102)
            ..quadraticBezierTo(
                bx + sway * .4, 102 - hgt * .6, bx + sway, 102 - hgt)
            ..quadraticBezierTo(
                bx + sway * .5, 102 - hgt * .55, bx + .9, 102)
            ..close();
          c.drawPath(p, i.isEven ? blade : back);
        }
      },
    );
  }

  void _fireflies(Canvas c) {
    for (var i = 0; i < 14; i++) {
      final hx = _hash(i * 3 + 1);
      final hy = _hash(i * 3 + 2);
      final hs = _hash(i * 3 + 3);
      final x = (((hx * 110) - scroll * 3) % 110 + 110) % 110 - 5;
      final y = 24 + hy * 44 + math.sin(time * 1.6 + i) * 2.2;
      final a = (0.30 + 0.5 * math.abs(math.sin(time * 2 + i * 1.7))) *
          (0.5 + hs * 0.5);
      c.drawCircle(
        Offset(x, y),
        0.45 + hs * 0.5,
        Paint()..color = LionGold.bright.withValues(alpha: a),
      );
    }
  }

  void _vignette(Canvas c) {
    final rect = Rect.fromLTWH(-4, -4, 112, 112);
    c.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.08, 0),
          radius: .78,
          colors: [Colors.transparent, const Color(0x66000000)],
          stops: const [.55, 1],
        ).createShader(rect),
    );
  }

  // ---------------------------------------------------------------------------
  // The hero: golden lion. Local origin = ground under its chest, +x forward.
  // ---------------------------------------------------------------------------
  void _lion(Canvas c) {
    c.save();
    c.translate(_lionX, _groundY);
    final gait = scroll * 2.25;
    final stance = headRaise; // 1 = planted for the roar
    final bobY = -math.abs(math.sin(gait * math.pi * 2)) * 1.2 * (1 - stance * .8);
    c.translate(0, bobY);

    // Contact shadow.
    c.drawOval(
      Rect.fromCenter(center: const Offset(0, .7), width: 26, height: 2.6),
      Paint()..color = const Color(0x59140A02),
    );

    // Soft golden aura (blurred silhouette pass — cheap fake glow).
    final glow = Paint()
      ..color = LionGold.core.withValues(alpha: .5)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.6);
    c.drawCircle(const Offset(-1, -12), 9.5, glow);
    c.drawCircle(const Offset(6.5, -12.5), 5.6, glow);
    c.drawCircle(const Offset(-8, -12), 5.8, glow);
    c.drawCircle(const Offset(14.5, -19.5), 4.2, glow);

    void leg(double hx, double phase, Color col, double wUp, double wLo) {
      final p = gait + phase;
      var swing = math.sin(p * math.pi * 2);
      final lift = math.max(0.0, math.cos(p * math.pi * 2));
      swing *= (1 - stance * .92); // settle into a planted stance to roar
      final a = swing * .55 + stance * .06;
      const hy = -11.0;
      final kx = hx + math.sin(a) * 5.3;
      final ky = hy + math.cos(a) * 5.3;
      final b = a - lift * .85 * (1 - stance) + .12 + stance * .04;
      final px = kx + math.sin(b) * 5.1;
      final py = ky + math.cos(b) * 5.1;
      final st = Paint()
        ..color = col
        ..strokeCap = StrokeCap.round;
      st.strokeWidth = wUp;
      c.drawLine(Offset(hx, hy), Offset(kx, ky), st);
      st.strokeWidth = wLo;
      c.drawLine(Offset(kx, ky), Offset(px, py), st);
      c.drawCircle(Offset(px, py), wLo * .6, Paint()..color = col);
    }

    // Far legs first (darker — reads as depth).
    leg(5.0, .62, LionGold.shade, 2.0, 1.5);
    leg(-9.4, .5, LionGold.shade, 2.2, 1.6);

    // Tail, whipping behind.
    final tailSway = math.sin(time * 5) * 2.0 + math.sin(gait * math.pi * 4) * 1.4;
    final tailEnd =
        Offset(-19.5 - stance * 1.5, -25 + tailSway - stance * 3.5);
    c.drawPath(
      Path()
        ..moveTo(-11.8, -13.4)
        ..quadraticBezierTo(-18.5, -17.5 + tailSway * .4, tailEnd.dx, tailEnd.dy),
      Paint()
        ..color = LionGold.deep
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );
    c.drawCircle(tailEnd, 1.7, Paint()..color = LionGold.deep);

    // Body: overlapping blobs read as one muscular silhouette.
    final bodyPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [LionGold.bright, LionGold.core, LionGold.deep],
        stops: [0, .55, 1],
      ).createShader(Rect.fromLTWH(-14, -19, 26, 14));
    void blob(Offset o, double r) => c.drawOval(
          Rect.fromCenter(center: o, width: r * 2, height: r * 1.86),
          bodyPaint,
        );
    blob(const Offset(-1, -12), 10.2);
    blob(const Offset(6.4, -12.4), 5.4);
    blob(const Offset(-8.2, -11.8), 5.6);

    // Near legs on top of the body.
    leg(6.4, .12, LionGold.core, 2.4, 1.8);
    leg(-8.0, 0, LionGold.core, 2.6, 1.9);

    // Neck.
    c.drawLine(
      const Offset(7.8, -14.2),
      const Offset(12.6, -18.4),
      Paint()
        ..color = LionGold.core
        ..strokeWidth = 4.6
        ..strokeCap = StrokeCap.round,
    );

    // Head group — rotates up into the roar.
    c.save();
    c.translate(9.2, -15.2);
    c.rotate(-0.62 * headRaise);
    c.translate(-9.2, 15.2);

    // Mane: jagged golden crown that flares and flutters while roaring.
    final mane = Path();
    const spikes = 13;
    for (var i = 0; i < spikes * 2; i++) {
      final ang = i / (spikes * 2) * math.pi * 2 + .35;
      final outer = i.isEven;
      final flutter = math.sin(time * 6 + i * 1.7) * .45;
      final r = outer
          ? 7.3 + 2.0 * headRaise + flutter * (0.5 + headRaise)
          : 4.5;
      final pt = Offset(14.6 + math.cos(ang) * r, -19.6 + math.sin(ang) * r);
      if (i == 0) {
        mane.moveTo(pt.dx, pt.dy);
      } else {
        mane.lineTo(pt.dx, pt.dy);
      }
    }
    mane.close();
    c.drawPath(mane, Paint()..color = const Color(0xFFE3A335));

    // Head, muzzle, ear, eye.
    c.drawCircle(const Offset(14.6, -19.6), 3.7, bodyPaint);
    c.drawCircle(const Offset(17.8, -18.4), 2.0, bodyPaint);
    final ear = Path()
      ..moveTo(12.4, -22.2)
      ..lineTo(13.6, -24.2)
      ..lineTo(14.4, -22.0)
      ..close();
    c.drawPath(ear, Paint()..color = LionGold.deep);
    c.drawCircle(
      const Offset(16.2, -20.6),
      .55,
      Paint()..color = const Color(0xFF3A1B06),
    );

    // Roar: gaping jaw with fangs.
    if (jawOpen > 0.02) {
      final gape = jawOpen * 2.2;
      final mouth = Path()
        ..moveTo(16.6, -17.6)
        ..lineTo(19.6, -16.4 - gape * .2)
        ..lineTo(17.0, -16.2 + gape)
        ..close();
      c.drawPath(mouth, Paint()..color = const Color(0xFF40190A));
      final fang = Paint()..color = const Color(0xFFF7E1A8);
      c.drawPath(
        Path()
          ..moveTo(17.2, -17.3)
          ..lineTo(17.8, -17.1)
          ..lineTo(17.5, -16.1)
          ..close(),
        fang,
      );
      c.drawPath(
        Path()
          ..moveTo(18.6, -16.9)
          ..lineTo(19.1, -16.7)
          ..lineTo(18.9, -15.9)
          ..close(),
        fang,
      );
    }

    c.restore(); // head group
    c.restore(); // lion
  }

  // ---------------------------------------------------------------------------
  // The pride that joins once the tunnel is up — same gold, same aura.
  // ---------------------------------------------------------------------------
  void _pride(Canvas c) {
    final a = companions;
    void at(Offset pos, double s, void Function() draw) {
      c.save();
      c.translate(pos.dx, pos.dy);
      c.scale(s);
      draw();
      c.restore();
    }

    // Deer — far side, bounding gait, antlers.
    at(
      const Offset(25, 79),
      .74,
      () => _beast(
        c,
        gait: scroll * 2.42 + .33,
        bob: 1.9,
        alpha: a,
        bodyRx: 5.6,
        bodyRy: 2.3,
        neckLen: 4.6,
        headR: 1.7,
        legLen: 6.4,
        fill: const Color(0xFFF3C55E),
        dark: const Color(0xFFB2761E),
        antlers: true,
      ),
    );

    // Leopard — low and long-tailed, spots.
    at(
      const Offset(38, 81.5),
      .62,
      () => _beast(
        c,
        gait: scroll * 2.25 + .66,
        bob: 1.2,
        alpha: a,
        bodyRx: 5.4,
        bodyRy: 2.4,
        neckLen: 2.4,
        headR: 1.9,
        legLen: 5.2,
        fill: LionGold.core,
        dark: LionGold.deep,
        spots: true,
        longTail: true,
      ),
    );

    // Tiger — big striped cat, ahead on the path.
    at(
      const Offset(80, 80.5),
      .94,
      () => _beast(
        c,
        gait: scroll * 2.25 + .15,
        bob: 1.3,
        alpha: a,
        bodyRx: 7.4,
        bodyRy: 3.2,
        neckLen: 2.8,
        headR: 2.5,
        legLen: 6.2,
        fill: const Color(0xFFF6BE3F),
        dark: const Color(0xFF9C5A0E),
        stripes: true,
      ),
    );
  }

  /// Generic golden quadruped (deer / tiger / leopard), local origin at the
  /// ground under its chest. Simpler rig than the lion — the lion is the
  /// hero; these read as glowing silhouettes in motion.
  void _beast(
    Canvas c, {
    required double gait,
    required double bob,
    required double alpha,
    required double bodyRx,
    required double bodyRy,
    required double neckLen,
    required double headR,
    required double legLen,
    required Color fill,
    required Color dark,
    bool stripes = false,
    bool spots = false,
    bool antlers = false,
    bool longTail = false,
  }) {
    final cy = -(legLen + bodyRy);
    final bodyRect = Rect.fromCenter(
      center: Offset(0, cy),
      width: bodyRx * 2,
      height: bodyRy * 2,
    );

    c.save();
    c.translate(0, -math.abs(math.sin(gait * math.pi * 2)) * bob);

    // Contact shadow.
    c.drawOval(
      Rect.fromCenter(center: const Offset(0, .6), width: bodyRx * 2.2, height: 2),
      Paint()..color = const Color(0x40140A02).withValues(alpha: .25 * alpha),
    );

    // Matching golden aura.
    c.drawOval(
      bodyRect,
      Paint()
        ..color = fill.withValues(alpha: .38 * alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.2),
    );

    final body = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(Colors.white, fill, .65)!,
          fill.withValues(alpha: alpha),
          dark.withValues(alpha: alpha),
        ],
      ).createShader(bodyRect.inflate(2));

    void leg(double phase, Color col, double w) {
      final p = gait + phase;
      final swing = math.sin(p * math.pi * 2);
      final lift = math.max(0.0, math.cos(p * math.pi * 2));
      final hx = bodyRx * (phase < .3 ? .62 : -.62);
      final hy = cy + bodyRy * .5;
      final a2 = swing * .5;
      final kx = hx + math.sin(a2) * legLen * .55;
      final ky = hy + math.cos(a2) * legLen * .55;
      final b = a2 - lift * .8 + .1;
      final px = kx + math.sin(b) * legLen * .45;
      final py = ky + math.cos(b) * legLen * .45;
      final st = Paint()
        ..color = col.withValues(alpha: alpha)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = w;
      c.drawLine(Offset(hx, hy), Offset(kx, ky), st);
      st.strokeWidth = w * .75;
      c.drawLine(Offset(kx, ky), Offset(px, py), st);
    }

    // Far pair, then body, then near pair — depth order.
    leg(.5, dark, bodyRy * .32);
    leg(.62, dark, bodyRy * .30);
    c.drawOval(bodyRect, body);
    leg(0, fill, bodyRy * .38);
    leg(.12, fill, bodyRy * .36);

    if (stripes) {
      final sp = Paint()
        ..color = dark.withValues(alpha: .85 * alpha)
        ..strokeWidth = .7
        ..strokeCap = StrokeCap.round;
      for (var i = -1; i <= 1; i++) {
        final bx = i * bodyRx * .33;
        c.drawLine(Offset(bx, cy - bodyRy * .9), Offset(bx - .7, cy + bodyRy * .7), sp);
      }
    }
    if (spots) {
      final dp = Paint()..color = dark.withValues(alpha: .8 * alpha);
      for (var i = 0; i < 7; i++) {
        c.drawCircle(
          Offset((_hash(i * 7) - .5) * bodyRx * 1.5,
              cy + (_hash(i * 11) - .5) * bodyRy * 1.4),
          .45,
          dp,
        );
      }
    }

    // Neck + head.
    final headC = Offset(bodyRx * .92, cy - neckLen);
    c.drawLine(
      Offset(bodyRx * .55, cy - bodyRy * .4),
      headC + Offset(-headR * .3, headR * .9),
      Paint()
        ..color = fill.withValues(alpha: alpha)
        ..strokeWidth = bodyRy * .9
        ..strokeCap = StrokeCap.round,
    );
    c.drawCircle(headC, headR, Paint()..color = fill.withValues(alpha: alpha));
    // Ear.
    c.drawPath(
      Path()
        ..moveTo(headC.dx - headR * .4, headC.dy - headR * .8)
        ..lineTo(headC.dx - headR * .1, headC.dy - headR * 1.6)
        ..lineTo(headC.dx + headR * .2, headC.dy - headR * .8)
        ..close(),
      Paint()..color = dark.withValues(alpha: alpha),
    );

    if (antlers) {
      final ap = Paint()
        ..color = dark.withValues(alpha: alpha)
        ..strokeWidth = .45
        ..strokeCap = StrokeCap.round;
      for (final s in const [-1.0, 1.0]) {
        final a0 = headC + Offset(s * headR * .35, -headR * .85);
        final a1 = a0 + Offset(s * 1.6, -3.2);
        c.drawLine(a0, a1, ap);
        c.drawLine(a1 + Offset(0, 1.4), a1 + Offset(s * 1.9, .5), ap);
        c.drawLine(a1 + Offset(0, 2.4), a1 + Offset(-s * .1, 1.9), ap);
      }
    }

    // Tail.
    final tailEnd = Offset(
      -bodyRx * .95 - (longTail ? 4.6 : 3.4),
      cy - (longTail ? 6.2 : 2.2) + math.sin(time * 5 + gait * 6) * 1.1,
    );
    c.drawPath(
      Path()
        ..moveTo(-bodyRx * .9, cy - bodyRy * .2)
        ..quadraticBezierTo(
            -bodyRx - 2.5, cy - 3.4, tailEnd.dx, tailEnd.dy),
      Paint()
        ..color = dark.withValues(alpha: alpha)
        ..strokeWidth = .9
        ..strokeCap = StrokeCap.round,
    );
    c.drawCircle(
        tailEnd, .9, Paint()..color = fill.withValues(alpha: alpha));

    c.restore();
  }

  // ---------------------------------------------------------------------------
  // The roar: radiant golden aura wave expanding outward in a circle.
  // ---------------------------------------------------------------------------
  void _aura(Canvas c) {
    for (var i = 0; i < 3; i++) {
      final p = ((aura - i * .12) / .7).clamp(0.0, 1.0);
      if (p <= 0) continue;
      final r = 5 + Curves.easeOutCubic.transform(p) * 48;
      final alpha = (1 - p) * (1 - p) * .85;
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4 * (1 - p) + .35
        ..color = LionGold.bright.withValues(alpha: alpha);
      // Ring on the ground plane + a full circle around the lion.
      c.drawOval(
        Rect.fromCenter(
            center: const Offset(_lionX, _groundY + 1), width: r * 2, height: r * .62),
        stroke,
      );
      c.drawCircle(
        const Offset(_lionX, _groundY - 12),
        r * .92,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0 * (1 - p) + .3
          ..color = LionGold.core.withValues(alpha: alpha * .55),
      );
    }
  }

  void _flash(Canvas c) {
    final r = Rect.fromCircle(
        const Offset(_lionX, _groundY - 12), 8 + flash * 30);
    c.drawRect(
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            LionGold.bright.withValues(alpha: .45 * flash),
            LionGold.core.withValues(alpha: .18 * flash),
            Colors.transparent,
          ],
          stops: const [0, .4, 1],
        ).createShader(r),
    );
  }
}
