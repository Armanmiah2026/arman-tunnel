import 'package:flutter/material.dart';

import '../../theme/snapdark_theme.dart';

/// Top-level destinations of the shell.
enum SnapDarkTab { home, configs, logs, settings }

/// Floating pill bottom navigation.
///
/// The active item expands to show its label; inactive items stay icon-only, so
/// four destinations fit comfortably on narrow phones.
class SnapDarkBottomNavBar extends StatelessWidget {
  final SnapDarkTab activeTab;
  final ValueChanged<SnapDarkTab> onTabSelected;

  const SnapDarkBottomNavBar({
    super.key,
    required this.activeTab,
    required this.onTabSelected,
  });

  static const _items = <(SnapDarkTab, String, IconData)>[
    (SnapDarkTab.home, 'Home', Icons.shield_rounded),
    (SnapDarkTab.configs, 'Configs', Icons.dns_rounded),
    (SnapDarkTab.logs, 'Logs', Icons.terminal_rounded),
    (SnapDarkTab.settings, 'Settings', Icons.tune_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Same responsive factor as the home dashboard (see snapdarkScale): the
    // pill shrinks with everything else on small / low-DPI screens instead
    // of staying a fixed bulk under scaled-down cards.
    final s = snapdarkScale(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          SnapDarkTokens.gap * s,
          SnapDarkTokens.gapSm * s,
          SnapDarkTokens.gap * s,
          SnapDarkTokens.gapMd * s,
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
                    maxWidth: SnapDarkTokens.maxContentWidth),
                padding: EdgeInsets.all(6 * s),
                decoration: BoxDecoration(
                  // Glass pill: a touch of translucency + a thin golden
                  // hairline ties the bar to the golden-lion home theme.
                  color: t.isDark
                      ? Color.alphaBlend(
                          t.surfaceFill, const Color(0x59000000))
                      : t.surfaceFill,
                  borderRadius: SnapDarkTokens.brPill,
                  border: Border.all(color: const Color(0x33E8C36A)),
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

  /// Shared home-scale factor (see [snapdarkScale]).
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
        borderRadius: SnapDarkTokens.brPill,
        child: AnimatedContainer(
          duration: SnapDarkTokens.medium,
          curve: Curves.easeOutCubic,
          height: 44 * s,
          padding: EdgeInsets.symmetric(horizontal: SnapDarkTokens.gapSm * s),
          decoration: BoxDecoration(
            color: selected ? t.accent : Colors.transparent,
            borderRadius: SnapDarkTokens.brPill,
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
