import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../models/vpn_state.dart';
import '../services/config_service.dart';
import '../services/settings_provider.dart';
import '../theme/snapdark_theme.dart';
import '../utils/format.dart';
import '../widgets/ui/snapdark_controls.dart';

/// Live engine state: connection, throughput, transport, engine tunables and
/// config source. Refreshes once a second while open.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final vpn = context.watch<VpnState>();
    final cfg = context.watch<ConfigService>();
    final s = context.watch<SettingsProvider>();
    // While connected, report the CONNECTED tunnel — not whatever happens to
    // be selected right now (they can drift mid-session).
    ServerConfig? server = cfg.selectedServer;
    if (vpn.connectedServerName.isNotEmpty) {
      final match = cfg.servers
          .where((x) => x.displayName == vpn.connectedServerName)
          .toList();
      if (match.isNotEmpty) server = match.first;
    }
    final ok = vpn.isConnected;

    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(title: const Text('Diagnostics')),
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  SnapDarkTokens.pageInset,
                  SnapDarkTokens.gapSm,
                  SnapDarkTokens.pageInset,
                  SnapDarkTokens.gapXxl,
                ),
                children: [
                  SnapDarkNotice(
                    kind: ok
                        ? SnapDarkNoticeKind.success
                        : SnapDarkNoticeKind.warning,
                    message: ok
                        ? 'Tunnel is up. Traffic counters below come from the '
                            'native engine, and the state was confirmed by a real '
                            'round-trip through the local SOCKS port.'
                        : 'Tunnel is down. Connect to see live counters.',
                  ),
                  const SizedBox(height: SnapDarkTokens.gapLg),
                  SnapDarkSection(
                    title: 'Session',
                    icon: Icons.timeline_rounded,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SnapDarkStatRow(
                        label: 'State',
                        value: vpn.connectionStateText,
                        valueColor: ok ? t.accent : t.textMuted,
                      ),
                      SnapDarkStatRow(
                        label: 'Uptime',
                        value: formatDuration(vpn.connectionDuration),
                        mono: true,
                      ),
                      SnapDarkStatRow(
                        label: 'Tunnel',
                        value: vpn.connectedServerName.isNotEmpty
                            ? vpn.connectedServerName
                            : (server?.displayName ?? '—'),
                      ),
                      SnapDarkStatRow(
                        label: 'Endpoint',
                        value: server == null
                            ? '—'
                            : '${server.address}:${server.port}',
                        mono: true,
                        selectable: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: SnapDarkTokens.gapLg),
                  SnapDarkSection(
                    title: 'Traffic',
                    icon: Icons.swap_vert_rounded,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SnapDarkStatRow(
                        label: 'Download',
                        value: formatRate(vpn.downloadSpeed),
                        mono: true,
                        valueColor: ok ? t.accent : t.textMuted,
                      ),
                      SnapDarkStatRow(
                        label: 'Upload',
                        value: formatRate(vpn.uploadSpeed),
                        mono: true,
                        valueColor: ok ? t.accent : t.textMuted,
                      ),
                      SnapDarkStatRow(
                        label: 'Total down',
                        value: formatBytes(vpn.totalDownload),
                        mono: true,
                      ),
                      SnapDarkStatRow(
                        label: 'Total up',
                        value: formatBytes(vpn.totalUpload),
                        mono: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: SnapDarkTokens.gapLg),
                  SnapDarkSection(
                    title: 'Transport',
                    icon: Icons.lan_rounded,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SnapDarkStatRow(
                        label: 'Protocol',
                        value: server == null
                            ? '—'
                            : ProtocolVisual.labelFor(server.protocol),
                      ),
                      SnapDarkStatRow(
                        label: 'Network',
                        value: server?.transportLabel ?? '—',
                      ),
                      SnapDarkStatRow(
                        label: 'Security',
                        value:
                            server?.security.name.toUpperCase() ?? '—',
                      ),
                      SnapDarkStatRow(
                        label: 'Inject',
                        value: server == null
                            ? '—'
                            : server.injectMode.name.toUpperCase(),
                      ),
                      SnapDarkStatRow(
                        label: 'SNI',
                        value: s.customSni.isNotEmpty
                            ? '${s.customSni} (override)'
                            : (server?.sni?.isNotEmpty == true
                                ? server!.sni!
                                : '—'),
                        mono: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: SnapDarkTokens.gapLg),
                  SnapDarkSection(
                    title: 'Local Ports',
                    icon: Icons.settings_input_component_rounded,
                    caption: 'Only ports actually used by this tunnel are listed',
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      const SnapDarkStatRow(
                        label: 'SOCKS5',
                        value: '0.0.0.0:10808',
                        mono: true,
                        selectable: true,
                      ),
                      if (server == null || server.isV2rayFamily)
                        const SnapDarkStatRow(
                          label: 'HTTP',
                          value: '0.0.0.0:10809',
                          mono: true,
                          selectable: true,
                        ),
                      if (server != null && server.v2rayInjectActive)
                        const SnapDarkStatRow(
                          label: 'Inject relay',
                          value: '127.0.0.1:8089',
                          mono: true,
                        ),
                      if (server != null && server.isSshFamily)
                        const SnapDarkStatRow(
                          label: 'DNS-over-TCP',
                          value: '127.0.0.1:7353',
                          mono: true,
                        ),
                    ],
                  ),
                  const SizedBox(height: SnapDarkTokens.gapLg),
                  SnapDarkSection(
                    title: 'Engine & Source',
                    icon: Icons.memory_rounded,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SnapDarkStatRow(label: 'MTU', value: '${s.mtu}', mono: true),
                      SnapDarkStatRow(
                        label: 'DNS',
                        value: '${s.dnsPrimary} / ${s.dnsSecondary}',
                        mono: true,
                      ),
                      SnapDarkStatRow(
                        label: 'Split mode',
                        value: s.splitTunnelActive
                            ? '${s.splitMode} (${s.splitApps.length})'
                            : 'off',
                      ),
                      SnapDarkStatRow(
                        label: 'Route rules',
                        value: '${s.routeRules.length}',
                      ),
                      SnapDarkStatRow(
                        label: 'Official',
                        value: '${cfg.officialServers.length} tunnels',
                      ),
                      SnapDarkStatRow(
                        label: 'Custom',
                        value: '${cfg.customServers.length} tunnels',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
