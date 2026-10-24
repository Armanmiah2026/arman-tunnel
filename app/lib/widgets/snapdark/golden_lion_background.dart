import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/snapdark_theme.dart';
import 'golden_lion_dial.dart';

/// Full-screen golden-lion backdrop for the home dashboard.
///
/// Layer order (bottom → top):
///  1. a painterly golden-jungle safety net, shown only if the poster art
///     itself cannot load;
///  2. the STILL poster (assets/animations/golden_lion_poster.jpg),
///     cover-fitted — what the owner sees whenever the tunnel is down: a
///     frozen frame of the lion, so the background always looks real;
///  3. the looping 3D golden-lion video (assets/animations/3d_golden_lion.mp4)
///     — created and played ONLY once Connect is tapped (owner request:
///     nothing moves before that), crossfading out again on disconnect;
///  4. a dark-golden readability scrim plus a theme veil, so header text,
///     cards and buttons stay legible over any video frame while the 3D
///     lion keeps shining through.
///
/// The connection MOMENT is sold by [GoldenLionShockwaveOverlay] (placed
/// above the dashboard): when the tunnel comes up it fires a golden flash +
/// shock rings + sparks across the entire screen — the connect dial itself
/// stays a plain static button.
///
/// Lifecycle discipline: no video work at app open; the controller is
/// created lazily on the first connect, looped, volume-set from Settings
/// and played with mounted guards; init failures degrade to the poster and
/// painterly net (never a red screen); the platform player is released
/// exactly once in [dispose]; playback pauses while the app is backgrounded
/// and resumes on return — but only while the tunnel is up.
class GoldenLionBackground extends StatefulWidget {
  const GoldenLionBackground(
      {super.key, this.isConnected = false, this.soundVolume = 1.0});

  /// Whether the tunnel is UP. The video starts on the false→true edge and
  /// pauses (poster takes over) on the true→false edge.
  final bool isConnected;

  /// Background sound volume from Settings (0..1), applied to the video.
  final double soundVolume;

  /// The bundled loop. Drop the owner's render here (see the note in
  /// assets/animations/): the widget degrades to the poster and painterly
  /// fallback until the file exists, so the repo always builds and runs.
  static const String videoAsset = 'assets/animations/3d_golden_lion.mp4';

  /// One frozen frame of the loop — the disconnected background. Extracted
  /// from [videoAsset] (see assets/animations/README.md).
  static const String posterAsset =
      'assets/animations/golden_lion_poster.jpg';

  @override
  State<GoldenLionBackground> createState() => _GoldenLionBackgroundState();
}

class _GoldenLionBackgroundState extends State<GoldenLionBackground>
    with WidgetsBindingObserver {
  /// Created lazily on the first connect — null until then (owner request:
  /// the video starts playing only when Connect is pressed).
  VideoPlayerController? _video;
  bool _ready = false;
  bool _failed = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Deliberately NO video work here: the still poster covers the screen
    // until the owner taps Connect.
  }

  /// First connect: create + initialize + loop + volume + play. Later
  /// reconnects just resume the existing player.
  Future<void> _startVideo() async {
    if (_failed || _starting) return;
    final existing = _video;
    if (existing != null) {
      if (_ready) unawaited(existing.play());
      return; // still initializing — the boot sequence below will play.
    }
    _starting = true;
    try {
      final v = VideoPlayerController.asset(GoldenLionBackground.videoAsset);
      _video = v;
      await v.initialize();
      if (!mounted) return;
      await v.setLooping(true);
      await v.setVolume(widget.soundVolume); // Settings: Background Sound
      if (!mounted) return;
      if (widget.isConnected) await v.play();
      if (!mounted) return;
      setState(() {
        _ready = true;
        _starting = false;
      });
    } catch (_) {
      // Missing asset, unsupported codec, or no platform player at all
      // (widget tests). The poster + painterly net IS the design in that
      // case — the app keeps its golden look and never surfaces an error.
      if (mounted) {
        setState(() {
          _failed = true;
          _starting = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant GoldenLionBackground old) {
    super.didUpdateWidget(old);
    if (old.isConnected != widget.isConnected) {
      if (widget.isConnected) {
        // Tap Connect → the lion video starts (or resumes).
        unawaited(_startVideo());
      } else if (_ready) {
        // Disconnect → freeze; the still poster takes over again.
        unawaited(_video!.pause());
      }
    }
    if (old.soundVolume != widget.soundVolume && _ready) {
      // Settings → Background Sound −/+ takes effect live.
      unawaited(_video!.setVolume(widget.soundVolume));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Nothing plays while disconnected, so there is nothing to pause there.
    if (!_ready || !widget.isConnected) return;
    if (state == AppLifecycleState.resumed) {
      _video!.play();
    } else {
      _video!.pause();
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
    final v = _video;
    if (v != null && !_failed) {
      unawaited(v.dispose());
    }
    super.dispose();
  }

  /// Video aspect ratio with a safe default — VideoPlayerValue reports
  /// 0/0 = NaN before the first frame, which would poison FittedBox.
  double get _aspect {
    final ar = _video?.value.aspectRatio ?? 0;
    return ar.isFinite && ar > 0 ? ar : 16 / 9;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final light = !t.isDark;
    return Stack(
      fit: StackFit.expand,
      children: [
        // ---- 1. painterly safety net (deepest layer) --------------------
        const _GoldenJungleFallback(),
        // ---- 2. the STILL poster: the disconnected state of the bg -------
        Image.asset(
          GoldenLionBackground.posterAsset,
          key: const Key('goldenLionPoster'),
          fit: BoxFit.cover,
          // Missing poster → the painterly layer below simply shows through.
          errorBuilder: _ignorePosterError,
        ),
        // ---- 3. the video: exists only after Connect, cover-fitted -------
        if (_ready && _video!.value.isInitialized)
          AnimatedOpacity(
            opacity: widget.isConnected ? 1 : 0,
            duration: SnapDarkTokens.slow,
            curve: Curves.easeOut,
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  // Any box with the video's ratio works: FittedBox scales
                  // it up to cover and crops the overflow.
                  width: _aspect * 720,
                  height: 720,
                  child: VideoPlayer(_video!),
                ),
              ),
            ),
          ),
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

/// Swallows poster load/decode errors: the painterly layer below simply
/// stays visible, and widget tests never see an asset exception.
Widget _ignorePosterError(
        BuildContext context, Object error, StackTrace? stackTrace) =>
    const SizedBox.shrink();

/// Painterly golden-jungle dusk — the deepest layer, visible whenever both
/// the poster and the video are unavailable: a deep black-gold radial sky
/// over a warm path-glow — the same palette as [LionGold], so the app reads
/// as one scene at every zoom level.
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
