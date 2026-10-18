import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../models/vpn_state.dart';
import '../services/config_service.dart';
import '../services/settings_provider.dart';
import '../theme/sensei_theme.dart';
import '../utils/format.dart';
import '../widgets/ui/sensei_controls.dart';

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
                maxWidth: SenseiTokens.maxContentWidth,
              ),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  SenseiTokens.pageInset,
                  SenseiTokens.gapSm,
                  SenseiTokens.pageInset,
                  SenseiTokens.gapXxl,
                ),
                children: [
                  SenseiNotice(
                    kind: ok
                        ? SenseiNoticeKind.success
                        : SenseiNoticeKind.warning,
                    message: ok
                        ? 'Tunnel is up. Traffic counters below come from the '
                            'native engine, and the state was confirmed by a real '
                            'round-trip through the local SOCKS port.'
                        : 'Tunnel is down. Connect to see live counters.',
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Session',
                    icon: Icons.timeline_rounded,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SenseiStatRow(
                        label: 'State',
                        value: vpn.connectionStateText,
                        valueColor: ok ? t.accent : t.textMuted,
                      ),
                      SenseiStatRow(
                        label: 'Uptime',
                        value: formatDuration(vpn.connectionDuration),
                        mono: true,
                      ),
                      SenseiStatRow(
                        label: 'Tunnel',
                        value: vpn.connectedServerName.isNotEmpty
                            ? vpn.connectedServerName
                            : (server?.displayName ?? '—'),
                      ),
                      SenseiStatRow(
                        label: 'Endpoint',
                        value: server == null
                            ? '—'
                            : '${server.address}:${server.port}',
                        mono: true,
                        selectable: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Traffic',
                    icon: Icons.swap_vert_rounded,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SenseiStatRow(
                        label: 'Download',
                        value: formatRate(vpn.downloadSpeed),
                        mono: true,
                        valueColor: ok ? t.accent : t.textMuted,
                      ),
                      SenseiStatRow(
                        label: 'Upload',
                        value: formatRate(vpn.uploadSpeed),
                        mono: true,
                        valueColor: ok ? t.accent : t.textMuted,
                      ),
                      SenseiStatRow(
                        label: 'Total down',
                        value: formatBytes(vpn.totalDownload),
                        mono: true,
                      ),
                      SenseiStatRow(
                        label: 'Total up',
                        value: formatBytes(vpn.totalUpload),
                        mono: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Transport',
                    icon: Icons.lan_rounded,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SenseiStatRow(
                        label: 'Protocol',
                        value: server == null
                            ? '—'
                            : ProtocolVisual.labelFor(server.protocol),
                      ),
                      SenseiStatRow(
                        label: 'Network',
                        value: server?.transportLabel ?? '—',
                      ),
                      SenseiStatRow(
                        label: 'Security',
                        value:
                            server?.security.name.toUpperCase() ?? '—',
                      ),
                      SenseiStatRow(
                        label: 'Inject',
                        value: server == null
                            ? '—'
                            : server.injectMode.name.toUpperCase(),
                      ),
                      SenseiStatRow(
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
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Local Ports',
                    icon: Icons.settings_input_component_rounded,
                    caption: 'Only ports actually used by this tunnel are listed',
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      const SenseiStatRow(
                        label: 'SOCKS5',
                        value: '0.0.0.0:10808',
                        mono: true,
                        selectable: true,
                      ),
                      if (server == null || server.isV2rayFamily)
                        const SenseiStatRow(
                          label: 'HTTP',
                          value: '0.0.0.0:10809',
                          mono: true,
                          selectable: true,
                        ),
                      if (server != null && server.v2rayInjectActive)
                        const SenseiStatRow(
                          label: 'Inject relay',
                          value: '127.0.0.1:8089',
                          mono: true,
                        ),
                      if (server != null && server.isSshFamily)
                        const SenseiStatRow(
                          label: 'DNS-over-TCP',
                          value: '127.0.0.1:7353',
                          mono: true,
                        ),
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Engine & Source',
                    icon: Icons.memory_rounded,
                    padding: EdgeInsets.zero,
                    divided: false,
                    children: [
                      SenseiStatRow(label: 'MTU', value: '${s.mtu}', mono: true),
                      SenseiStatRow(
                        label: 'DNS',
                        value: '${s.dnsPrimary} / ${s.dnsSecondary}',
                        mono: true,
                      ),
                      SenseiStatRow(
                        label: 'Split mode',
                        value: s.splitTunnelActive
                            ? '${s.splitMode} (${s.splitApps.length})'
                            : 'off',
                      ),
                      SenseiStatRow(
                        label: 'Route rules',
                        value: '${s.routeRules.length}',
                      ),
                      SenseiStatRow(
                        label: 'Official',
                        value: '${cfg.officialServers.length} tunnels',
                      ),
                      SenseiStatRow(
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
