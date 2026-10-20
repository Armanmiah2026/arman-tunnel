import 'package:flutter/material.dart';

import '../services/session_history.dart';
import '../theme/snapdark_theme.dart';
import '../utils/format.dart';
import '../widgets/ui/snapdark_controls.dart';

/// Connection history: real per-session records (server, start, duration,
/// traffic), newest first. The old keyword-filter over the log mistook config
/// refreshes for connections and its "Clear" wiped the engine log too.
class ConnectionHistoryScreen extends StatelessWidget {
  const ConnectionHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(
        title: const Text('Connection History'),
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: t.pageGradient,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: SnapDarkTokens.maxContentWidth,
              ),
              child: ListenableBuilder(
                listenable: SessionHistory.instance,
                builder: (context, _) {
                  final history = SessionHistory.instance;
                  final sessions = [
                    if (history.active != null) {...history.active!, 'live': true},
                    ...history.sessions,
                  ];

                  if (sessions.isEmpty) {
                    return const SnapDarkEmptyState(
                      icon: Icons.history_rounded,
                      title: 'No history yet',
                      message: 'Sessions appear here once you connect — with '
                          'duration and traffic, not guesses.',
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                      SnapDarkTokens.pageInset,
                      SnapDarkTokens.gapMd,
                      SnapDarkTokens.pageInset,
                      SnapDarkTokens.gapXxl,
                    ),
                    itemCount: sessions.length,
                    itemBuilder: (_, i) => _SessionRow(
                      session: sessions[i],
                      isLast: i == sessions.length - 1,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  final Map<String, dynamic> session;
  final bool isLast;

  const _SessionRow({required this.session, required this.isLast});

  String _fmtBytes(num bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(v >= 100 || u == 0 ? 0 : 1)} ${units[u]}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final live = session['live'] == true;
    final server = session['server']?.toString() ?? 'Unknown';
    final protocol = session['protocol']?.toString() ?? '';
    final startMs = (session['start'] as num?)?.toInt() ?? 0;
    final endMs = (session['end'] as num?)?.toInt();
    final down = (session['down'] as num?)?.toInt() ?? 0;
    final up = (session['up'] as num?)?.toInt() ?? 0;

    final start = DateTime.fromMillisecondsSinceEpoch(startMs);
    final duration = live
        ? Duration.zero
        : endMs != null
            ? DateTime.fromMillisecondsSinceEpoch(endMs).difference(start)
            : Duration.zero;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline rail.
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 18),
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: live ? t.accent : t.accentDeep,
                    boxShadow: live
                        ? [BoxShadow(color: t.accent.withValues(alpha: 0.5), blurRadius: 8)]
                        : null,
                  ),
                ),
                if (!isLast)
                  Expanded(child: Container(width: 2, color: t.border)),
              ],
            ),
          ),
          const SizedBox(width: SnapDarkTokens.gapSm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: SnapDarkTokens.gapMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          server,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: t.text,
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                      if (live)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: t.accentWash,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'LIVE',
                            style: TextStyle(
                              color: t.accent,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${_two(start.hour)}:${_two(start.minute)} · '
                    '${start.day}/${start.month}',
                    style: TextStyle(color: t.textMuted, fontSize: 11.5),
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: SnapDarkTokens.gapSm,
                    runSpacing: 4,
                    children: [
                      if (protocol.isNotEmpty)
                        _chip(context, Icons.bolt_rounded, protocol, t.textMuted),
                      _chip(
                        context,
                        Icons.schedule_rounded,
                        live ? formatDuration(DateTime.now().difference(start)) : formatDuration(duration),
                        live ? t.accent : t.textMuted,
                      ),
                      _chip(context, Icons.download_rounded, _fmtBytes(down), t.textMuted),
                      _chip(context, Icons.upload_rounded, _fmtBytes(up), t.textMuted),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, IconData icon, String label, Color color) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: t.surfaceAltFill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
