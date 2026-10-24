import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/snapdark_theme.dart';
import 'golden_lion_dial.dart';

/// The connect dial: concentric progress ring, orbiting spark while connecting,
/// breathing glow while connected, plus status and session timer.
///
/// One tap toggles the tunnel. The ring colour is the app's single source of
/// visual truth for connection state:
///   idle       → muted ring, hollow icon
///   connecting → bright mint, ring sweeps
///   connected  → accent, ring full + slow pulse
///
/// Inside the dial circle, a majestic golden-lion scene (see
/// [GoldenLionScene]) crossfades in while the tunnel is busy or up:
/// connecting → the lion sprints through a glowing golden jungle; the
/// instant the tunnel comes up it plants its feet and ROARS with an expanding
/// golden aura wave; connected → it runs on with a golden pride (deer, tiger,
/// leopard). Idle shows the original glass dial, unchanged.
class SnapDarkConnectionDial extends StatefulWidget {
  final bool isConnected;
  final bool isConnecting;

  /// `HH:MM:SS` session timer, shown only while connected.
  final String durationText;

  /// Short line under the timer (server name, or a hint when idle).
  final String caption;

  final VoidCallback onToggleConnect;

  const SnapDarkConnectionDial({
    super.key,
    required this.isConnected,
    required this.isConnecting,
    required this.durationText,
    required this.caption,
    required this.onToggleConnect,
  });

  @override
  State<SnapDarkConnectionDial> createState() => _SnapDarkConnectionDialState();
}

class _SnapDarkConnectionDialState extends State<SnapDarkConnectionDial>
    with TickerProviderStateMixin {
  late final AnimationController _spin;
  late final AnimationController _pulse;
  late final AnimationController _press;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _press = AnimationController(
      vsync: this,
      duration: SnapDarkTokens.fast,
      lowerBound: 0,
      upperBound: 0.04,
    );
    _syncAnimations();
  }

  @override
  void didUpdateWidget(SnapDarkConnectionDial old) {
    super.didUpdateWidget(old);
    if (old.isConnected != widget.isConnected ||
        old.isConnecting != widget.isConnecting) {
      _syncAnimations();
    }
  }

  /// Only run the controllers a given state actually needs — a permanently
  /// spinning ticker on an idle dial is pure battery drain on a VPN app that
  /// sits in the foreground for hours.
  void _syncAnimations() {
    if (widget.isConnecting) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
      _spin.value = 0;
    }
    if (widget.isConnected) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = snapdarkScale(context);
    final connected = widget.isConnected;
    final connecting = widget.isConnecting;

    final ringColor = connected
        ? t.accent
        : connecting
            ? t.accentBright
            : t.border;
    final label = connected
        ? 'CONNECTED'
        : connecting
            ? 'CONNECTING'
            : 'TAP TO CONNECT';
    final labelColor = connected
        ? t.accent
        : connecting
            ? t.accentBright
            : t.textMuted;

    return Padding
      (padding: EdgeInsets.symmetric(vertical: SnapDarkTokens.gapSm * s),
      child: Column(
        children: [
          // The dial is sized PROPORTIONALLY but inside a guaranteed band:
          //   target  = min(33% of screen height, 72% of screen width) — one
          //             formula for every aspect ratio, portrait or landscape,
          //             so a 320dp-wide low-DPI phone lands at a real, usable
          //             size instead of the old height-only number collapsing
          //             to "abnormally small" once cards/banners ate the slot;
          //   floor   = 170dp — the connect button never renders below this;
          //   ceiling = 320dp — tablets/big phones get a big-but-not-bloated
          //             dial (the old 560 ceiling over-inflated it);
          //   …then capped by what THIS zone can actually offer, so a banner
          //   or notice stacked above can never push the art out of its slot
          //   (FittedBox scales it down gracefully in that rare squeeze).
          Flexible(
            child: Center(
              child: LayoutBuilder(builder: (context, box) {
                final screen = MediaQuery.sizeOf(context);
                double side = math.min(
                  screen.height * 0.33,
                  screen.width * 0.72,
                );
                side = side.clamp(170.0, 320.0);
                if (box.hasBoundedWidth && box.maxWidth.isFinite) {
                  side = math.min(side, box.maxWidth);
                }
                if (box.hasBoundedHeight && box.maxHeight.isFinite) {
                  side = math.min(side, box.maxHeight);
                }
                return SizedBox(
                  width: side,
                  height: side,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: 244,
                      height: 244,
                      child: AnimatedBuilder(
              animation: Listenable.merge([_spin, _pulse, _press]),
              builder: (context, _) {
                final breathe = connected ? _pulse.value : 0.0;
                return Transform.scale(
                  scale: 1 - _press.value,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Soft halo — grows slightly with the breath.
                      Container(
                        width: 244,
                        height: 244,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              ringColor.withValues(alpha: 
                                connected
                                    ? 0.12 + breathe * 0.09
                                    : connecting
                                        ? 0.12
                                        : 0.03,
                              ),
                              Colors.transparent,
                            ],
                            stops: const [0.55, 1],
                          ),
                        ),
                      ),
                      CustomPaint(
                        size: const Size.square(212),
                        painter: _DialPainter(
                          ringColor: ringColor,
                          trackColor: t.border,
                          tickColor: connected
                              ? t.accent.withValues(alpha: 0.55)
                              : t.border,
                          // Full ring when connected, sweeping arc while
                          // connecting, thin idle track otherwise.
                          progress: connected ? 1 : (connecting ? 0.24 : 0),
                          rotation: _spin.value * 2 * math.pi,
                          glow: breathe,
                        ),
                      ),
                      _DialButton(
                        connected: connected,
                        connecting: connecting,
                        onTap: widget.onToggleConnect,
                        onPressStart: () => _press.forward(),
                        onPressEnd: () => _press.reverse(),
                      ),
                    ],
                  ),
                );
              },
                      ),
                    ),
                  ),
                );
              }), // LayoutBuilder
            ), // Center
          ), // Flexible
          SizedBox(height: SnapDarkTokens.gap * s),
          Text(
            label,
            style: TextStyle(
              color: labelColor,
              fontSize: 13 * s,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.2 * s,
            ),
          ),
          SizedBox(height: 6 * s),
          Text(
            connected ? widget.durationText : '00:00:00',
            style: t.mono(
              size: 22 * s,
              weight: FontWeight.w700,
              color: connected ? t.text : t.textMuted,
              letterSpacing: 2 * s,
            ),
          ),
          SizedBox(height: SnapDarkTokens.gapXs * s),
          Text(
            widget.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: t.textMuted,
              fontSize: 12 * s,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _DialButton extends StatelessWidget {
  final bool connected;
  final bool connecting;
  final VoidCallback onTap;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  const _DialButton({
    required this.connected,
    required this.connecting,
    required this.onTap,
    required this.onPressStart,
    required this.onPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final busy = connecting || connected;
    return Semantics(
      button: true,
      label: connected ? 'Disconnect' : 'Connect',
      child: GestureDetector(
        onTap: onTap,
        onTapDown: (_) => onPressStart(),
        onTapUp: (_) => onPressEnd(),
        onTapCancel: onPressEnd,
        child: Container(
          width: 150,
          height: 150,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: connected
                ? LinearGradient(
                    colors: t.accentGradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : LinearGradient(
                    // Glass mode: translucent fill so the wallpaper reads
                    // through the idle dial (neon-glass look); identical to
                    // the opaque gradient when wallpaper mode is off.
                    colors: [t.surfaceAltFill, t.surfaceFill],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
            border: Border.all(
              color: connected
                  ? Colors.transparent
                  : connecting
                      ? t.accentBright
                      : t.border,
              width: 1.4,
            ),
            boxShadow: connected
                ? [
                    BoxShadow(
                      color: t.accent.withValues(alpha: 0.35),
                      blurRadius: 28,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          // The golden-lion scene fills the dial circle while busy/up, and
          // crossfades out to the plain glass fill at idle (AnimatedOpacity
          // keeps one subtree alive — no rebuild churn on state flips).
          //
          // Owner request: no power-icon badge over the lion — the scene is
          // the button. The whole 150dp circle remains the tap target
          // (the GestureDetector wraps this container), so nothing is lost.
          child: ClipOval(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: busy ? 1 : 0,
                    duration: SnapDarkTokens.slow,
                    curve: Curves.easeOut,
                    child: GoldenLionScene(
                      isConnected: connected,
                      isConnecting: connecting,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final Color ringColor;
  final Color trackColor;
  final Color tickColor;

  /// 0..1 of the ring to fill. 0 draws only the track.
  final double progress;

  /// Radians of rotation applied to the sweeping arc.
  final double rotation;

  /// 0..1 breath amount, widens the stroke slightly.
  final double glow;

  _DialPainter({
    required this.ringColor,
    required this.trackColor,
    required this.tickColor,
    required this.progress,
    required this.rotation,
    required this.glow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 6;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Track.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = trackColor,
    );

    // Tick marks around the dial — 48 ticks, every 6th one longer.
    const ticks = 48;
    final tickPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..color = tickColor;
    for (var i = 0; i < ticks; i++) {
      final angle = (i / ticks) * 2 * math.pi - math.pi / 2;
      final major = i % 6 == 0;
      final inner = radius - (major ? 13 : 8);
      tickPaint.strokeWidth = major ? 2 : 1;
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * (radius - 4), math.sin(angle) * (radius - 4)),
        tickPaint,
      );
    }

    if (progress <= 0) return;

    // Progress arc.
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4 + glow * 1.6
      ..shader = SweepGradient(
        colors: [ringColor.withValues(alpha: 0.25), ringColor],
        transform: GradientRotation(rotation - math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(
      rect,
      -math.pi / 2 + rotation,
      2 * math.pi * progress,
      false,
      arc,
    );

    // Leading spark on the sweeping arc.
    if (progress < 1) {
      final angle = -math.pi / 2 + rotation + 2 * math.pi * progress;
      canvas.drawCircle(
        center + Offset(math.cos(angle) * radius, math.sin(angle) * radius),
        3.5,
        Paint()..color = ringColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DialPainter o) =>
      o.ringColor != ringColor ||
      o.trackColor != trackColor ||
      o.tickColor != tickColor ||
      o.progress != progress ||
      o.rotation != rotation ||
      o.glow != glow;
}
