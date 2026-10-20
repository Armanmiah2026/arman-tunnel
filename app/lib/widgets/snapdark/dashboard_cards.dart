import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/server_config.dart';
import '../../theme/snapdark_theme.dart';
import '../../utils/format.dart';
import '../ui/cached_image.dart';
import '../ui/snapdark_controls.dart';
import 'charts.dart';

/// Active-server card on the dashboard. Tapping it jumps to the Configs tab
/// (the category sections there are the single place to pick a tweak).
class SnapDarkServerCard extends StatelessWidget {
  final ServerConfig? server;
  final VoidCallback onTap;
  final double? scale;

  /// Opens the config-note popup; non-null only when the selected config has
  /// note content, in which case a small note chip renders on the card.
  final VoidCallback? onNote;

  /// Live latency in ms; <= 0 renders as "—".
  final int pingMs;

  const SnapDarkServerCard({
    super.key,
    this.server,
    required this.onTap,
    this.pingMs = 0,
    this.onNote,
    this.scale,
  });

  /// Map latency onto the 4-bar indicator. Anything above ~400 ms is one bar.
  int get _bars {
    if (pingMs <= 0) return 0;
    if (pingMs < 90) return 4;
    if (pingMs < 180) return 3;
    if (pingMs < 400) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = scale ?? snapdarkScale(context);
    final cfg = server;
    return SnapDarkCard(
      onTap: onTap,
      padding: EdgeInsets.all(SnapDarkTokens.gap * s),
      child: Row(
        children: [
          // Admin logo image (Robi/Airtel/…) beats the country flag when set.
          _HomeAvatar(cfg: cfg, scale: s),
          SizedBox(width: SnapDarkTokens.gapMd * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ACTIVE TUNNEL', style: t.overline),
                SizedBox(height: 3 * s),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        cfg?.displayName ?? 'No tunnel selected',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cfg == null ? t.textSecondary : t.text,
                          fontSize: 16 * s,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    SizedBox(width: 2 * s),
                    Icon(Icons.expand_more_rounded,
                        color: t.accent, size: 19 * s),
                    if (onNote != null) ...[
                      SizedBox(width: 4 * s),
                      GestureDetector(
                        onTap: onNote,
                        child: Icon(Icons.sticky_note_2_outlined,
                            color: t.lime, size: 16 * s),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: 5 * s),
                if (cfg == null)
                  Text(
                    'Tap to pick one',
                    style: TextStyle(color: t.textMuted, fontSize: 11.5 * s),
                  )
                else
                  // Wrap, not Row: three method badges (SSH · TCP · Proxy+Payload)
                  // plus a 3-digit ping overflow the fixed-width middle column —
                  // Flutter's grey/black stripes. Wrapping absorbs the width.
                  Wrap(
                    spacing: 6 * s,
                    runSpacing: 5 * s,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SnapDarkBadge(
                        label: cfg.protocolLabel,
                        color: ProtocolVisual.tint(cfg.protocol, t),
                        icon: ProtocolVisual.iconFor(cfg.protocol),
                        scale: s,
                      ),
                      SnapDarkBadge(
                          label: cfg.transportLabel,
                          color: t.textMuted,
                          scale: s),
                      // Method badge (SNI / Payload / Proxy / combos / DNSTT) —
                      // the Configs list shows all three; the Tunnel card must
                      // too, not just protocol + transport.
                      if (cfg.methodLabel.isNotEmpty)
                        SnapDarkBadge(
                            label: cfg.methodLabel, color: t.lime, scale: s),
                    ],
                  ),
              ],
            ),
          ),
          SizedBox(width: SnapDarkTokens.gapSm * s),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SnapDarkSignalBars(strength: _bars, scale: s),
              SizedBox(height: 6 * s),
              Text(
                pingMs > 0 ? '$pingMs ms' : '—',
                style: t.mono(
                  size: 11.5 * s,
                  color: pingMs > 0 ? t.accent : t.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Live traffic panel: download / upload / ping with a ping sparkline, plus a
/// session total footer.
class SnapDarkStatisticsCard extends StatelessWidget {
  final int downloadBytesPerSecond;
  final int uploadBytesPerSecond;
  final int totalDownloadBytes;
  final int totalUploadBytes;
  final int pingMs;
  final List<double> pingHistory;

  /// Dim the whole panel when there is no active session.
  final bool active;

  /// Tight layout (small screens): drops the session-totals strip so the
  /// connect dial keeps its size. Metrics row always stays.
  final bool compact;
  final double? scale;

  const SnapDarkStatisticsCard({
    super.key,
    required this.downloadBytesPerSecond,
    required this.uploadBytesPerSecond,
    required this.totalDownloadBytes,
    required this.totalUploadBytes,
    required this.pingMs,
    required this.pingHistory,
    required this.active,
    this.compact = false,
    this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = scale ?? snapdarkScale(context);
    return SnapDarkCard(
      padding: EdgeInsets.all(SnapDarkTokens.gap * s),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: _Metric(
                  icon: Icons.south_rounded,
                  value: formatRate(downloadBytesPerSecond),
                  label: 'Download',
                  active: active,
                  scale: s,
                ),
              ),
              _VDivider(scale: s),
              Expanded(
                child: _Metric(
                  icon: Icons.north_rounded,
                  value: formatRate(uploadBytesPerSecond),
                  label: 'Upload',
                  active: active,
                  scale: s,
                ),
              ),
              _VDivider(scale: s),
              Expanded(
                child: _Metric(
                  icon: Icons.network_ping_rounded,
                  value: pingMs > 0 ? '$pingMs ms' : '—',
                  label: 'Latency',
                  active: active,
                  scale: s,
                  chart: pingHistory.length > 1
                      ? SnapDarkSparkline(
                          points: pingHistory,
                          color: t.accent,
                          size: Size(44 * s, 16 * s),
                        )
                      : null,
                ),
              ),
            ],
          ),
          if (!compact) ...[
            SizedBox(height: SnapDarkTokens.gapMd * s),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: SnapDarkTokens.gapMd * s,
                vertical: SnapDarkTokens.gapSm * s,
              ),
              decoration: BoxDecoration(
                color: t.surfaceAltFill,
                borderRadius: SnapDarkTokens.brSm,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.data_usage_rounded,
                          size: 13 * s, color: t.accent),
                      SizedBox(width: 6 * s),
                      Text(
                        'Session',
                        style: TextStyle(
                          color: t.textMuted,
                          fontSize: 11.5 * s,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '↓ ${formatBytes(totalDownloadBytes)}   '
                    '↑ ${formatBytes(totalUploadBytes)}',
                    style: t.mono(size: 11.5 * s, color: t.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _VDivider extends StatelessWidget {
  final double scale;
  const _VDivider({this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 40 * scale,
      color: context.tokens.border,
    );
  }
}

class _Metric extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final bool active;
  final Widget? chart;

  /// Shared home-scale factor (see [snapdarkScale]).
  final double scale;

  const _Metric({
    required this.icon,
    required this.value,
    required this.label,
    required this.active,
    this.chart,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tint = active ? t.accent : t.textMuted;
    return Column(
      children: [
        Icon(icon, size: 15 * scale, color: tint),
        SizedBox(height: 6 * scale),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: t.mono(
            size: 13 * scale,
            weight: FontWeight.w700,
            color: active ? t.text : t.textMuted,
          ),
        ),
        SizedBox(height: 3 * scale),
        if (chart != null)
          chart!
        else
          Text(
            label,
            style: TextStyle(color: t.textMuted, fontSize: 10.5 * scale),
          ),
      ],
    );
  }
}

/// 2x2 grid of dashboard shortcuts (protocol picker, split tunnel, routing,
/// speed test…). Replaces the old two-row "configuration card".
class SnapDarkQuickActions extends StatelessWidget {
  final List<SnapDarkQuickAction> actions;

  /// Tight layout: smaller gaps and tile padding so the dial keeps priority.
  final bool dense;
  final double? scale;
  const SnapDarkQuickActions(
      {super.key, required this.actions, this.dense = false, this.scale});

  @override
  Widget build(BuildContext context) {
    final s = scale ?? snapdarkScale(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = (dense ? SnapDarkTokens.gapSm : SnapDarkTokens.gapMd) * s;
        final width = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: actions
              .map((a) => SizedBox(
                  width: width,
                  child: _ActionTile(action: a, dense: dense, scale: s)))
              .toList(),
        );
      },
    );
  }
}

class SnapDarkQuickAction {
  final IconData icon;
  final String label;

  /// Current value / state shown under the label.
  final String value;
  final VoidCallback onTap;

  /// Highlight when the feature is switched on.
  final bool active;

  const SnapDarkQuickAction({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.active = false,
  });
}

class _ActionTile extends StatelessWidget {
  final SnapDarkQuickAction action;
  final bool dense;

  /// Shared home-scale factor (see [snapdarkScale]).
  final double scale;

  const _ActionTile({
    required this.action,
    this.dense = false,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = scale;
    return SnapDarkCard(
      onTap: action.onTap,
      active: action.active,
      radius: SnapDarkTokens.radiusMd,
      padding: EdgeInsets.all(
          (dense ? SnapDarkTokens.gapSm : SnapDarkTokens.gapMd + 2) * s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                action.icon,
                size: 18 * s,
                color: action.active ? t.accent : t.textSecondary,
              ),
              const Spacer(),
              Icon(Icons.chevron_right_rounded,
                  size: 17 * s, color: t.textMuted),
            ],
          ),
          SizedBox(height: SnapDarkTokens.gapMd * s),
          Text(
            action.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: t.textMuted,
              fontSize: 11 * s,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6 * s,
            ),
          ),
          SizedBox(height: 2 * s),
          Text(
            action.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: action.active ? t.accent : t.text,
              fontSize: 14 * s,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// Avatar of the active-tunnel card on the home dashboard: admin-supplied
/// hosted logo (imgbb URL) → embedded base64 logo → country flag → globe.
/// Scales with the shared home factor like everything else on the screen.
class _HomeAvatar extends StatelessWidget {
  final ServerConfig? cfg;
  final double scale;

  const _HomeAvatar({required this.cfg, required this.scale});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = cfg;
    final side = 46 * scale;

    Widget framed(Widget child) => Container(
          width: side,
          height: side,
          clipBehavior: Clip.hardEdge,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.accentWash,
            borderRadius: SnapDarkTokens.brMd,
            border: Border.all(color: t.accent.withValues(alpha: 0.3)),
          ),
          child: child,
        );

    final url = c?.logoUrl?.trim() ?? '';
    if (url.isNotEmpty) {
      return framed(
        // Permanent low-quality cache: downloaded once, downsampled, stored
        // locally — no network on later launches.
        SnapDarkCachedImage(
          url: url,
          size: side,
          errorBuilder: (_) => _fallback(context),
        ),
      );
    }
    final b64 = c?.logoBase64 ?? '';
    if (b64.isNotEmpty) {
      try {
        return framed(
          Image.memory(
            base64Decode(b64),
            width: side,
            height: side,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallback(context),
          ),
        );
      } catch (_) {/* fall through to the flag */}
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) {
    final c = cfg;
    final flag = c == null ? null : flagEmojiFor(c);
    final t = context.tokens;
    return Center(
      child: flag != null
          ? Text(flag, style: TextStyle(fontSize: 24 * scale))
          : Icon(
              Icons.public_rounded,
              size: 22 * scale,
              color: t.textMuted,
            ),
    );
  }
}
