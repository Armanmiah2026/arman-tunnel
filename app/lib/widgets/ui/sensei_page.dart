import 'package:flutter/material.dart';

import '../../theme/sensei_theme.dart';

/// Standard page shell: gradient background, themed app bar, safe area and a
/// max-width content column so wide screens don't stretch the layout.
///
/// Every screen in the app uses this instead of a bare [Scaffold] so headers,
/// insets and backgrounds cannot drift apart.
class SenseiPage extends StatelessWidget {
  /// App bar title. Omit for pages that draw their own header.
  final String? title;

  /// Optional line under the title.
  final String? subtitle;

  /// App bar trailing actions.
  final List<Widget> actions;

  /// Replaces the default back button.
  final Widget? leading;

  final Widget body;

  /// When true the body is wrapped in a scroll view with page padding applied.
  /// Use false for pages that host their own [ListView] or [Column]/[Expanded].
  final bool scrollable;

  /// Padding around [body]. Defaults to the standard page inset.
  final EdgeInsets? padding;

  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final Widget? drawer;
  final GlobalKey<ScaffoldState>? scaffoldKey;

  /// Constrain the body to [SenseiTokens.maxContentWidth] and centre it.
  final bool constrainWidth;

  const SenseiPage({
    super.key,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.leading,
    required this.body,
    this.scrollable = false,
    this.padding,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.drawer,
    this.scaffoldKey,
    this.constrainWidth = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = padding ??
        const EdgeInsets.fromLTRB(
          SenseiTokens.pageInset,
          SenseiTokens.gapSm,
          SenseiTokens.pageInset,
          SenseiTokens.gapXl,
        );

    Widget content = body;
    if (scrollable) {
      content = SingleChildScrollView(padding: pad, child: content);
    } else if (padding != null) {
      content = Padding(padding: pad, child: content);
    }
    if (constrainWidth) {
      content = Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: SenseiTokens.maxContentWidth),
          child: content,
        ),
      );
    }

    return Scaffold(
      key: scaffoldKey,
      drawer: drawer,
      backgroundColor: t.bg,
      extendBodyBehindAppBar: true,
      appBar: title == null
          ? null
          : AppBar(
              leading: leading,
              actions: actions,
              titleSpacing: leading == null ? SenseiTokens.gap : 0,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title!),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color: t.textMuted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: t.pageGradient,
          ),
        ),
        child: SafeArea(child: content),
      ),
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
    );
  }
}

/// Brand header used at the top of the home tab: wordmark + trailing action.
class SenseiBrandHeader extends StatelessWidget {
  final VoidCallback onMenuTap;

  /// Small status line under the wordmark (e.g. the active protocol).
  final String? status;

  /// Tint for the status dot. Defaults to muted.
  final Color? statusColor;

  final List<Widget> trailing;

  const SenseiBrandHeader({
    super.key,
    required this.onMenuTap,
    this.status,
    this.statusColor,
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Same responsive factor as the rest of the dashboard (see
    // senseiScale) so the header scales with the cards below it.
    final s = senseiScale(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        SenseiTokens.pageInset * s,
        SenseiTokens.gapMd * s,
        SenseiTokens.pageInset * s,
        SenseiTokens.gapSm * s,
      ),
      child: Row(
        children: [
          _IconSquare(icon: Icons.menu_rounded, onTap: onMenuTap, scale: s),
          SizedBox(width: SenseiTokens.gapMd * s),
          Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // FittedBox, not a bare Row: at high display densities
                  // (260/320/400 dpi on old phones) the slot between the menu
                  // button and the trailing actions drops below the wordmark's
                  // intrinsic width and the Row overflowed by up to ~90dp.
                  // scaleDown shrinks the lockup to fit instead of clipping it.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'SENSEI',
                          style: TextStyle(
                            color: t.text,
                            fontSize: 18 * s,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.6 * s,
                          ),
                        ),
                        SizedBox(width: 5 * s),
                        Text(
                          'TUNNEL',
                          style: TextStyle(
                            color: t.accent,
                            fontSize: 18 * s,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.6 * s,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (status != null)
                  Padding(
                    padding: EdgeInsets.only(top: 2 * s),
                    child: Row(
                      children: [
                        Container(
                          width: 6 * s,
                          height: 6 * s,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor ?? t.textMuted,
                          ),
                        ),
                        SizedBox(width: 6 * s),
                        Flexible(
                          child: Text(
                            status!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.textMuted,
                              fontSize: 11.5 * s,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4 * s,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

class _IconSquare extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  /// Shared home-scale factor (see [senseiScale]).
  final double scale;

  const _IconSquare({
    required this.icon,
    required this.onTap,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.surfaceFill,
      borderRadius: SenseiTokens.brMd,
      child: InkWell(
        onTap: onTap,
        borderRadius: SenseiTokens.brMd,
        child: Container(
          width: 42 * scale,
          height: 42 * scale,
          decoration: BoxDecoration(
            borderRadius: SenseiTokens.brMd,
            border: Border.all(color: t.border),
          ),
          child: Icon(icon, color: t.text, size: 21 * scale),
        ),
      ),
    );
  }
}
