import 'package:flutter/material.dart';

import '../../theme/snapdark_theme.dart';
import '../snapdark/golden_lion_background.dart';

/// Bordered panel used for every grouped block in the app.
class SnapDarkCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  /// Draw the accent-tinted border/fill used for "active" panels.
  final bool active;

  /// Use the hero gradient instead of a flat fill.
  final bool hero;

  final VoidCallback? onTap;
  final double radius;

  const SnapDarkCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(SnapDarkTokens.gap),
    this.active = false,
    this.hero = false,
    this.onTap,
    this.radius = SnapDarkTokens.radiusLg,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final br = BorderRadius.circular(radius);
    // Over the full-screen golden-lion backdrop (home dashboard) every card
    // turns to glass: a faint white wash with a golden hairline, so the 3D
    // lion keeps shining through the panels while text keeps its contrast.
    // Everywhere else the card keeps its exact theme fill — nothing else in
    // the app changes.
    final lion = GoldenLionScope.of(context);
    // Active fill: the accent wash composited ON the card surface, not IN
    // PLACE of it. Painting the wash alone (the old way) made active cards
    // read as a dark tint slab in glass mode — on light glass the wash's
    // translucency let the wallpaper through differently than the inactive
    // cards beside it, so the ON switches (Wake Lock etc.) looked like they
    // carried a dark-mode layer. Compositing keeps the same readable base
    // as every other card and tints it green.
    final fill = t.glass
        ? Color.alphaBlend(t.accentWash, t.surfaceFill)
        : t.accentWash;
    final decorated = AnimatedContainer(
      duration: SnapDarkTokens.fast,
      padding: padding,
      decoration: BoxDecoration(
        color: hero
            ? null
            : active
                ? fill
                : lion
                    // white @ 12% — the glassmorphism fill from the brief.
                    ? Colors.white.withValues(alpha: 0.12)
                    : t.surfaceFill,
        gradient: hero
            ? LinearGradient(
                colors: lion
                    ? [
                        Colors.white.withValues(alpha: 0.16),
                        Colors.white.withValues(alpha: 0.07),
                      ]
                    : t.heroGradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        borderRadius: br,
        border: Border.all(
          color: active
              ? t.accent
              : lion
                  // Thin golden border around every glass panel.
                  ? const Color(0x59E8C36A)
                  : t.border,
          width: active ? 1.4 : 1,
        ),
      ),
      child: child,
    );

    if (onTap == null) return decorated;
    return Material(
      color: Colors.transparent,
      borderRadius: br,
      child: InkWell(onTap: onTap, borderRadius: br, child: decorated),
    );
  }
}

/// Titled group: an overline label plus a [SnapDarkCard] holding [children].
///
/// Children are laid out in a column with hairline dividers between them, which
/// is how every settings-style list in the app is built.
class SnapDarkSection extends StatelessWidget {
  final String title;
  final String? caption;
  final IconData? icon;
  final List<Widget> children;

  /// Trailing widget on the header row (e.g. a counter or an action).
  final Widget? trailing;

  /// Insert hairline dividers between children.
  final bool divided;

  /// Padding inside the card. Rows supply their own padding, so this defaults
  /// to zero for divided lists.
  final EdgeInsets? padding;

  const SnapDarkSection({
    super.key,
    required this.title,
    this.caption,
    this.icon,
    required this.children,
    this.trailing,
    this.divided = true,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (divided && i != children.length - 1) {
        items.add(Divider(height: 1, color: t.border));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: SnapDarkTokens.gapXs,
            bottom: SnapDarkTokens.gapSm,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: t.accent, size: 15),
                const SizedBox(width: SnapDarkTokens.gapSm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title.toUpperCase(), style: t.overline),
                    if (caption != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          caption!,
                          style: TextStyle(color: t.textMuted, fontSize: 11.5),
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
        SnapDarkCard(
          padding: padding ?? (divided ? EdgeInsets.zero : const EdgeInsets.all(SnapDarkTokens.gap)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: items,
          ),
        ),
      ],
    );
  }
}

/// A row inside a [SnapDarkSection]: leading icon, title, subtitle, trailing
/// value + chevron.
class SnapDarkTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Right-aligned value text.
  final String? value;

  final VoidCallback? onTap;

  /// Replaces the value/chevron block entirely.
  final Widget? trailing;

  /// Tint the icon and value with the alert colour (for destructive rows).
  final bool danger;

  const SnapDarkTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.trailing,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tint = danger ? t.alert : t.accent;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SnapDarkTokens.gap,
          vertical: SnapDarkTokens.gapMd + 1,
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: SnapDarkTokens.brSm,
              ),
              child: Icon(icon, color: tint, size: 18),
            ),
            const SizedBox(width: SnapDarkTokens.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: danger ? t.alert : t.text,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: TextStyle(
                          color: t.textMuted,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else ...[
              if (value != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: Text(
                    value!,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (onTap != null) ...[
                const SizedBox(width: SnapDarkTokens.gapXs),
                Icon(Icons.chevron_right_rounded, color: t.textMuted, size: 20),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Toggle row inside a [SnapDarkSection].
class SnapDarkSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  const SnapDarkSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return SnapDarkTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: enabled ? () => onChanged(!value) : null,
      trailing: Switch(value: value, onChanged: enabled ? onChanged : null),
    );
  }
}

/// Small pill label (protocol, transport, status…).
class SnapDarkBadge extends StatelessWidget {
  final String label;
  final Color? color;
  final IconData? icon;

  /// Filled = solid tint background; otherwise a translucent wash.
  final bool filled;

  /// Responsive shrink factor (dashboard scaling on small screens). 1.0
  /// everywhere except the home cards, which pass the shared home scale.
  final double scale;

  const SnapDarkBadge({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.filled = false,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tint = color ?? t.accent;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 8 * scale,
        vertical: 3 * scale,
      ),
      decoration: BoxDecoration(
        color: filled ? tint : tint.withValues(alpha: 0.14),
        borderRadius: SnapDarkTokens.brPill,
        border: Border.all(color: filled ? tint : tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11 * scale, color: filled ? t.onAccent : tint),
            SizedBox(width: 4 * scale),
          ],
          Text(
            label,
            style: TextStyle(
              color: filled ? t.onAccent : tint,
              fontSize: 10.5 * scale,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3 * scale,
            ),
          ),
        ],
      ),
    );
  }
}

/// Segmented control. Used for theme mode, split-tunnel mode, usage period and
/// the import/manual switch — previously four hand-rolled implementations.
class SnapDarkSegmented<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final ValueChanged<T> onChanged;
  final String Function(T) label;
  final IconData? Function(T)? iconFor;

  /// Compact removes icons and shrinks the vertical padding.
  final bool compact;

  const SnapDarkSegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.label,
    this.iconFor,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.surfaceAlt,
        borderRadius: SnapDarkTokens.brMd,
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: values.map((v) {
          final on = v == selected;
          final icon = iconFor?.call(v);
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(v),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: SnapDarkTokens.fast,
                padding: EdgeInsets.symmetric(vertical: compact ? 7 : 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? t.accent : Colors.transparent,
                  borderRadius: SnapDarkTokens.brSm,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null && !compact) ...[
                      Icon(icon,
                          size: 18, color: on ? t.onAccent : t.textMuted),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      label(v),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: on ? t.onAccent : t.textSecondary,
                        fontSize: compact ? 11.5 : 12.5,
                        fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Selectable option row used by pickers (protocol, duration, mode…).
class SnapDarkOptionRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  /// Override the selection tint (used by the amber "Block" action).
  final Color? tint;

  const SnapDarkOptionRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.selected,
    required this.onTap,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final accent = tint ?? t.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: SnapDarkTokens.gapSm),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.13) : t.surfaceAlt,
        borderRadius: SnapDarkTokens.brMd,
        child: InkWell(
          onTap: onTap,
          borderRadius: SnapDarkTokens.brMd,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SnapDarkTokens.gapMd + 2,
              vertical: SnapDarkTokens.gapMd,
            ),
            decoration: BoxDecoration(
              borderRadius: SnapDarkTokens.brMd,
              border: Border.all(
                color: selected ? accent : t.border,
                width: selected ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon,
                      size: 19, color: selected ? accent : t.textSecondary),
                  const SizedBox(width: SnapDarkTokens.gapMd),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: selected ? accent : t.text,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitle!,
                            style: TextStyle(
                              color: t.textMuted,
                              fontSize: 11.5,
                              height: 1.3,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (selected)
                  Container(
                    width: 22,
                    height: 22,
                    decoration:
                        BoxDecoration(shape: BoxShape.circle, color: accent),
                    child: Icon(Icons.check_rounded,
                        size: 14, color: t.onAccent),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Centred placeholder for empty lists and "nothing captured yet" states.
class SnapDarkEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;

  /// Optional call to action.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Use the success tint (for "no errors captured" style positives).
  final bool positive;

  const SnapDarkEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.positive = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tint = positive ? t.accent : t.textMuted;
    // Scroll-safe AND still centred: the inner ConstrainedBox carries the
    // viewport's own height as MIN height, so the column fills the slot and
    // centres its content exactly like the old Center(Padding(...)) — until
    // the slot gets shorter than the placeholder (high-density phones leave
    // <120dp under a pinned panel), where it starts scrolling instead of
    // painting RenderFlex stripes.
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          // Only echo the slot height when it is actually bounded — inside a
          // ListView/Column (unbounded) minHeight would have to be 0.
          constraints: BoxConstraints(
            minHeight: box.maxHeight.isFinite ? box.maxHeight : 0,
          ),
          child: Padding(
            padding: const EdgeInsets.all(SnapDarkTokens.gapXxl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tint.withValues(alpha: 0.10),
                border: Border.all(color: tint.withValues(alpha: 0.28)),
              ),
              child: Icon(icon, color: tint, size: 30),
            ),
            const SizedBox(height: SnapDarkTokens.gap),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: t.text,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: SnapDarkTokens.gapSm),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: t.textMuted,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: SnapDarkTokens.gapLg),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Labelled form field with consistent spacing. The visual style comes from the
/// global [InputDecorationTheme].
class SnapDarkField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? helper;
  final bool number;
  final bool obscure;
  final int maxLines;
  final Widget? suffix;
  final Widget? prefix;
  final bool mono;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const SnapDarkField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.helper,
    this.number = false,
    this.obscure = false,
    this.maxLines = 1,
    this.suffix,
    this.prefix,
    this.mono = false,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: SnapDarkTokens.gapMd + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 2),
              child: Text(
                label,
                style: TextStyle(
                  color: t.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          TextField(
            controller: controller,
            obscureText: obscure,
            autofocus: autofocus,
            maxLines: obscure ? 1 : maxLines,
            keyboardType: number ? TextInputType.number : TextInputType.text,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
            style: mono
                ? t.mono(size: 13, weight: FontWeight.w500)
                : TextStyle(color: t.text, fontSize: 14),
            decoration: InputDecoration(
              hintText: hint,
              suffixIcon: suffix,
              prefixIcon: prefix,
            ),
          ),
          if (helper != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 2),
              child: Text(
                helper!,
                style: TextStyle(
                  color: t.textMuted,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Search input used by the tunnel list, app picker and server sheet.
class SnapDarkSearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;

  const SnapDarkSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(color: t.text, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(Icons.search_rounded, color: t.textMuted, size: 20),
        border: OutlineInputBorder(
          borderRadius: SnapDarkTokens.brMd,
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: SnapDarkTokens.brMd,
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: SnapDarkTokens.brMd,
          borderSide: BorderSide(color: t.accent, width: 1.4),
        ),
      ),
    );
  }
}

/// Dropdown with the same chrome as [SnapDarkField].
class SnapDarkDropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<T> items;
  final String Function(T) itemLabel;
  final ValueChanged<T> onChanged;

  const SnapDarkDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: SnapDarkTokens.gapMd + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text(
              label,
              style: TextStyle(
                color: t.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: t.surfaceAlt,
              borderRadius: SnapDarkTokens.brSm,
              border: Border.all(color: t.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                borderRadius: SnapDarkTokens.brMd,
                dropdownColor: t.surfaceHigh,
                icon: Icon(Icons.expand_more_rounded, color: t.textMuted),
                padding: const EdgeInsets.symmetric(
                  horizontal: SnapDarkTokens.gapMd + 2,
                ),
                style: TextStyle(color: t.text, fontSize: 14),
                // DropdownButton asserts EXACTLY ONE item carries [value] —
                // a value outside [items] (editing a config whose protocol
                // the form's fixed list lacks, e.g. an imported http_proxy
                // node) used to crash the whole form. Render the current
                // value as an extra item instead: the real selection stays
                // visible and truthful, and the assert can never fire.
                items: (items.contains(value) ? items : [...items, value])
                    .map((e) => DropdownMenuItem(
                          value: e,
                          child: Text(itemLabel(e)),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width primary action button.
class SnapDarkPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;

  const SnapDarkPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: busy ? null : onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.textMuted,
                ),
              )
            else if (icon != null)
              Icon(icon, size: 19),
            if (busy || icon != null) const SizedBox(width: SnapDarkTokens.gapSm),
            Text(label),
          ],
        ),
      ),
    );
  }
}

/// Key/value row for info panels (diagnostics, device info, about).
class SnapDarkStatRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  final Color? valueColor;

  /// Render the value with the monospace face (IPs, byte counts, timers).
  final bool mono;

  /// Allow the user to select/copy the value.
  final bool selectable;

  const SnapDarkStatRow({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.valueColor,
    this.mono = false,
    this.selectable = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = mono
        ? t.mono(size: 12.5, color: valueColor ?? t.text)
        : TextStyle(
            color: valueColor ?? t.text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SnapDarkTokens.gap,
        vertical: SnapDarkTokens.gapMd - 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: t.textMuted),
            const SizedBox(width: SnapDarkTokens.gapSm),
          ],
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                color: t.textMuted,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: selectable
                ? SelectableText(value, style: style, textAlign: TextAlign.right)
                : Text(value, style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

/// Inline notice strip: neutral info, caution, or alert.
enum SnapDarkNoticeKind { info, success, warning, alert }

class SnapDarkNotice extends StatelessWidget {
  final String message;
  final SnapDarkNoticeKind kind;
  final IconData? icon;

  const SnapDarkNotice({
    super.key,
    required this.message,
    this.kind = SnapDarkNoticeKind.info,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (Color tint, IconData fallback) = switch (kind) {
      SnapDarkNoticeKind.info => (t.accent, Icons.info_outline_rounded),
      SnapDarkNoticeKind.success => (t.accent, Icons.check_circle_outline_rounded),
      SnapDarkNoticeKind.warning => (t.warning, Icons.warning_amber_rounded),
      SnapDarkNoticeKind.alert => (t.alert, Icons.error_outline_rounded),
    };
    return Container(
      padding: const EdgeInsets.all(SnapDarkTokens.gapMd + 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: SnapDarkTokens.brMd,
        border: Border.all(color: tint.withValues(alpha: 0.40)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? fallback, color: tint, size: 19),
          const SizedBox(width: SnapDarkTokens.gapMd),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: t.text, fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// Header for a modal sheet or dialog: title, optional caption, close button.
class SnapDarkSheetHeader extends StatelessWidget {
  final String title;
  final String? caption;
  final VoidCallback onClose;

  const SnapDarkSheetHeader({
    super.key,
    required this.title,
    this.caption,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: t.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (caption != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    caption!,
                    style: TextStyle(color: t.textMuted, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          onPressed: onClose,
          icon: Icon(Icons.close_rounded, color: t.textSecondary),
        ),
      ],
    );
  }
}
