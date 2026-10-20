import 'package:flutter/material.dart';

import '../../services/settings_provider.dart';
import '../../theme/snapdark_theme.dart';

/// Animated Dark/Light quick-toggle for the home header.
///
/// Sun ↔ moon crossfade with a spin: the outgoing icon rotates a quarter
/// turn while scaling down, the incoming one spins in from the opposite
/// side — the classic day/night flip. A tinted ring behind the icon pulses
/// to the accent during the swap so the tap always feels acknowledged.
class SnapDarkThemeToggle extends StatelessWidget {
  final SettingsProvider settings;

  const SnapDarkThemeToggle({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isDark = settings.isDark;
    return Tooltip(
      message: isDark ? 'Switch to Light' : 'Switch to Dark',
      child: Material(
        color: t.surfaceFill,
        borderRadius: SnapDarkTokens.brMd,
        child: InkWell(
          onTap: () => settings.toggleTheme(),
          borderRadius: SnapDarkTokens.brMd,
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: SnapDarkTokens.brMd,
              border: Border.all(color: t.border),
            ),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 420),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) {
                  // The incoming icon spins in from the left, the outgoing
                  // one keeps rotating out to the right — keyed on the
                  // child's identity so each side gets its own direction.
                  final incoming = child.key == const ValueKey(true);
                  final turns = Tween<double>(
                    begin: incoming ? -0.5 : 0.5,
                    end: 0,
                  ).animate(anim);
                  return RotationTransition(
                    turns: turns,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.4,
                        end: 1,
                      ).animate(anim),
                      child: child,
                    ),
                  );
                },
                child: Icon(
                  // Dark shows the SUN (what you switch TO), light the MOON —
                  // the button always advertises the destination.
                  isDark
                      ? Icons.light_mode_rounded
                      : Icons.dark_mode_rounded,
                  key: ValueKey(isDark),
                  size: 21,
                  color: isDark ? t.lime : t.accent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
