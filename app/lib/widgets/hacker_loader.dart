import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/sensei_theme.dart';

/// Terminal-style progress overlay shown while a background task runs
/// (fetching and decrypting the config feed).
///
/// The step list mirrors what `ConfigService.loadServers()` actually does, so the
/// text is descriptive rather than decorative.
class HackerLoader {
  const HackerLoader._();

  /// Runs [task] behind the overlay and returns its result. The overlay is
  /// always dismissed, including when [task] throws.
  static Future<T> run<T>(
    BuildContext context,
    Future<T> Function() task, {
    String title = 'FETCHING CONFIGS',
  }) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.86),
      builder: (_) => _HackerDialog(title: title),
    );
    try {
      // Hold the overlay for a beat so it never just flashes on a fast link.
      final results = await Future.wait([
        task(),
        Future<void>.delayed(const Duration(milliseconds: 1300)),
      ]);
      return results[0] as T;
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }
}

class _HackerDialog extends StatefulWidget {
  final String title;
  const _HackerDialog({required this.title});

  @override
  State<_HackerDialog> createState() => _HackerDialogState();
}

class _HackerDialogState extends State<_HackerDialog>
    with SingleTickerProviderStateMixin {
  static const _steps = [
    'open secure channel',
    'resolve feed endpoint',
    'tls handshake',
    'GET config bundle',
    'verify signature binding',
    'decrypt AES-256-GCM',
    'parse tunnel list',
    'write offline cache',
  ];

  final _rng = Random();
  final List<String> _lines = [];
  Timer? _timer;
  late final AnimationController _bar;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _bar = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..forward();
    _timer = Timer.periodic(const Duration(milliseconds: 130), (_) {
      if (!mounted) return;
      setState(() {
        final hex = List.generate(
          12,
          (_) => _rng.nextInt(16).toRadixString(16),
        ).join();
        final tag =
            _step < _steps.length ? _steps[_step] : 'stream ${_rng.nextInt(9999)}';
        _lines.add('${tag.padRight(26)} 0x$hex');
        if (_lines.length > 8) _lines.removeAt(0);
        if (_rng.nextBool() && _step < _steps.length) _step++;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _bar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(SenseiTokens.gap),
        decoration: BoxDecoration(
          color: t.isDark ? const Color(0xFF0A0714) : t.surface,
          borderRadius: SenseiTokens.brMd,
          border: Border.all(color: t.accent.withValues(alpha: 0.55)),
          boxShadow: [
            BoxShadow(color: t.accent.withValues(alpha: 0.22), blurRadius: 26),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.terminal_rounded, color: t.accent, size: 17),
                const SizedBox(width: SenseiTokens.gapSm),
                Text(
                  widget.title,
                  style: t.mono(
                    size: 12.5,
                    weight: FontWeight.w800,
                    color: t.accent,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: SenseiTokens.gapMd),
            SizedBox(
              height: 148,
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: _lines
                    .asMap()
                    .entries
                    .map(
                      (e) => Opacity(
                        // Older lines fade out toward the top.
                        opacity: (e.key + 1) / _lines.length,
                        child: Text(
                          '> ${e.value}',
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: t.mono(
                            size: 10.5,
                            weight: FontWeight.w500,
                            color: t.accent,
                            height: 1.6,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: SenseiTokens.gapMd),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: AnimatedBuilder(
                animation: _bar,
                builder: (_, __) => LinearProgressIndicator(
                  value: _bar.value,
                  minHeight: 5,
                  backgroundColor: t.accent.withValues(alpha: 0.15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
