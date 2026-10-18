import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/config_service.dart';
import '../services/settings_provider.dart';
import '../services/vpn_service.dart';

import '../models/vpn_state.dart';
import '../theme/sensei_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/ui/sensei_controls.dart';
import '../widgets/ui/sensei_modal.dart';

/// Share the tunnel over a Wi-Fi hotspot.
///
/// Android cannot route a hotspot client's traffic through this app's VPN
/// interface, so sharing works by pointing each client at the engine's local
/// proxy ports (`10808` SOCKS / `10809` HTTP) on this phone's IP.
class HotspotScreen extends StatefulWidget {
  const HotspotScreen({super.key});

  @override
  State<HotspotScreen> createState() => _HotspotScreenState();
}

class _HotspotScreenState extends State<HotspotScreen> {
  static const int socksPort = 10808;
  static const int httpPort = 10809;

  String _ip = '';
  String _interfaceName = '';
  bool _loading = true;
  int _activeConnections = 0;
  List<String> _clientIps = const [];
  List<_HotspotEndpoint> _endpoints = const [];
  Timer? _statsTimer;

  @override
  void initState() {
    super.initState();
    _loadIp();
    _refreshStats();
    _statsTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _refreshStats());
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshStats() async {
    final st = await VpnService.proxyStats();
    if (!mounted) return;
    setState(() {
      _activeConnections = st['count'] as int? ?? 0;
      _clientIps = (st['devices'] as List).cast<String>();
    });
  }

  /// Prefer the user's saved endpoint, then private-range addresses clients can
  /// actually reach over hotspot/Wi-Fi/USB/Ethernet tethering.
  Future<void> _loadIp() async {
    setState(() => _loading = true);
    final settings = context.read<SettingsProvider>();
    var found = settings.hotspotIp;
    var foundName = settings.hotspotInterface;
    var endpoints = <_HotspotEndpoint>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        if (_isHiddenInterface(iface.name)) continue;
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.isEmpty) continue;
          endpoints.add(_HotspotEndpoint(name: iface.name, ip: ip));
        }
      }
      endpoints = _sortedEndpoints(endpoints);
      final savedStillExists = endpoints.any(
        (e) => e.ip == found && e.name == foundName,
      );
      if (!savedStillExists) {
        final best = endpoints.isEmpty ? null : endpoints.first;
        found = best?.ip ?? '';
        foundName = best?.name ?? '';
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _ip = found;
      _interfaceName = foundName;
      _endpoints = endpoints;
      _loading = false;
    });
  }

  List<_HotspotEndpoint> _sortedEndpoints(List<_HotspotEndpoint> endpoints) {
    final unique = <String, _HotspotEndpoint>{};
    for (final endpoint in endpoints) {
      unique['${endpoint.name}|${endpoint.ip}'] = endpoint;
    }
    final sorted = unique.values.toList();
    sorted.sort((a, b) {
      final privateCompare = b.isPrivate.toString().compareTo(
            a.isPrivate.toString(),
          );
      if (privateCompare != 0) return privateCompare;
      return a.name.compareTo(b.name);
    });
    return sorted;
  }

  bool _isHiddenInterface(String name) {
    final n = name.toLowerCase();
    return n.startsWith('tun') ||
        n.startsWith('ppp') ||
        n.startsWith('lo') ||
        n.startsWith('dummy') ||
        n.startsWith('clat') ||
        n.startsWith('ipsec') ||
        n.startsWith('wg');
  }

  Future<bool> _pickEndpoint({bool required = false}) async {
    final settings = context.read<SettingsProvider>();
    await _loadIp();
    if (!mounted) return false;
    if (_endpoints.isEmpty) {
      AppToast.warning(context, 'No reachable IPv4 interface found');
      return false;
    }
    if (_endpoints.length == 1 && !required) return true;

    final selected = await SenseiModal.sheet<_HotspotEndpoint>(
      context,
      padded: false,
      scrollable: false,
      builder: (context) => _EndpointPicker(
        endpoints: _endpoints,
        selectedIp: _ip,
      ),
    );
    if (selected == null) return false;
    await settings.setHotspotEndpoint(
      ip: selected.ip,
      name: selected.name,
    );
    if (!mounted) return false;
    setState(() {
      _ip = selected.ip;
      _interfaceName = selected.name;
    });
    return true;
  }

  Future<void> _manualEndpoint() async {
    final settings = context.read<SettingsProvider>();
    final values = await SenseiModal.edit(
      context,
      title: 'Manual Share IP',
      description: 'Use this when Android hides the hotspot interface. Enter the '
          'phone IP shown by your hotspot/tether settings.',
      fields: [
        SenseiModalField(
          label: 'IP address',
          hint: '192.168.43.1',
          initialValue: _ip,
        ),
      ],
    );
    if (values == null) return;
    final ip = values.first.trim();
    if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(ip)) {
      if (mounted) AppToast.error(context, 'Enter a valid IPv4 address');
      return;
    }
    await settings.setHotspotEndpoint(
          ip: ip,
          name: 'manual',
        );
    if (!mounted) return;
    setState(() {
      _ip = ip;
      _interfaceName = 'manual';
    });
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) AppToast.success(context, 'Copied $value');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final connected = context.watch<VpnState>().isConnected;
    final ipText = _loading ? '…' : (_ip.isEmpty ? 'unavailable' : _ip);
    final interfaceText =
        _interfaceName.isEmpty ? 'auto-detected' : _interfaceName;

    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(
        title: const Text('Hotspot Share'),
        actions: [
          IconButton(
            tooltip: 'Re-detect IP',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadIp,
          ),
          const SizedBox(width: SenseiTokens.gapXs),
        ],
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
                    kind: connected
                        ? SenseiNoticeKind.success
                        : SenseiNoticeKind.warning,
                    icon: connected
                        ? Icons.wifi_tethering_rounded
                        : Icons.wifi_tethering_off_rounded,
                    message: connected
                        ? 'Tunnel is up. Turn on your phone hotspot, then set the '
                            'proxy below on each client.'
                        : 'Connect the tunnel first — the proxy ports only carry '
                            'traffic while the engine is running.',
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  Consumer<SettingsProvider>(
                    builder: (context, s, _) => SenseiSwitchTile(
                      icon: Icons.wifi_tethering_rounded,
                      title: 'Hotspot Share',
                      subtitle: s.hotspotShare
                          ? 'Proxy endpoints bind network-wide — clients on this '
                              'hotspot can use them at $_ip:$socksPort'
                          : 'Proxy endpoints are local-only. No external device '
                              'can reach them until you enable sharing.',
                      value: s.hotspotShare,
                      onChanged: (v) async {
                        if (v && !await _pickEndpoint(required: true)) return;
                        await s.setHotspotShare(v);
                        if (!context.mounted) return;
                        AppToast.success(
                          context,
                          v
                              ? 'Hotspot share enabled. Restart the tunnel to apply.'
                              : 'Hotspot share disabled. Restart the tunnel to apply.',
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Live Activity',
                    icon: Icons.radar_rounded,
                    caption: 'Active proxy connections on this phone',
                    children: [
                      SenseiTile(
                        icon: Icons.devices_rounded,
                        title: 'Active devices',
                        subtitle: _clientIps.isEmpty
                            ? 'No clients connected right now · $_activeConnections active connection${_activeConnections == 1 ? '' : 's'}'
                            : '${_clientIps.length} device${_clientIps.length == 1 ? '' : 's'} · '
                                '${_clientIps.join(', ')} · $_activeConnections active connection${_activeConnections == 1 ? '' : 's'}',
                        trailing: Text(
                          '${_clientIps.length}',
                          style: t.mono(
                            size: 22,
                            weight: FontWeight.w800,
                            color:
                                _clientIps.isNotEmpty ? t.accent : t.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiCard(
                    hero: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('THIS PHONE', style: t.overline),
                        const SizedBox(height: SenseiTokens.gapSm),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                ipText,
                                style: t.mono(
                                  size: 26,
                                  weight: FontWeight.w800,
                                  color: _ip.isEmpty ? t.textMuted : t.text,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Select IP',
                              icon: Icon(
                                Icons.account_tree_rounded,
                                color: t.accent,
                              ),
                              onPressed: () => _pickEndpoint(required: true),
                            ),
                            IconButton(
                              tooltip: 'Manual IP',
                              icon: Icon(
                                Icons.edit_location_alt_rounded,
                                color: t.accent,
                              ),
                              onPressed: _manualEndpoint,
                            ),
                            IconButton(
                              tooltip: 'Copy IP',
                              icon: Icon(Icons.copy_rounded, color: t.accent),
                              onPressed: _ip.isEmpty ? null : () => _copy(_ip),
                            ),
                          ],
                        ),
                        const SizedBox(height: SenseiTokens.gapXs),
                        Text(
                          'Interface: $interfaceText',
                          style: TextStyle(
                            color: t.textMuted,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  SenseiSection(
                    title: 'Proxy Endpoints',
                    icon: Icons.settings_input_component_rounded,
                    caption: 'OpenVPN exposes SOCKS5 only; V2Ray and SSH also '
                        'expose HTTP on 10809',
                    children: [
                      SenseiTile(
                        icon: Icons.dns_rounded,
                        title: 'SOCKS5',
                        subtitle:
                            _ip.isEmpty ? 'Port $socksPort' : '$_ip:$socksPort',
                        trailing: _CopyButton(
                          onTap: _ip.isEmpty
                              ? null
                              : () => _copy('$_ip:$socksPort'),
                        ),
                      ),
                      Builder(builder: (context) {
                        // OpenVPN has no HTTP proxy: hide it there.
                        final cfg = context.watch<ConfigService>();
                        final server = cfg.selectedServer;
                        final hasHttp = server == null ||
                            server.isV2rayFamily ||
                            server.isSshFamily;
                        if (!hasHttp) return const SizedBox.shrink();
                        return SenseiTile(
                          icon: Icons.http_rounded,
                          title: 'HTTP',
                          subtitle:
                              _ip.isEmpty ? 'Port $httpPort' : '$_ip:$httpPort',
                          trailing: _CopyButton(
                            onTap: _ip.isEmpty
                                ? null
                                : () => _copy('$_ip:$httpPort'),
                          ),
                        );
                      }),
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapLg),
                  const SenseiSection(
                    title: 'How To',
                    icon: Icons.list_alt_rounded,
                    divided: false,
                    children: [
                      _Step(1, 'Connect the tunnel on this phone.'),
                      _Step(
                          2, 'Turn on your Wi-Fi hotspot in Android settings.'),
                      _Step(3, 'Join that hotspot from the other device.'),
                      _Step(
                        4,
                        'Set its Wi-Fi proxy to the IP and port above. SOCKS5 '
                        'carries UDP; HTTP does not.',
                      ),
                    ],
                  ),
                  const SizedBox(height: SenseiTokens.gapMd),
                  Text(
                    'SSH tunnels cannot carry UDP at all, so QUIC-heavy apps on '
                    'clients may fall back to TCP.',
                    style: TextStyle(
                      color: t.textMuted,
                      fontSize: 11.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: SenseiTokens.gapSm),
                  const SenseiNotice(
                    kind: SenseiNoticeKind.warning,
                    message:
                        'Anyone on this hotspot can use your tunnel through the '
                        'proxy above — there is no password. Share only with '
                        'devices you trust.',
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

class _HotspotEndpoint {
  final String name;
  final String ip;

  const _HotspotEndpoint({required this.name, required this.ip});

  bool get isPrivate =>
      ip.startsWith('10.') || ip.startsWith('192.168.') || _isPrivate172(ip);

  static bool _isPrivate172(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4 || parts.first != '172') return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }
}

class _EndpointPicker extends StatelessWidget {
  final List<_HotspotEndpoint> endpoints;
  final String selectedIp;

  const _EndpointPicker({required this.endpoints, required this.selectedIp});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SenseiCard(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(SenseiTokens.gapLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select Share IP',
                style: TextStyle(
                  color: t.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: SenseiTokens.gapSm),
              Text(
                'Choose the hotspot, Wi-Fi, USB tether, Ethernet, or modem IP '
                'clients should use for the proxy.',
                style: TextStyle(color: t.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: SenseiTokens.gapMd),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: endpoints.length,
                  itemBuilder: (context, index) {
                    final endpoint = endpoints[index];
                    final selected = endpoint.ip == selectedIp;
                    return SenseiTile(
                      icon: selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      title: endpoint.ip,
                      subtitle:
                          '${endpoint.name}${endpoint.isPrivate ? ' · private/LAN' : ''}',
                      onTap: () => Navigator.pop(context, endpoint),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _CopyButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return IconButton(
      tooltip: 'Copy',
      onPressed: onTap,
      icon: Icon(
        Icons.copy_rounded,
        size: 18,
        color: onTap == null ? t.textMuted : t.accent,
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int index;
  final String text;
  const _Step(this.index, this.text);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: SenseiTokens.gapMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.accentWash,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: TextStyle(
                color: t.accent,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: SenseiTokens.gapMd),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: t.textSecondary,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
