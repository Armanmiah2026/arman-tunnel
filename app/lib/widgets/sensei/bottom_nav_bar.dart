import 'package:flutter/material.dart';

import '../../theme/sensei_theme.dart';

/// Top-level destinations of the shell.
enum SenseiTab { home, configs, logs, settings }

/// Floating pill bottom navigation.
///
/// The active item expands to show its label; inactive items stay icon-only, so
/// four destinations fit comfortably on narrow phones.
class SenseiBottomNavBar extends StatelessWidget {
  final SenseiTab activeTab;
  final ValueChanged<SenseiTab> onTabSelected;

  const SenseiBottomNavBar({
    super.key,
    required this.activeTab,
    required this.onTabSelected,
  });

  static const _items = <(SenseiTab, String, IconData)>[
    (SenseiTab.home, 'Home', Icons.shield_rounded),
    (SenseiTab.configs, 'Configs', Icons.dns_rounded),
    (SenseiTab.logs, 'Logs', Icons.terminal_rounded),
    (SenseiTab.settings, 'Settings', Icons.tune_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Same responsive factor as the home dashboard (see senseiScale): the
    // pill shrinks with everything else on small / low-DPI screens instead
    // of staying a fixed bulk under scaled-down cards.
    final s = senseiScale(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          SenseiTokens.gap * s,
          SenseiTokens.gapSm * s,
          SenseiTokens.gap * s,
          SenseiTokens.gapMd * s,
        ),
        child: Row(
          // Horizontal-only centring. A `Center` here would centre the pill on
          // BOTH axes and, if this widget is ever given extra height, push it to
          // the middle of the screen — keep it pinned to the bottom slot.
          // `Flexible` stops the Row from granting infinite width, so the pill
          // honours maxWidth on tablets but never overflows on a phone.
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Container(
                constraints: const BoxConstraints(
                    maxWidth: SenseiTokens.maxContentWidth),
                padding: EdgeInsets.all(6 * s),
                decoration: BoxDecoration(
                  color: t.surfaceFill,
                  borderRadius: SenseiTokens.brPill,
                  border: Border.all(color: t.border),
                  boxShadow: [
                    // Shadow keeps the pill readable over ANY wallpaper in
                    // both themes: dark uses a deeper drop, light a soft one.
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: t.glass ? 0.28 : (t.isDark ? 0.45 : 0.06)),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: _items.map((item) {
                    final (tab, label, icon) = item;
                    final selected = tab == activeTab;
                    return Expanded(
                      flex: selected ? 5 : 3,
                      child: _NavItem(
                        label: label,
                        icon: icon,
                        selected: selected,
                        onTap: () => onTabSelected(tab),
                        scale: s,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  /// Shared home-scale factor (see [senseiScale]).
  final double scale;

  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = scale;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: SenseiTokens.brPill,
        child: AnimatedContainer(
          duration: SenseiTokens.medium,
          curve: Curves.easeOutCubic,
          height: 44 * s,
          padding: EdgeInsets.symmetric(horizontal: SenseiTokens.gapSm * s),
          decoration: BoxDecoration(
            color: selected ? t.accent : Colors.transparent,
            borderRadius: SenseiTokens.brPill,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 21 * s,
                color: selected ? t.onAccent : t.textMuted,
              ),
              // The label only exists on the active item; ClipRect keeps the
              // cross-fade from overflowing while the pill resizes.
              if (selected)
                Flexible(
                  child: ClipRect(
                    child: Padding(
                      padding: EdgeInsets.only(left: 7 * s),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                        style: TextStyle(
                          color: t.onAccent,
                          fontSize: 12.5 * s,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
