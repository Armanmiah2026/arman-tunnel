import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_provider.dart';
import '../theme/sensei_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/ui/sensei_controls.dart';
import '../widgets/ui/sensei_modal.dart';

/// Custom routing rules.
///
/// A rule sends traffic for a domain or IP/CIDR either `direct` (around the
/// tunnel) or `block` (dropped). Rules are folded into the xray JSON Dart-side,
/// so they apply to the xray protocols only — not SSH or OpenVPN. That caveat is
/// stated in the UI because it silently confused users before.
class RouteRulesScreen extends StatelessWidget {
  const RouteRulesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = context.watch<SettingsProvider>();
    final rules = s.routeRules;

    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(title: const Text('Route Rules')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addRule(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Rule'),
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
                  const Padding(
                    padding: EdgeInsets.fromLTRB(
                      SenseiTokens.pageInset,
                      SenseiTokens.gapSm,
                      SenseiTokens.pageInset,
                      SenseiTokens.gapMd,
                    ),
                    child: SenseiNotice(
                      message: 'Rules apply before the default proxy route on '
                          'the next connection. Domains are grouped first, then '
                          'IPs; they are built into the xray config, so SSH and '
                          'OpenVPN tunnels ignore them.',
                    ),
                  ),
                  Expanded(
                    child: rules.isEmpty
                        ? SenseiEmptyState(
                            icon: Icons.alt_route_rounded,
                            title: 'No rules yet',
                            message: 'Add a domain, geosite, IP or CIDR to send '
                                'it around the tunnel or drop it entirely.',
                            actionLabel: 'Add rule',
                            onAction: () => _addRule(context),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(
                              SenseiTokens.pageInset,
                              0,
                              SenseiTokens.pageInset,
                              SenseiTokens.gapXxl * 2,
                            ),
                            itemCount: rules.length,
                            itemBuilder: (_, i) {
                              final rule = rules[i];
                              final block = rule['action'] == 'block';
                              return Padding(
                                padding: const EdgeInsets.only(
                                  bottom: SenseiTokens.gapSm,
                                ),
                                child: SenseiCard(
                                  radius: SenseiTokens.radiusMd,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: SenseiTokens.gapMd,
                                    vertical: SenseiTokens.gapSm,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 34,
                                        height: 34,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: (block ? t.alert : t.accent)
                                              .withValues(alpha: 0.13),
                                          borderRadius: SenseiTokens.brSm,
                                        ),
                                        child: Icon(
                                          block
                                              ? Icons.block_rounded
                                              : Icons.alt_route_rounded,
                                          size: 17,
                                          color: block ? t.alert : t.accent,
                                        ),
                                      ),
                                      const SizedBox(
                                          width: SenseiTokens.gapMd),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              rule['value'] ?? '',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: t.mono(
                                                size: 13,
                                                color: t.text,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              block
                                                  ? 'Blocked before it leaves the device'
                                                  : 'Direct — bypasses the tunnel',
                                              style: TextStyle(
                                                color: t.textMuted,
                                                fontSize: 11.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Remove',
                                        icon: Icon(
                                          Icons.delete_outline_rounded,
                                          color: t.textMuted,
                                          size: 19,
                                        ),
                                        onPressed: () => context
                                            .read<SettingsProvider>()
                                            .removeRouteRuleAt(i),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _addRule(BuildContext context) async {
    final controller = TextEditingController();
    var action = 'direct';

    final added = await SenseiModal.sheet<bool>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final t = ctx.tokens;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SenseiSheetHeader(
                title: 'Add Route Rule',
                caption: 'Domain, geosite, IP or CIDR',
                onClose: () => Navigator.pop(ctx, false),
              ),
              const SizedBox(height: SenseiTokens.gapMd),
              SenseiField(
                label: 'Match',
                controller: controller,
                hint: 'netflix.com   •   1.2.3.4/24   •   2606:4700::/32',
                helper:
                    'Domains, IPs and CIDRs. geosite:/geoip: selectors are NOT '
                    'accepted — the geo databases are not bundled and a rule '
                    'using them would break the whole tunnel.',
                autofocus: true,
                mono: true,
              ),
              SenseiOptionRow(
                icon: Icons.alt_route_rounded,
                title: 'Direct',
                subtitle: 'Send this traffic around the tunnel',
                selected: action == 'direct',
                onTap: () => setSheet(() => action = 'direct'),
              ),
              SenseiOptionRow(
                icon: Icons.block_rounded,
                title: 'Block',
                subtitle: 'Drop this traffic on the device',
                selected: action == 'block',
                tint: t.alert,
                onTap: () => setSheet(() => action = 'block'),
              ),
              const SizedBox(height: SenseiTokens.gapSm),
              SenseiPrimaryButton(
                label: 'Add Rule',
                icon: Icons.add_rounded,
                onPressed: () {
                  final value = controller.text.trim();
                  if (value.isEmpty) return;
                  // geosite:/geoip: rules make xray fail to load (no .dat
                  // assets are bundled), which kills the entire tunnel.
                  if (value.startsWith('geosite:') || value.startsWith('geoip:')) {
                    Navigator.pop(ctx, false);
                    AppToast.error(
                      context,
                      'geosite:/geoip: selectors are not supported — add the '
                      'domain or IP range directly',
                    );
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
              ),
            ],
          );
        },
      ),
    );

    final value = controller.text.trim();
    controller.dispose();
    if (added != true || value.isEmpty || !context.mounted) return;
    await context.read<SettingsProvider>().addRouteRule(value, action);
    if (context.mounted) AppToast.success(context, 'Rule added');
  }
}
