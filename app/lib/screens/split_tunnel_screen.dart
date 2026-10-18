import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_provider.dart';
import '../services/vpn_service.dart';
import '../theme/sensei_theme.dart';
import '../widgets/ui/sensei_controls.dart';

/// Per-app split tunneling.
///
/// Three modes: off (everything tunneled), exclude (listed apps bypass) and
/// include (only listed apps are tunneled). The engine refuses to start in
/// exclude/include mode with an empty list, so the footer keeps the count
/// visible while picking.
class SplitTunnelScreen extends StatefulWidget {
  const SplitTunnelScreen({super.key});

  @override
  State<SplitTunnelScreen> createState() => _SplitTunnelScreenState();
}

class _SplitTunnelScreenState extends State<SplitTunnelScreen> {
  List<Map<String, dynamic>> _apps = const [];
  bool _loading = true;
  String _query = '';
  bool _showSystem = false;

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  Future<void> _loadApps() async {
    setState(() => _loading = true);
    final apps = await VpnService.installedApps();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> _filtered(Set<String> selected) {
    var list = _apps.where((a) {
      if (!_showSystem && a['system'] == true && !selected.contains(a['package'])) {
        return false;
      }
      if (_query.isEmpty) return true;
      return (a['name'] as String).toLowerCase().contains(_query) ||
          (a['package'] as String).toLowerCase().contains(_query);
    }).toList();
    // Selected apps float to the top so the current choice is always visible.
    list.sort((a, b) {
      final sa = selected.contains(a['package']) ? 0 : 1;
      final sb = selected.contains(b['package']) ? 0 : 1;
      if (sa != sb) return sa - sb;
      return (a['name'] as String)
          .toLowerCase()
          .compareTo((b['name'] as String).toLowerCase());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = context.watch<SettingsProvider>();
    final enabled = s.splitMode != 'off';
    final selected = s.splitApps;
    final list = _filtered(selected);

    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(
        title: const Text('Split Tunnel'),
        actions: [
          IconButton(
            tooltip: _showSystem ? 'Hide system apps' : 'Show system apps',
            icon: Icon(
              _showSystem ? Icons.android_rounded : Icons.apps_rounded,
            ),
            onPressed: () => setState(() => _showSystem = !_showSystem),
          ),
          if (selected.isNotEmpty)
            IconButton(
              tooltip: 'Clear selection',
              icon: const Icon(Icons.clear_all_rounded),
              onPressed: () =>
                  context.read<SettingsProvider>().clearSplitApps(),
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
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      SenseiTokens.pageInset,
                      SenseiTokens.gapSm,
                      SenseiTokens.pageInset,
                      SenseiTokens.gapMd,
                    ),
                    child: SenseiSegmented<String>(
                      values: const ['off', 'exclude', 'include'],
                      selected: s.splitMode,
                      onChanged: (m) =>
                          context.read<SettingsProvider>().setSplitMode(m),
                      label: (m) => switch (m) {
                        'exclude' => 'Exclude',
                        'include' => 'Only these',
                        _ => 'Off',
                      },
                      iconFor: (m) => switch (m) {
                        'exclude' => Icons.block_rounded,
                        'include' => Icons.check_circle_outline_rounded,
                        _ => Icons.all_inclusive_rounded,
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SenseiTokens.pageInset,
                    ),
                    child: SenseiNotice(
                      kind: enabled && selected.isEmpty
                          ? SenseiNoticeKind.warning
                          : SenseiNoticeKind.info,
                      message: switch (s.splitMode) {
                        'include' => selected.isEmpty
                            ? 'Pick at least one app — the tunnel will not start '
                                'with an empty include list.'
                            : '${selected.length} app'
                                '${selected.length == 1 ? '' : 's'} will use the '
                                'tunnel. Everything else goes direct.',
                        'exclude' => selected.isEmpty
                            ? 'Pick at least one app — the tunnel will not start '
                                'with an empty exclude list.'
                            : '${selected.length} app'
                                '${selected.length == 1 ? '' : 's'} will bypass the '
                                'tunnel. Everything else is tunneled.',
                        _ => 'Every app uses the tunnel. Switch mode to carve out '
                            'exceptions.',
                      },
                    ),
                  ),
                  if (!enabled)
                    const Expanded(
                      child: SenseiEmptyState(
                        icon: Icons.all_inclusive_rounded,
                        title: 'Split tunneling is off',
                        message: 'All apps route through the VPN.',
                      ),
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        SenseiTokens.pageInset,
                        SenseiTokens.gapMd,
                        SenseiTokens.pageInset,
                        SenseiTokens.gapSm,
                      ),
                      child: SenseiSearchField(
                        hint: 'Search apps…',
                        onChanged: (v) =>
                            setState(() => _query = v.trim().toLowerCase()),
                      ),
                    ),
                    Expanded(
                      child: _loading
                          ? Center(
                              child: CircularProgressIndicator(color: t.accent),
                            )
                          : list.isEmpty
                              ? const SenseiEmptyState(
                                  icon: Icons.search_off_rounded,
                                  title: 'No apps match',
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.fromLTRB(
                                    SenseiTokens.pageInset,
                                    0,
                                    SenseiTokens.pageInset,
                                    SenseiTokens.gapXl,
                                  ),
                                  itemCount: list.length,
                                  itemBuilder: (_, i) {
                                    final app = list[i];
                                    final pkg = app['package'] as String;
                                    return _AppRow(
                                      name: app['name'] as String,
                                      package: pkg,
                                      system: app['system'] == true,
                                      checked: selected.contains(pkg),
                                      onChanged: (v) => context
                                          .read<SettingsProvider>()
                                          .toggleSplitApp(pkg, v),
                                    );
                                  },
                                ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  final String name;
  final String package;
  final bool system;
  final bool checked;
  final ValueChanged<bool> onChanged;

  const _AppRow({
    required this.name,
    required this.package,
    required this.system,
    required this.checked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: SenseiTokens.gapSm),
      child: SenseiCard(
        onTap: () => onChanged(!checked),
        active: checked,
        radius: SenseiTokens.radiusMd,
        padding: const EdgeInsets.symmetric(
          horizontal: SenseiTokens.gapMd,
          vertical: SenseiTokens.gapMd - 2,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.surfaceAltFill,
                borderRadius: SenseiTokens.brSm,
              ),
              child: Icon(
                system ? Icons.android_rounded : Icons.apps_rounded,
                color: checked ? t.accent : t.textMuted,
                size: 18,
              ),
            ),
            const SizedBox(width: SenseiTokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    package,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.mono(size: 10.5, color: t.textMuted),
                  ),
                ],
              ),
            ),
            Checkbox(
              value: checked,
              onChanged: (v) => onChanged(v ?? false),
            ),
          ],
        ),
      ),
    );
  }
}
