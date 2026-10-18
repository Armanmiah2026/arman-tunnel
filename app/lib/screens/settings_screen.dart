import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/config_service.dart';
import '../services/settings_provider.dart';
import '../theme/sensei_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/ui/sensei_controls.dart';
import '../widgets/ui/sensei_modal.dart';
import 'route_rules_screen.dart';
import 'split_tunnel_screen.dart';

/// Settings tab: connection behaviour, appearance and engine tunables.
///
/// The whole page is one vertically scrollable column of sections (header +
/// 2-column card grid). Cards are content-sized and compact — no fixed
/// heights, no Expanded slots — so the layout cannot overflow on any screen
/// size or font scale, and grid rows keep equal heights via IntrinsicHeight.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(title: const Text('Settings')),
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
              // Fully scrollable, laid out by CONTENT height: no card is ever
              // squeezed into a fixed Expanded slot (the old paged layout
              // threw "BOTTOM OVERFLOWED BY n pixels" on short screens /
              // large fonts), no artificial empty space is injected, and the
              // bottom padding keeps the last row clear of the bottom
              // navigation on every screen size.
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  SenseiTokens.pageInset,
                  SenseiTokens.gapSm,
                  SenseiTokens.pageInset,
                  SenseiTokens.gapLg,
                ),
                child: Consumer<SettingsProvider>(
                  builder: (context, s, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionHeader(
                          title: 'Connection', icon: Icons.link_rounded),
                      _CardGrid(children: _connectionCards(s)),
                      const SizedBox(height: SenseiTokens.gap),
                      const _SectionHeader(
                          title: 'Appearance', icon: Icons.palette_outlined),
                      _CardGrid(children: _appearanceCards(context, s)),
                      const SizedBox(height: SenseiTokens.gap),
                      const _SectionHeader(
                          title: 'Engine', icon: Icons.memory_rounded),
                      _CardGrid(children: _engineCards(context, s)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Connection switches (2x2 grid).
  List<Widget> _connectionCards(SettingsProvider s) {
    return [
      _switchCard(
        icon: Icons.bolt_rounded,
        title: 'Wake Lock',
        subtitle: 'Keep the CPU awake while connected',
        value: s.wakeLock,
        onChanged: s.setWakeLock,
      ),
      _switchCard(
        icon: Icons.autorenew_rounded,
        title: 'Auto Reconnect',
        subtitle: 'Reconnect automatically if the tunnel drops',
        value: s.autoReconnect,
        onChanged: s.setAutoReconnect,
      ),
      _switchCard(
        icon: Icons.block_rounded,
        title: 'Kill Switch',
        subtitle: 'Block all traffic if the VPN drops',
        value: s.killSwitch,
        onChanged: s.setKillSwitch,
      ),
      _switchCard(
        icon: Icons.lan_rounded,
        title: 'Bypass LAN',
        subtitle: 'Keep local network traffic outside the tunnel',
        value: s.bypassLan,
        onChanged: s.setBypassLan,
      ),
    ];
  }

  /// Appearance cards (Theme + Wallpaper Mode).
  List<Widget> _appearanceCards(BuildContext context, SettingsProvider s) {
    return [
      _SettingCard(
        icon: s.themeMode == ThemeMode.light
            ? Icons.light_mode_rounded
            : Icons.dark_mode_rounded,
        title: 'Theme',
        subtitle: 'Switch between the dark and light palettes',
        // The compact segmented selector in the trailing slot IS the
        // control — no chevron, no card-level toggle (deliberately unlike
        // the ON/OFF switch cards), and no value text underneath.
        trailing: _ThemeSegmented(
          mode: s.themeMode,
          onChanged: (m) => s.setThemeMode(m),
        ),
      ),
      _SettingCard(
        icon: Icons.wallpaper_rounded,
        title: 'Wallpaper Mode',
        subtitle: 'Device wallpaper behind a glass UI',
        // Show WHICH wallpaper is applied (admin title / file name) so the
        // card reflects the admin-published gallery.
        value: s.hasWallpaper
            ? (s.wallpaperTitle.isEmpty ? 'On' : s.wallpaperTitle)
            : 'Off',
        onTap: () => _editWallpaper(context, s),
      ),
    ];
  }

  /// Engine / routing cards (2-column grid, three rows).
  List<Widget> _engineCards(BuildContext context, SettingsProvider s) {
    return [
      _SettingCard(
        icon: Icons.settings_ethernet_rounded,
        title: 'MTU',
        subtitle: 'Lower it if pages stall on mobile data',
        value: '${s.mtu}',
        onTap: () => _editMtu(context, s),
      ),
      _SettingCard(
        icon: Icons.dns_rounded,
        title: 'DNS Servers',
        subtitle: 'Resolvers used inside the tunnel, in order',
        // Show the whole list — with three resolvers, showing only the first
        // hid the fact that a backup existed.
        value: s.dnsServers.join(', '),
        onTap: () => _editDns(context, s),
      ),
      _SettingCard(
        icon: Icons.speed_rounded,
        title: 'Ping Target',
        subtitle: 'What the latency probe actually requests',
        value: s.pingEnabled ? (s.pingHost.isEmpty ? 'Default' : 'Custom') : 'Off',
        onTap: () => _editPing(context, s),
      ),
      _SettingCard(
        icon: Icons.health_and_safety_rounded,
        title: 'Keepalive',
        subtitle: 'Balance battery drain and idle tunnel drops',
        value: s.keepAliveLabel,
        onTap: () => _editKeepAlive(context, s),
      ),
      _SettingCard(
        icon: Icons.call_split_rounded,
        title: 'Split Tunnel',
        subtitle: 'Choose which apps use the tunnel',
        value: s.splitTunnelActive ? '${s.splitApps.length} app' : 'Off',
        onTap: () => _push(context, const SplitTunnelScreen()),
      ),
      _SettingCard(
        icon: Icons.alt_route_rounded,
        title: 'Direct / Block',
        subtitle: 'Send domains around the tunnel or drop them',
        value: s.routeRules.isEmpty ? 'None' : '${s.routeRules.length}',
        onTap: () => _push(context, const RouteRulesScreen()),
      ),
      _SettingCard(
        icon: Icons.memory_rounded,
        title: 'TLS & Mux',
        subtitle: 'Fragment the ClientHello, reuse connections',
        value: s.tlsFragment && s.muxEnabled ? 'Tuned' : 'Custom',
        onTap: () => _editEngine(context, s),
      ),
    ];
  }

  /// Wallpaper Mode configuration: standard bottom sheet with a LIVE
  /// preview (the picked image rendered behind sample Sensei cards), the two
  /// sources, and dim/blur/card-opacity sliders. Nothing touches
  /// the app background until "Apply".
  Future<void> _editWallpaper(BuildContext context, SettingsProvider s) {
    return SenseiModal.sheet<void>(
      context,
      maxHeightFactor: 0.94,
      builder: (sheetCtx) => _WallpaperConfigSheet(settings: s),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void _push(BuildContext context, Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  Widget _switchCard({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _SettingCard(
      icon: icon,
      title: title,
      subtitle: subtitle,
      active: value,
      onTap: () => onChanged(!value),
      trailing: Transform.scale(
        scale: 0.85,
        child: Switch(value: value, onChanged: onChanged),
      ),
    );
  }

  Future<void> _editMtu(BuildContext context, SettingsProvider s) async {
    final values = await SenseiModal.edit(
      context,
      title: 'MTU',
      description: 'Valid range 576–1500. 1500 is the default; drop to 1400 or '
          '1280 when packets are fragmented on mobile networks.',
      fields: [
        SenseiModalField(
          label: 'Bytes',
          hint: '1500',
          initialValue: '${s.mtu}',
          number: true,
        ),
      ],
    );
    if (values == null) return;
    await s.setMtu((int.tryParse(values.first) ?? 1500).clamp(576, 1500));
    if (context.mounted) AppToast.success(context, 'MTU updated');
  }

  /// One comma-separated line instead of two fixed fields: Android's Builder
  /// accepts any number of resolvers and tries them in order, so more than two
  /// is the only way one bad DNS stops breaking the whole tunnel.
  Future<void> _editDns(BuildContext context, SettingsProvider s) async {
    final values = await SenseiModal.edit(
      context,
      title: 'DNS Servers',
      description:
          'Comma-separated, tried in order. Google first is the safe default on local BDIX exits — a Cloudflare-only setup fails to resolve YouTube there.',
      fields: [
        SenseiModalField(
          label: 'Resolvers',
          hint: SettingsProvider.defaultDnsServers.join(', '),
          initialValue: s.dnsServers.join(', '),
        ),
      ],
    );
    if (values == null) return;
    await s.setDnsServers(values[0].split(','));
    if (context.mounted) {
      AppToast.success(
        context,
        'DNS updated — ${s.dnsServers.length} resolver${s.dnsServers.length == 1 ? '' : 's'}',
      );
    }
  }

  /// Ping card: target + HTTPS toggle in one dialog.
  Future<void> _editPing(BuildContext context, SettingsProvider s) async {
    final values = await SenseiModal.edit(
      context,
      title: 'Ping Probe',
      description: 'The probe sends a real HTTP request here and times the '
          'response. Leave the target empty for the default '
          '(${SettingsProvider.defaultPingHost}).',
      fields: [
        SenseiModalField(
          label: 'Enable Ping Probe',
          isBool: true,
          initialBool: s.pingEnabled,
        ),
        SenseiModalField(
          label: 'Host or URL',
          hint: SettingsProvider.defaultPingHost,
          initialValue: s.pingHost,
        ),
        SenseiModalField(
          label: 'Probe over HTTPS',
          isBool: true,
          initialBool: s.pingHttps,
        ),
        SenseiModalField(
          label: 'Write ping to Logs',
          isBool: true,
          initialBool: s.pingLogging,
        ),
      ],
    );
    if (values == null) return;
    await s.setPingEnabled(values[0] == 'true');
    await s.setPingHost(values[1]);
    await s.setPingHttps(values[2] == 'true');
    await s.setPingLogging(values[3] == 'true');
    if (context.mounted) AppToast.success(context, 'Ping probe updated');
  }

  /// Engine card: MTU + TLS fragmentation + mux in one dialog.
  Future<void> _editEngine(BuildContext context, SettingsProvider s) async {
    final values = await SenseiModal.edit(
      context,
      title: 'Engine Tunables',
      description: 'MTU 576–1500 (1500 default). TLS fragmentation splits the '
          'ClientHello to slip past inline DPI; mux reuses one connection for '
          'many streams.',
      fields: [
        SenseiModalField(
          label: 'MTU',
          hint: '1500',
          initialValue: '${s.mtu}',
          number: true,
        ),
        SenseiModalField(
          label: 'TLS Fragmentation',
          isBool: true,
          initialBool: s.tlsFragment,
        ),
        SenseiModalField(
          label: 'Connection Mux',
          isBool: true,
          initialBool: s.muxEnabled,
        ),
        SenseiModalField(
          label: 'OpenVPN: legacy ovpn3 engine',
          isBool: true,
          initialBool: s.ovpnUseOvpn3,
        ),
      ],
    );
    if (values == null) return;
    await s.setMtu((int.tryParse(values[0]) ?? 1500).clamp(576, 1500));
    await s.setTlsFragment(values[1] == 'true');
    await s.setMuxEnabled(values[2] == 'true');
    await s.setOvpnUseOvpn3(values[3] == 'true');
    if (context.mounted) AppToast.success(context, 'Engine updated');
  }

  Future<void> _editKeepAlive(BuildContext context, SettingsProvider s) async {
    final t = context.tokens;
    final picked = await SenseiModal.sheet<int>(
      context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Keepalive Mode',
            style: TextStyle(
              color: t.text,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: SenseiTokens.gapSm),
          Text(
            'Use Aggressive only on phones where the tunnel dies while idle. '
            'Battery Saver sends fewer keepalive packets.',
            style: TextStyle(color: t.textSecondary, height: 1.35),
          ),
          const SizedBox(height: SenseiTokens.gapMd),
          for (final item in const [
            (0, 'Battery Saver', 'Lowest drain, weakest idle protection'),
            (1, 'Balanced', 'Recommended for most devices'),
            (2, 'Aggressive', 'Best survival, higher battery use'),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                s.keepAliveMode == item.$1
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: t.accent,
              ),
              title: Text(item.$2),
              subtitle: Text(item.$3),
              onTap: () => Navigator.pop(ctx, item.$1),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await s.setKeepAliveMode(picked);
    if (context.mounted) AppToast.success(context, 'Keepalive updated');
  }
}

/// Overline section label with the accent icon, mirroring the header the old
/// grouped sections used to draw.
class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SectionHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(
        left: SenseiTokens.gapXs,
        bottom: SenseiTokens.gapSm,
      ),
      child: Row(
        children: [
          Icon(icon, color: t.accent, size: 15),
          const SizedBox(width: SenseiTokens.gapSm),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: t.overline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// One compact settings card: icon chip + title, optional trailing switch or
/// chevron, and stacked subtitle / value below.
class _SettingCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Current value rendered under the subtitle.
  final String? value;

  final VoidCallback? onTap;

  /// Replaces the chevron entirely (used for the toggle switch).
  final Widget? trailing;

  /// Accent-tinted highlight (a switch that is ON).
  final bool active;

  const _SettingCard({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.trailing,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tint = t.accent;
    return SenseiCard(
      onTap: onTap,
      active: active,
      radius: SenseiTokens.radiusMd,
      // Compact: content-sized card, no fixed heights anywhere — the row's
      // IntrinsicHeight keeps the two cards of a grid row equal.
      padding: const EdgeInsets.all(SenseiTokens.gapSm + 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: SenseiTokens.brSm,
                ),
                child: Icon(icon, color: tint, size: 15),
              ),
              const SizedBox(width: SenseiTokens.gapSm),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
              if (trailing != null)
                trailing!
              else if (onTap != null)
                Icon(Icons.chevron_right_rounded, color: t.textMuted, size: 18),
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                subtitle!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.textMuted,
                  fontSize: 10.5,
                  height: 1.3,
                ),
              ),
            ),
          if (value != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.textSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact Dark/Light segmented selector living in the Theme card's
/// trailing slot (where the chevron used to be).
///
/// Deliberately NOT an ON/OFF switch: a rounded pill track holding two
/// segments — moon = Dark, sun = Light. The active segment fills with the
/// accent (neon green on the dark palette); the other stays transparent
/// with a muted icon. Track and border follow the glass tokens so it sits
/// flush with the glassmorphism of the cards.
class _ThemeSegmented extends StatelessWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeSegmented({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    Widget segment({
      required bool selected,
      required IconData icon,
      required String label,
      required ThemeMode target,
    }) =>
        Tooltip(
          message: label,
          child: InkWell(
            onTap: () => onChanged(target),
            borderRadius: BorderRadius.circular(999),
            child: AnimatedContainer(
              duration: SenseiTokens.fast,
              curve: Curves.easeOut,
              width: 30,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? t.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(
                icon,
                size: 14,
                color: selected ? t.onAccent : t.textMuted,
              ),
            ),
          ),
        );

    final dark = mode != ThemeMode.light;
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: t.surfaceAltFill,
        borderRadius: SenseiTokens.brPill,
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(
            selected: dark,
            icon: Icons.dark_mode_rounded,
            label: 'Dark',
            target: ThemeMode.dark,
          ),
          segment(
            selected: !dark,
            icon: Icons.light_mode_rounded,
            label: 'Light',
            target: ThemeMode.light,
          ),
        ],
      ),
    );
  }
}

/// Lays cards out in a 2-column grid: rows of two with equal heights per row.
/// An odd trailing card spans the full row width.
class _CardGrid extends StatelessWidget {
  final List<Widget> children;

  const _CardGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      final hasPair = i + 1 < children.length;
      final isLastRow = i + 2 >= children.length;
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: children[i]),
              if (hasPair) ...[
                const SizedBox(width: SenseiTokens.gapSm),
                Expanded(child: children[i + 1]),
              ],
            ],
          ),
        ),
      );
      if (!isLastRow) rows.add(const SizedBox(height: SenseiTokens.gapSm));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

/// Where the glass-mode background comes from.
enum _WallpaperSource { admin, gallery }

/// A selectable option box (icon on top, label below) used by pickers here.
class _ShareBox extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ShareBox({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.surfaceAltFill,
      borderRadius: SenseiTokens.brMd,
      child: InkWell(
        onTap: onTap,
        borderRadius: SenseiTokens.brMd,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: SenseiTokens.gap),
          decoration: BoxDecoration(
            borderRadius: SenseiTokens.brMd,
            border: Border.all(color: t.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: t.accent, size: 22),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: t.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wallpaper Mode configuration: a standard bottom sheet with live preview.
///
/// Layout: live preview first (the actual candidate image behind sample
/// Sensei cards, with the dim/blur sliders applied in real time), source
/// boxes under it (Admin / Gallery), the tuning sliders, then
/// Remove + Apply. "Apply" is what writes the wallpaper + look to the
/// provider — the app background changes exactly then, never before.
class _WallpaperConfigSheet extends StatefulWidget {
  final SettingsProvider settings;
  const _WallpaperConfigSheet({required this.settings});

  @override
  State<_WallpaperConfigSheet> createState() => _WallpaperConfigSheetState();
}

class _WallpaperConfigSheetState extends State<_WallpaperConfigSheet> {
  /// The image being previewed (null = no wallpaper).
  Uint8List? _previewBytes;
  String? _previewPath;

  /// Display name of what is being previewed (admin title / file name).
  String _previewName = '';

  /// Admin wallpaper gallery (files downloaded by the config feed, with
  /// their panel titles). Loaded on open so the picker is ready before the
  /// user taps Admin.
  List<AdminWallpaper> _adminEntries = const [];

  double _dim = 0.35;
  double _blur = 0.0;
  double _cardOpacity = 0.55;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _dim = widget.settings.wallpaperDim;
    _blur = widget.settings.wallpaperBlur;
    _cardOpacity = widget.settings.wallpaperCardOpacity;
    // Live preview starts from the CURRENTLY applied wallpaper, if any.
    final current = widget.settings.wallpaperPath;
    if (current.isNotEmpty) {
      _previewPath = current;
      _previewName = widget.settings.wallpaperTitle;
    }
    _loadAdminGallery();
  }

  Future<void> _loadAdminGallery() async {
    try {
      final entries = await context.read<ConfigService>().adminWallpapers();
      if (mounted) setState(() => _adminEntries = entries);
    } catch (_) {/* gallery stays empty */}
  }

  bool get _isCurrent =>
      (_previewPath != null && _previewPath == widget.settings.wallpaperPath) ||
      (_previewBytes == null &&
          _previewPath == null &&
          !widget.settings.hasWallpaper);

  /// The title of the admin entry being previewed, if any — drives the
  /// caption shown on the preview.
  String get _previewAdminTitle {
    final p = _previewPath;
    if (p == null) return '';
    for (final e in _adminEntries) {
      if (e.path == p) return e.title;
    }
    return '';
  }

  /// Caption over the preview: what the user is looking at right now.
  String get _previewCaption {
    final adminTitle = _previewAdminTitle;
    if (adminTitle.isNotEmpty) return adminTitle;
    if (_previewName.trim().isNotEmpty) return _previewName.trim();
    if (widget.settings.hasWallpaper &&
        _previewPath == widget.settings.wallpaperPath) {
      return widget.settings.wallpaperTitle;
    }
    return '';
  }

  Future<void> _useSource(_WallpaperSource source) async {
    if (source == _WallpaperSource.admin) {
      // Refresh the gallery; single-entry galleries preview straight away,
      // larger ones are picked from the titled list below.
      await _loadAdminGallery();
      if (!mounted) return;
      if (_adminEntries.isEmpty) {
        setState(() => _error = 'No admin wallpaper published yet.');
        return;
      }
      if (_adminEntries.length == 1) {
        _previewAdmin(_adminEntries.first);
      }
      return;
    }
    // Gallery: the system image picker.
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final f = res?.files.firstOrNull;
      final bytes = f?.bytes;
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _error = 'Could not load that image.');
        return;
      }
      setState(() {
        _previewBytes = bytes;
        _previewPath = null; // new candidate, not yet persisted
        _previewName = f?.name
                .replaceAll(
                    RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false),
                    '')
                .trim() ??
            '';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Load an admin gallery entry into the preview (tap on the titled list).
  void _previewAdmin(AdminWallpaper entry) {
    setState(() {
      _previewPath = entry.path;
      _previewBytes = null;
      _previewName = entry.title;
      _error = null;
    });
  }

  Future<void> _apply() async {
    final bytes = _previewBytes;
    final path = _previewPath;
    if (bytes == null && (path == null || path.isEmpty)) {
      // Turning wallpaper OFF.
      await widget.settings.clearWallpaper();
      if (mounted) Navigator.pop(context);
      return;
    }
    setState(() => _busy = true);
    try {
      if (_previewBytes != null) {
        await widget.settings
            .setWallpaperBytes(_previewBytes!, title: _previewName);
      } else if (path != null &&
          path.isNotEmpty &&
          path != widget.settings.wallpaperPath) {
        // A picked file (admin gallery thumbnail): copy it in so later feed
        // refreshes can never swap the user's applied wallpaper. The admin
        // title travels along.
        await widget.settings.setWallpaperFile(File(path), title: _previewName);
      } else if (path == widget.settings.wallpaperPath) {
        // Re-applying the current file — only the look (or title) changed.
        await widget.settings.renameWallpaper(_previewName);
      }
      await widget.settings.setWallpaperLook(
        dim: _dim,
        blur: _blur,
        cardOpacity: _cardOpacity,
      );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _preview(double width, {double height = 210}) {
    final t = context.tokens;
    Widget image;
    if (_previewBytes != null) {
      image = Image.memory(_previewBytes!,
          fit: BoxFit.cover, width: width, cacheHeight: 420);
    } else if (_previewPath != null && _previewPath!.isNotEmpty) {
      image = Image.file(File(_previewPath!),
          fit: BoxFit.cover, width: width, cacheHeight: 420);
    } else {
      image = Container(
        width: width,
        color: t.surfaceAltFill,
        alignment: Alignment.center,
        child: Text(
          'No wallpaper selected',
          style: TextStyle(color: t.textMuted, fontSize: 12.5),
        ),
      );
    }
    // The preview applies the exact same transforms the shell will: blur
    // filter over the image, then the black dim scrim (Dim = darkness in
    // BOTH themes), then sample cards at the card opacity — what you see
    // here IS the app background.
    return ClipRRect(
      borderRadius: SenseiTokens.brLg,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (_blur > 0)
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: _blur, sigmaY: _blur),
                child: const SizedBox.expand(),
              ),
            ColoredBox(color: Colors.black.withValues(alpha: _dim)),
            Padding(
              padding: const EdgeInsets.all(SenseiTokens.gap),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_previewCaption.isNotEmpty)
                    Padding(
                      padding:
                          const EdgeInsets.only(bottom: SenseiTokens.gapSm),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: SenseiTokens.gapMd,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: SenseiTokens.brPill,
                        ),
                        child: Text(
                          _previewCaption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  Opacity(
                    opacity: _cardOpacity.clamp(0.0, 1.0),
                    child: Container(
                      padding: const EdgeInsets.all(SenseiTokens.gapMd),
                      decoration: BoxDecoration(
                        color: t.surface,
                        borderRadius: SenseiTokens.brMd,
                        border: Border.all(color: t.accent.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: t.accentWash,
                              borderRadius: SenseiTokens.brSm,
                            ),
                            child: Icon(Icons.shield_rounded,
                                color: t.accent, size: 18),
                          ),
                          const SizedBox(width: SenseiTokens.gapSm),
                          Expanded(
                            child: Text(
                              'Sample tunnel card',
                              style: TextStyle(
                                  color: t.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded,
                              color: t.textMuted, size: 18),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final width = MediaQuery.of(context).size.width;
    final selectedAdminIndex =
        _adminEntries.indexWhere((e) => e.path == _previewPath);
    Widget box(IconData icon, String label, _WallpaperSource source) =>
        _ShareBox(
          icon: icon,
          label: label,
          onTap: _busy ? null : () => _useSource(source),
        );
    Widget slider({
      required IconData icon,
      required String label,
      required double value,
      required double max,
      required ValueChanged<double> onChanged,
    }) =>
        Row(
          children: [
            Icon(icon, color: t.accent, size: 18),
            const SizedBox(width: SenseiTokens.gapSm),
            Text(label, style: TextStyle(color: t.text, fontSize: 12.5)),
            Expanded(
              child: Slider(
                value: value,
                max: max,
                onChanged: (v) => setState(() => onChanged(v)),
              ),
            ),
            SizedBox(
              width: 42,
              child: Text(
                '${(value * 100).round()}%',
                textAlign: TextAlign.right,
                style: t.mono(size: 11.5, color: t.textSecondary),
              ),
            ),
          ],
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.wallpaper_rounded, color: t.accent, size: 22),
            const SizedBox(width: SenseiTokens.gapSm),
            Text(
              'Wallpaper Mode',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: Icon(Icons.close_rounded, color: t.textSecondary),
            ),
          ],
        ),
        if (widget.settings.wallpaperPath.isNotEmpty) ...[
          const SizedBox(height: SenseiTokens.gapXs),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: widget.settings.wallpaperEnabled,
            onChanged: _busy
                ? null
                : (v) => widget.settings.setWallpaperEnabled(v),
            title: Text(
              'Wallpaper On/Off',
              style: TextStyle(color: t.text, fontSize: 13.5),
            ),
            subtitle: Text(
              'Pause glass mode without deleting this wallpaper',
              style: TextStyle(color: t.textSecondary, fontSize: 11.5),
            ),
          ),
        ],
        const SizedBox(height: SenseiTokens.gapSm),
        _preview(width - (SenseiTokens.gapLg * 2)),
        if (_error != null) ...[
          const SizedBox(height: SenseiTokens.gapSm),
          Text(_error!, style: TextStyle(color: t.alert, fontSize: 12)),
        ],
        const SizedBox(height: SenseiTokens.gapMd),
        Row(
          children: [
            Expanded(
              child: box(
                Icons.cloud_download_outlined,
                'Admin',
                _WallpaperSource.admin,
              ),
            ),
            const SizedBox(width: SenseiTokens.gapSm),
            Expanded(
              child: box(
                Icons.photo_library_outlined,
                'Gallery',
                _WallpaperSource.gallery,
              ),
            ),
          ],
        ),
        if (_adminEntries.isNotEmpty) ...[
          const SizedBox(height: SenseiTokens.gapSm),
          DropdownButtonFormField<int>(
            // (`initialValue` would not re-sync when the async admin-wallpaper
            // list first arrives, so `value` keeps the correct behavior.)
            // ignore: deprecated_member_use
            value: selectedAdminIndex >= 0 ? selectedAdminIndex : null,
            isDense: true,
            decoration: InputDecoration(
              labelText: 'Admin wallpapers',
              contentPadding: const EdgeInsets.symmetric(
                horizontal: SenseiTokens.gapMd,
                vertical: 9,
              ),
              border: OutlineInputBorder(
                borderRadius: SenseiTokens.brMd,
              ),
            ),
            items: [
              for (var i = 0; i < _adminEntries.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    _adminEntries[i].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (i) {
                    if (i != null) _previewAdmin(_adminEntries[i]);
                  },
          ),
        ],
        const SizedBox(height: SenseiTokens.gapMd),
        slider(
          icon: Icons.dark_mode_outlined,
          label: 'Dim',
          value: _dim,
          max: 1,
          onChanged: (v) => setState(() => _dim = v),
        ),
        slider(
          icon: Icons.blur_on_rounded,
          label: 'Blur',
          value: _blur,
          max: 20,
          onChanged: (v) => setState(() => _blur = v),
        ),
        slider(
          icon: Icons.opacity_rounded,
          label: 'Cards',
          value: _cardOpacity,
          max: 1,
          onChanged: (v) => setState(() => _cardOpacity = v),
        ),
        const SizedBox(height: SenseiTokens.gapMd),
        Row(
          children: [
            if (widget.settings.hasWallpaper || _previewBytes != null)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _previewBytes = null;
                            _previewPath = null;
                          }),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    color: t.alert,
                    size: 18,
                  ),
                  label: Text('Remove', style: TextStyle(color: t.alert)),
                ),
              ),
            if (widget.settings.hasWallpaper || _previewBytes != null)
              const SizedBox(width: SenseiTokens.gapSm),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _apply,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded, size: 18),
                label: Text(_isCurrent ? 'Applied' : 'Apply'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
