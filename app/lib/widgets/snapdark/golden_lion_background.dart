import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/snapdark_theme.dart';
import 'golden_lion_dial.dart';

/// Full-screen golden-lion backdrop for the home dashboard.
///
/// Layer order (bottom → top):
///  1. the looping 3D golden-lion video (assets/animations/3d_golden_lion.mp4)
///     painted through a FittedBox(BoxFit.cover) so it always fills the whole
///     screen — status bar edge to bottom navigation bar;
///  2. a painterly golden-jungle fallback shown while the video initializes,
///     when the asset has not been dropped in yet, or when the platform
///     cannot play video (widget tests, very old devices);
///  3. a dark-golden readability scrim plus a theme veil, so header text,
///     cards and buttons stay legible over any video frame while the 3D
///     lion keeps shining through.
///
/// The video is a loop and cannot sync to VPN state, so the connection
/// MOMENT is sold by [GoldenLionShockwaveOverlay] (placed above the
/// dashboard): when the tunnel comes up it fires a golden flash + shock
/// rings + sparks across the entire screen. The connect dial keeps its own
/// running / roar / pride lion scene inside the button.
///
/// Lifecycle discipline: the controller is created, initialized, looped,
/// muted and played in [initState] with mounted guards; init failures
/// degrade to the fallback (never a red screen); the platform player is
/// released exactly once in [dispose]; playback pauses while the app is
/// backgrounded and resumes on return.
class GoldenLionBackground extends StatefulWidget {
  const GoldenLionBackground({super.key});

  /// The bundled loop. Drop the owner's render here (see the note in
  /// assets/animations/): the widget degrades to the painterly fallback
  /// until the file exists, so the repo always builds and runs.
  static const String videoAsset = 'assets/animations/3d_golden_lion.mp4';

  @override
  State<GoldenLionBackground> createState() => _GoldenLionBackgroundState();
}

class _GoldenLionBackgroundState extends State<GoldenLionBackground>
    with WidgetsBindingObserver {
  late final VideoPlayerController _video;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _video = VideoPlayerController.asset(GoldenLionBackground.videoAsset);
    unawaited(_initVideo());
  }

  Future<void> _initVideo() async {
    try {
      await _video.initialize();
      if (!mounted) return;
      await _video.setLooping(true);
      await _video.setVolume(1.0); // the golden lion's roar/music ships with it
      await _video.play();
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (_) {
      // Missing asset, unsupported codec, or no platform player at all
      // (widget tests). The painterly fallback IS the design in that case —
      // the app keeps its golden look and never surfaces an error.
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_ready) return;
    if (state == AppLifecycleState.resumed) {
      _video.play();
    } else {
      _video.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Release the platform player whenever one can exist. After a FAILED
    // initialize() the controller's internal create-completer never
    // completes (video_player 2.14), so dispose() would await forever; in
    // that state there is no native player to release, so we skip it
    // deliberately. Success → full teardown; in-flight init → teardown
    // completes the moment creation lands.
    if (!_failed) {
      unawaited(_video.dispose());
    }
    super.dispose();
  }

  /// Video aspect ratio with a safe default — VideoPlayerValue reports
  /// 0/0 = NaN before the first frame, which would poison FittedBox.
  double get _aspect {
    final ar = _video.value.aspectRatio;
    return ar.isFinite && ar > 0 ? ar : 16 / 9;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final light = !t.isDark;
    return Stack(
      fit: StackFit.expand,
      children: [
        // ---- 1. the video, cover-fitted to the whole screen -------------
        if (_ready && _video.value.isInitialized)
          ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                // Any box with the video's ratio works: FittedBox scales it
                // up to cover and crops the overflow.
                width: _aspect * 720,
                height: 720,
                child: VideoPlayer(_video),
              ),
            ),
          )
        // ---- 2. painterly golden-jungle fallback ------------------------
        else
          const _GoldenJungleFallback(),
        // ---- 3a. dark-golden readability scrim --------------------------
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xB3000000), // top — header / status area
                Color(0x5A1A0F02), // middle — the lion breathes through
                Color(0xCC080500), // bottom — cards rest on a dark base
              ],
              stops: [0, .45, 1],
            ),
          ),
        ),
        // ---- 3b. radiant golden sun haze (top third) --------------------
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -.55),
              radius: 1.15,
              colors: [
                Color(0x2EF7C948), // LionGold.core @ ~18%
                Colors.transparent,
              ],
            ),
          ),
        ),
        // ---- 3c. theme veil: light theme keeps its contrast -------------
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                t.bg.withValues(alpha: light ? .60 : .20),
                t.bg.withValues(alpha: light ? .76 : .42),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Painterly golden-jungle dusk used whenever the video cannot play: a deep
/// black-gold radial sky over a warm path-glow — the same palette as the
/// dial's [LionGold], so the app reads as one scene at every zoom level.
class _GoldenJungleFallback extends StatelessWidget {
  const _GoldenJungleFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      key: Key('goldenLionFallback'),
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -.35),
          radius: 1.25,
          colors: [
            Color(0xFF3A2405), // sunlit haze
            Color(0xFF160D02), // deep jungle
            Color(0xFF070400), // night floor
          ],
          stops: [0, .55, 1],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0x66DE8B22), Colors.transparent],
            stops: [0, .35],
          ),
        ),
      ),
    );
  }
}

/// Marks the subtree that sits OVER the golden-lion backdrop, so shared
/// surfaces (see SnapDarkCard) switch to their glass treatment: a faint
/// white wash with a golden hairline, letting the 3D background shine
/// through every panel. Outside the home dashboard nothing changes.
class GoldenLionScope extends InheritedWidget {
  const GoldenLionScope({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GoldenLionScope>()?.enabled ??
      false;

  @override
  bool updateShouldNotify(GoldenLionScope oldWidget) =>
      oldWidget.enabled != enabled;
}

/// Full-screen golden shockwave for the connection-success moment.
///
/// Placed ABOVE the dashboard (and ignoring pointers): the instant
/// [isConnected] rises, a bright golden flash blooms and three lagging
/// shock rings plus a burst of golden sparks sweep outward across the
/// ENTIRE screen — the roar moment the dial's own scene cannot reach from
/// inside its circle. Idle: no ticker runs (battery discipline), the build
/// is a plain shrink-wrapped box.
class GoldenLionShockwaveOverlay extends StatefulWidget {
  const GoldenLionShockwaveOverlay({super.key, required this.isConnected});

  final bool isConnected;

  @override
  State<GoldenLionShockwaveOverlay> createState() =>
      _GoldenLionShockwaveOverlayState();
}

class _GoldenLionShockwaveOverlayState
    extends State<GoldenLionShockwaveOverlay>
    with SingleTickerProviderStateMixin {
  static const _kBoom = Duration(milliseconds: 1600);

  late final AnimationController _boom;
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    _wasConnected = widget.isConnected;
    // Idle = stopped: no frames are scheduled until the tunnel comes up.
    _boom = AnimationController(vsync: this, duration: _kBoom);
  }

  @override
  void didUpdateWidget(covariant GoldenLionShockwaveOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isConnected && !_wasConnected) {
      // THE moment: tunnel is up → shockwave from the very center.
      _boom.forward(from: 0);
    }
    _wasConnected = widget.isConnected;
  }

  @override
  void dispose() {
    _boom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _boom,
        builder: (context, _) {
          if (_boom.value == 0) return const SizedBox.shrink();
          return CustomPaint(painter: _ShockwavePainter(_boom.value));
        },
      ),
    );
  }
}

class _ShockwavePainter extends CustomPainter {
  const _ShockwavePainter(this.t);

  /// Progress 0..1 of the boom.
  final double t;

  /// Deterministic 0..1 hash — stable across repaints (a seeded Random
  /// would consume its sequence on every frame and make the sparks flicker).
  static double _hash01(int i) {
    final s = math.sin(i * 12.9898) * 43758.5453;
    return (s - s.floorToDouble()).abs();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR =
        math.sqrt(size.width * size.width + size.height * size.height) * .62;

    // ---- opening flash: a quick full-screen golden bloom -----------------
    final flash = (1 - (t / .22).clamp(0.0, 1.0));
    if (flash > 0) {
      final r = maxR * 1.2;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              LionGold.bright.withValues(alpha: .55 * flash),
              LionGold.core.withValues(alpha: .22 * flash),
              Colors.transparent,
            ],
            stops: const [0, .45, 1],
          ).createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }

    // ---- three lagging shock rings ---------------------------------------
    _ring(canvas, center, maxR, Curves.easeOutCubic.transform(t),
        width: 16, alpha: .85);
    _ring(
        canvas,
        center,
        maxR,
        Curves.easeOutCubic
            .transform(((t - .12) / .88).clamp(0.0, 1.0)),
        width: 10,
        alpha: .55);
    _ring(
        canvas,
        center,
        maxR,
        Curves.easeOutCubic
            .transform(((t - .24) / .76).clamp(0.0, 1.0)),
        width: 6,
        alpha: .35);

    // ---- golden sparks flying outward ------------------------------------
    for (var i = 0; i < 26; i++) {
      final h = _hash01(i);
      final lag = _hash01(i + 40) * .25;
      final p = ((t - lag) / (1 - lag)).clamp(0.0, 1.0);
      if (p <= 0) continue;
      final e = Curves.easeOutCubic.transform(p);
      final a = (i / 26) * math.pi * 2 + _hash01(i + 80) * .35;
      final dist = maxR * (.55 + h * .45) * e;
      final pos = center + Offset(math.cos(a), math.sin(a)) * dist;
      canvas.drawCircle(
        pos,
        1.2 + h * 2.4,
        Paint()
          ..color = LionGold.bright.withValues(alpha: (1 - p) * .9),
      );
    }
  }

  void _ring(Canvas canvas, Offset c, double maxR, double p,
      {required double width, required double alpha}) {
    if (p <= 0 || p >= 1) return;
    final r = maxR * p;
    if (r <= 0) return;
    final fade = 1 - p;
    // Soft outer glow line.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * fade + 1.5
        ..color = LionGold.bright.withValues(alpha: alpha * fade * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // Crisp inner edge.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color =
            const Color(0xFFFFF3C4).withValues(alpha: alpha * fade),
    );
  }

  @override
  bool shouldRepaint(_ShockwavePainter oldDelegate) =>
      oldDelegate.t != t;
}
