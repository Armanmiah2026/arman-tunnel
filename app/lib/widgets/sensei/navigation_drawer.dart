import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../screens/account_screen.dart';
import '../../screens/connection_history_screen.dart';
import '../../screens/diagnostics_screen.dart';
import '../../screens/flutter_error_log_screen.dart';
import '../../screens/hotspot_screen.dart';
import '../../screens/support_screen.dart';
import '../../services/config_service.dart';
import '../../services/vpn_service.dart';
import '../../theme/sensei_theme.dart';
import '../app_toast.dart';
import '../sensei_logo.dart';
import 'bottom_nav_bar.dart';

/// Side navigation — NON-SETTINGS features only.
///
/// Grouped into quick actions and
/// "System" (OS handoffs). Settings-managed options (Split Tunnel, Route
/// Rules, DNS, theme…) live in the Settings tab ONLY — nothing here may
/// duplicate them.
class SenseiNavigationDrawer extends StatelessWidget {
  final SenseiTab currentTab;
  final String version;
  final ValueChanged<SenseiTab> onNavigateTab;
  final VoidCallback onOpenSpeedTest;
  final VoidCallback onOpenAbout;
  final VoidCallback onCloseDrawer;

  const SenseiNavigationDrawer({
    super.key,
    required this.currentTab,
    required this.version,
    required this.onNavigateTab,
    required this.onOpenSpeedTest,
    required this.onOpenAbout,
    required this.onCloseDrawer,
  });

  void _push(BuildContext context, Widget screen) {
    onCloseDrawer();
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  void _goTab(SenseiTab tab) {
    onNavigateTab(tab);
    onCloseDrawer();
  }

  List<Widget> _menuItems(BuildContext context) {
    return [
      const _GroupLabel('Quick'),
      _Item(
        icon: Icons.tune_rounded,
        label: 'Settings',
        selected: currentTab == SenseiTab.settings,
        onTap: () => _goTab(SenseiTab.settings),
      ),
      _Item(
        icon: Icons.speed_rounded,
        label: 'Speed Test',
        onTap: () {
          onCloseDrawer();
          onOpenSpeedTest();
        },
      ),
      const SizedBox(height: SenseiTokens.gapLg),
      const _GroupLabel('Advanced'),
      _Item(
        icon: Icons.wifi_tethering_rounded,
        label: 'Hotspot Share',
        onTap: () => _push(context, const HotspotScreen()),
      ),
      _Item(
        icon: Icons.monitor_heart_outlined,
        label: 'Diagnostics',
        onTap: () => _push(context, const DiagnosticsScreen()),
      ),
      _Item(
        icon: Icons.history_rounded,
        label: 'Connection History',
        onTap: () => _push(context, const ConnectionHistoryScreen()),
      ),
      _Item(
        icon: Icons.vpn_key_rounded,
        label: 'My Access',
        onTap: () => _push(context, const AccountScreen()),
      ),
      if (kDebugMode)
        _Item(
          icon: Icons.bug_report_outlined,
          label: 'Error Logs',
          onTap: () => _push(context, const FlutterErrorLogScreen()),
        ),
      const SizedBox(height: SenseiTokens.gapLg),
      const _GroupLabel('System'),
      _Item(
        icon: Icons.sim_card_rounded,
        label: 'APN Settings',
        onTap: () {
          onCloseDrawer();
          VpnService.openApnSettings();
        },
      ),
      _Item(
        icon: Icons.signal_cellular_alt_rounded,
        label: '4G/5G Switcher',
        onTap: () {
          onCloseDrawer();
          VpnService.openNetworkModeSettings();
        },
      ),
      _Item(
        icon: Icons.battery_charging_full_rounded,
        label: 'Battery Optimization',
        onTap: () {
          onCloseDrawer();
          VpnService.ignoreBatteryOptimization();
        },
      ),
      _Item(
        icon: Icons.sync_rounded,
        label: 'Reload Configs',
        onTap: () => _reloadConfigs(context),
      ),
      _Item(
        icon: Icons.help_outline_rounded,
        label: 'Help Center',
        onTap: () => _push(context, const SupportScreen()),
      ),
      _Item(
        icon: Icons.info_outline_rounded,
        label: 'About',
        onTap: () {
          onCloseDrawer();
          onOpenAbout();
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final content = SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SenseiTokens.gapSm),
        child: Column(
          children: [
            _Header(version: version),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: SenseiTokens.gap),
                children: _menuItems(context),
              ),
            ),
          ],
        ),
      ),
    );
    // Glass mode keeps the drawer flush with the Scaffold edge and blurs the
    // wallpaper/root content behind it. The border is deliberately omitted:
    // a side stroke made the panel look detached from the status bar.
    if (!t.glass) return Drawer(child: content);
    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(color: t.surfaceFill),
          child: content,
        ),
      ),
    );
  }

  Future<void> _reloadConfigs(BuildContext context) async {
    final cfg = context.read<ConfigService>();
    onCloseDrawer();
    await cfg.loadServers(manual: true);
    if (context.mounted) {
      if (cfg.lastRefreshFailed) {
        AppToast.warning(context, 'Reload failed — showing cached configs');
      } else {
        AppToast.success(
            context, 'Configs reloaded (${cfg.officialServers.length})');
      }
    }
  }
}

class _Header extends StatelessWidget {
  final String version;
  const _Header({required this.version});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SenseiTokens.gapSm,
        SenseiTokens.gapLg,
        SenseiTokens.gapSm,
        SenseiTokens.gap,
      ),
      child: Row(
        children: [
          const SenseiLogo(size: 52),
          const SizedBox(width: SenseiTokens.gapMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Arman Tunnel',
                  style: TextStyle(
                    color: t.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  'v$version • multi-protocol',
                  style: TextStyle(color: t.textMuted, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String label;
  const _GroupLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: SenseiTokens.gapSm,
        bottom: SenseiTokens.gapSm,
      ),
      child: Text(label.toUpperCase(), style: context.tokens.overline),
    );
  }
}

class _Item extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Item({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? t.accentWash : Colors.transparent,
        borderRadius: SenseiTokens.brMd,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          borderRadius: SenseiTokens.brMd,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SenseiTokens.gapSm,
              vertical: SenseiTokens.gapMd - 1,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Icon(
                    icon,
                    size: 19,
                    color: selected ? t.accent : t.textSecondary,
                  ),
                ),
                const SizedBox(width: SenseiTokens.gapMd + 2),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: selected ? t.accent : t.text,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
