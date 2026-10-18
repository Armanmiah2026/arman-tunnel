import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../services/server_ping_cache.dart';
import '../services/settings_provider.dart';
import '../theme/sensei_theme.dart';
import '../utils/format.dart';
import 'ui/cached_image.dart';
import 'ui/sensei_controls.dart';

/// Row in the tunnel list.
///
/// Shows the protocol identity, the transport, DPI-bypass flags that are
/// actually active on this config, and ONE kebab (⋮) for the per-config
/// actions (note / share / edit / delete) — the old stack of four floating
/// mini-icons read as clutter; the actions now live in a branded sheet.
class ServerCard extends StatelessWidget {
  final ServerConfig server;
  final bool isSelected;
  final bool isConnected;
  final VoidCallback onTap;
  final VoidCallback? onMenu;

  const ServerCard({
    super.key,
    required this.server,
    required this.isSelected,
    required this.isConnected,
    required this.onTap,
    this.onMenu,
  });

  /// Extra capability chips beyond the protocol/transport/method badges.
  List<String> get _extras {
    final out = <String>[];
    if (server.payloadEnhanced) out.add('SPLIT');
    if (server.sshCompression) out.add('ZLIB');
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tint = ProtocolVisual.tint(server.protocol, t);
    // VIP state is honest on the card: crown = locked (watch an ad), filled
    // crown + check = already open (VIP device or valid unlock window).
    final vipOpen = context.watch<SettingsProvider>().isVipUnlocked(
          server.id,
          vip: server.vip,
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: SenseiTokens.gapSm),
      child: SenseiCard(
        onTap: onTap,
        active: isSelected,
        radius: SenseiTokens.radiusMd,
        padding: const EdgeInsets.all(SenseiTokens.gapMd),
        child: Row(
          children: [
            _Avatar(server: server, tint: tint),
            const SizedBox(width: SenseiTokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          server.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isConnected ? t.accent : t.text,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (server.vip) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: vipOpen
                              ? 'VIP — unlocked'
                              : 'VIP — unlock with a short ad',
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Icon(
                                Icons.workspace_premium_rounded,
                                size: 15,
                                color: vipOpen ? t.accent : t.lime,
                              ),
                              Positioned(
                                right: -3,
                                bottom: -2,
                                child: Icon(
                                  vipOpen
                                      ? Icons.check_circle_rounded
                                      : Icons.lock_rounded,
                                  size: 9,
                                  color:
                                      vipOpen ? t.accent : t.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (isConnected) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: t.accent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: t.accent.withValues(alpha: 0.6),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (server.locked) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.lock_rounded, size: 13, color: t.alert),
                      ],
                    ],
                  ),
                  // Sharer's note directly under the name (user request) —
                  // small, muted, NO "note:" label (same convention as the
                  // name, which carries no "name:" label either). Hidden when
                  // blank or identical to the displayed name.
                  if (server.note.trim().isNotEmpty &&
                      server.note.trim() != server.displayName)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        server.note.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.textMuted,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      SenseiBadge(label: server.protocolLabel, color: tint),
                      SenseiBadge(
                        label: server.transportLabel,
                        color: t.textMuted,
                      ),
                      if (server.methodLabel.isNotEmpty)
                        SenseiBadge(
                          label: server.methodLabel,
                          color: t.lime,
                        ),
                      // Measured latency for THIS server, refreshed by
                      // ServerPingCache while the list is on screen.
                      _PingBadge(serverId: server.id),
                      for (final f in _extras)
                        SenseiBadge(label: f, color: t.lime),
                      if (server.author != null && server.author!.isNotEmpty)
                        SenseiBadge(
                          label: server.author!,
                          color: t.accentDeep,
                        ),
                    ],
                  ),
                  // Locked configs hide their server identity (IP/port) — the
                  // admin publishes them but must not leak the backend address.
                  if (server.locked)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        'Locked by admin',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.mono(size: 11, color: t.alert),
                      ),
                    )
                  else if (!server.isOfficial &&
                      server.displayAddress.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        server.displayAddress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.mono(size: 11, color: t.textMuted),
                      ),
                    ),
                ],
              ),
            ),
            if (onMenu != null)
              Tooltip(
                message: 'Actions',
                child: InkWell(
                  onTap: onMenu,
                  borderRadius: SenseiTokens.brSm,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 10,
                    ),
                    child: Icon(
                      Icons.more_vert_rounded,
                      size: 22,
                      color: t.textMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final ServerConfig server;
  final Color tint;
  const _Avatar({required this.server, required this.tint});

  @override
  Widget build(BuildContext context) {
    // Admin-supplied logo wins (hosted image first, then embedded base64);
    // otherwise show the protocol glyph/flag. Hosted logos render through
    // the permanent low-quality cache — downloaded once, downsampled to
    // avatar resolution and stored locally (no network on later launches).
    final url = server.logoUrl;
    if (url != null && url.trim().isNotEmpty) {
      return ClipRRect(
        borderRadius: SenseiTokens.brSm,
        child: SenseiCachedImage(
          url: url.trim(),
          size: 42,
          errorBuilder: (_) => _base64OrGlyph(context),
        ),
      );
    }
    return _base64OrGlyph(context);
  }

  Widget _base64OrGlyph(BuildContext context) {
    final b64 = server.logoBase64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        return ClipRRect(
          borderRadius: SenseiTokens.brSm,
          child: Image.memory(
            base64Decode(b64),
            width: 42,
            height: 42,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _glyph(context),
          ),
        );
      } catch (_) {
        return _glyph(context);
      }
    }
    return _glyph(context);
  }

  Widget _glyph(BuildContext context) {
    // No logo image → the REAL flag emoji (user decision). The ISO chip
    // (GeoGlyph) read as a letter pair; Android's emoji font renders the
    // regional indicators fine on every device this app ships to.
    final flag = flagEmojiFor(server);
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.13),
        borderRadius: SenseiTokens.brSm,
        border: Border.all(color: tint.withValues(alpha: 0.28)),
      ),
      child: flag != null
          ? Text(flag, style: const TextStyle(fontSize: 24))
          : Icon(
              ProtocolVisual.iconFor(server.protocol),
              color: tint,
              size: 20,
            ),
    );
  }
}

/// Latency badge for one server card.
///
/// Renders nothing until the first probe answers (so the list does not flash a
/// row of "—" on every rebuild), then shows the measured ms. Green is fast,
/// amber is slow, and an unreachable endpoint is amber too rather than red —
/// the palette is green/lime with amber for trouble.
class _PingBadge extends StatelessWidget {
  final String serverId;
  const _PingBadge({required this.serverId});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: ServerPingCache.instance,
      builder: (context, _) {
        final ms = ServerPingCache.instance.pingOf(serverId);
        if (ms == null) return const SizedBox.shrink();
        // Live-ping DOT (user request): a colored dot whose color follows
        // the measured latency — green (fast) / yellow (medium) / red (slow
        // or no reply). The ms value rides next to it for the exact number.
        final (Color dot, String label) = ms < 0
            ? (t.alert, 'no reply')
            : ms <= 150
                ? (t.accent, '${ms}ms')
                : ms <= 400
                    ? (t.lime, '${ms}ms')
                    : (t.alert, '${ms}ms');
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dot,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: dot.withValues(alpha: 0.55),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: dot,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          ],
        );
      },
    );
  }
}
