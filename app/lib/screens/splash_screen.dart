import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main_shell.dart';

/// Boot screen — a seamless continuation of the NATIVE launch splash.
///
/// The Android launch theme already paints `#0B0913` with the 200dp SnapDark
/// lockup centered (drawable/snapdark_splash.png). This widget reproduces that
/// exact frame (same colour, same asset, same size) and adds only the loading
/// line underneath, so the user sees ONE screen — the logo they saw at tap,
/// now with a loader — instead of a second, different splash.
///
/// Colours are hardcoded to the dark brand values on purpose: the native
/// splash is always dark (Theme.Black), so this must match it in light mode
/// too or the transition flashes.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  static const _splashBg = Color(0xFF0B0913); // = @color/launcher_background
  static const _accent = Color(0xFF7C3AED);
  static const _track = Color(0xFF2A2340);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Lock portrait-agnostic: nothing to do. Short fixed boot delay gives the
    // providers a beat to load prefs + cached configs before the dashboard.
    _timer = Timer(const Duration(milliseconds: 1400), _go);
  }

  void _go() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (_, __, ___) => const MainShell(),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the system status/nav bars in the same dark tone; no contrast jump.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: _splashBg,
        systemNavigationBarColor: _splashBg,
      ),
      child: Scaffold(
        backgroundColor: _splashBg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Same bitmap the native splash shows, same 200dp size.
              Image.asset(
                'assets/images/snapdark_splash.png',
                width: 200,
                height: 200,
                filterQuality: FilterQuality.high,
              ),
              const SizedBox(height: 40),
              const SizedBox(
                width: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(3)),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    backgroundColor: _track,
                    valueColor: AlwaysStoppedAnimation(_accent),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
