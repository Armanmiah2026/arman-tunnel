import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../theme/sensei_theme.dart';
import 'sensei_controls.dart';

/// Modal helpers.
///
/// Every dialog and bottom sheet in the app goes through these functions so
/// padding, corner radii, scrim and button order are identical everywhere. The
/// visual chrome is token-based (`popup`/`sheet`), so whatever sits behind a
/// dialog — including the wallpaper — frosts instead of showing through
/// untouched.
class SenseiModal {
  const SenseiModal._();

  static const _barrierBlur = 14.0;

  static Color _barrierColor(SenseiTokens t) =>
      Colors.black.withValues(alpha: t.isDark ? 0.72 : 0.5);

  /// Centered popup with the standard blurred + dimmed barrier. Replaces
  /// `showDialog` everywhere so every popup frosts the screen behind it.
  static Future<T?> popup<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool dismissible = true,
  }) {
    final t = context.tokens;
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: dismissible,
      barrierLabel: 'dismiss',
      barrierColor: _barrierColor(t),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => Center(child: Builder(builder: builder)),
      transitionBuilder: (ctx, anim, __, child) => AnimatedBuilder(
        animation: anim,
        builder: (_, c) {
          final v = Curves.easeOut.transform(anim.value);
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                      sigmaX: _barrierBlur * v, sigmaY: _barrierBlur * v),
                  child: const SizedBox.shrink(),
                ),
              ),
              Opacity(opacity: v, child: c),
            ],
          );
        },
        child: child,
      ),
    );
  }

  /// Read-only information dialog. [lines] are rendered as paragraphs; an empty
  /// string becomes a spacer.
  static Future<void> info(
    BuildContext context, {
    required String title,
    required List<String> lines,
    IconData icon = Icons.info_outline_rounded,
  }) {
    final t = context.tokens;
    return popup<void>(
      context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: SenseiTokens.gapLg,
          vertical: SenseiTokens.gapXl,
        ),
        clipBehavior: Clip.antiAlias,
        icon: _ModalGlyph(icon: icon),
        title: Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: t.text,
            fontSize: 18,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.2,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lines.map((line) {
              if (line.trim().isEmpty) {
                return const SizedBox(height: SenseiTokens.gapMd);
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  line,
                  style: TextStyle(
                    color: t.textSecondary,
                    fontSize: 13.5,
                    height: 1.45,
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: _actionStyle(t, filled: true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Yes/no confirmation. Returns true only on explicit confirm.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool danger = false,
  }) async {
    final t = context.tokens;
    final ok = await popup<bool>(
      context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: SenseiTokens.gapLg,
          vertical: SenseiTokens.gapXl,
        ),
        clipBehavior: Clip.antiAlias,
        icon: _ModalGlyph(
          icon: danger ? Icons.warning_amber_rounded : Icons.help_outline_rounded,
          danger: danger,
        ),
        title: Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: t.text,
            fontSize: 18,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.2,
          ),
        ),
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: t.textSecondary, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: _actionStyle(t),
            child: Text(
              cancelLabel,
              style: TextStyle(color: t.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: _actionStyle(t, filled: !danger, danger: danger),
            child: Text(
              confirmLabel,
              style: TextStyle(color: danger ? t.alert : t.onAccent),
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// Single or multi field edit dialog. Returns the trimmed values in the same
  /// order as [fields], or null when cancelled.
  static Future<List<String>?> edit(
    BuildContext context, {
    required String title,
    String? description,
    required List<SenseiModalField> fields,
    String saveLabel = 'Save',
  }) {
    return popup<List<String>>(
      context,
      builder: (ctx) => _EditDialog(
        title: title,
        description: description,
        fields: fields,
        saveLabel: saveLabel,
      ),
    );
  }

  /// Bottom sheet with the standard drag handle, padding and keyboard inset.
  static Future<T?> sheet<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool scrollable = true,
    bool padded = true,
    bool dismissible = true,
    double? maxHeightFactor,
  }) {
    final t = context.tokens;
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: dismissible,
      barrierLabel: 'dismiss',
      barrierColor: _barrierColor(t),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, __, ___) {
        Widget body;
        if (padded) {
          final mq = MediaQuery.of(ctx);
          body = Material(
            color: t.surfaceFill,
            clipBehavior: Clip.antiAlias,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(SenseiTokens.radiusXl),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: SenseiTokens.gapSm),
                  child: Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: t.borderStrong,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Flexible(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: SenseiTokens.gapLg,
                      right: SenseiTokens.gapLg,
                      top: SenseiTokens.gapSm,
                      bottom: mq.viewInsets.bottom +
                          mq.padding.bottom +
                          SenseiTokens.gapLg,
                    ),
                    child: scrollable
                        ? SingleChildScrollView(child: builder(ctx))
                        : builder(ctx),
                  ),
                ),
              ],
            ),
          );
        } else {
          body = builder(ctx);
        }
        final constrainedBody = maxHeightFactor == null
            ? body
            : ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * maxHeightFactor,
                ),
                child: body,
              );
        return Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(width: double.infinity, child: constrainedBody),
        );
      },
      transitionBuilder: (ctx, anim, __, child) => AnimatedBuilder(
        animation: anim,
        builder: (_, c) {
          final v = Curves.easeOutCubic.transform(anim.value);
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                      sigmaX: _barrierBlur * v, sigmaY: _barrierBlur * v),
                  child: const SizedBox.shrink(),
                ),
              ),
              FractionalTranslation(
                translation: Offset(0, 1 - v),
                child: Opacity(opacity: v, child: c),
              ),
            ],
          );
        },
        child: child,
      ),
    );
  }

  /// Centered dialog with custom content and the standard chrome.
  static Future<T?> dialog<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool dismissible = true,
  }) {
    return popup<T>(
      context,
      dismissible: dismissible,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(SenseiTokens.gapLg),
        child: Padding(
          padding: const EdgeInsets.all(SenseiTokens.gapLg),
          child: builder(ctx),
        ),
      ),
    );
  }
}

/// Field spec for [SenseiModal.edit].
///
/// [isBool] fields render as a label + Switch row instead of a text input
/// (users must never have to TYPE true/false), and are returned in the list
/// as the strings 'true' / 'false' so the existing order-based API is
/// unchanged.
class SenseiModalField {
  final String label;
  final String? hint;
  final String initialValue;
  final bool number;

  /// Render as a toggle instead of a text field.
  final bool isBool;

  /// Starting value of an [isBool] field.
  final bool initialBool;

  const SenseiModalField({
    required this.label,
    this.hint,
    this.initialValue = '',
    this.number = false,
    this.isBool = false,
    this.initialBool = false,
  });
}

/// Body of [SenseiModal.edit]. Owns the TextEditingControllers so they are
/// disposed in [State.dispose] — i.e. after the dialog's exit animation has
/// fully unmounted the tree. Disposing them the moment the route popped left
/// the still-animating TextField reading a dead controller ("used after being
/// disposed"), which then tore down the tree with the framework's
/// "_dependents.isEmpty is not true" assertion — the ping-target modal's
/// cancel/apply-with-empty-field crash.
class _EditDialog extends StatefulWidget {
  final String title;
  final String? description;
  final List<SenseiModalField> fields;
  final String saveLabel;

  const _EditDialog({
    required this.title,
    required this.description,
    required this.fields,
    required this.saveLabel,
  });

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final List<TextEditingController> _controllers = [
    for (final f in widget.fields)
      if (!f.isBool) TextEditingController(text: f.initialValue),
  ];

  late final List<bool> _bools = [
    for (final f in widget.fields) if (f.isBool) f.initialBool,
  ];

  /// Index of field [i] inside [_bools] (== number of bool fields before it).
  int _boolIndex(int i) {
    var n = 0;
    for (var k = 0; k < i; k++) {
      if (widget.fields[k].isBool) n++;
    }
    return n;
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: SenseiTokens.gapLg,
        vertical: SenseiTokens.gapXl,
      ),
      clipBehavior: Clip.antiAlias,
      icon: const _ModalGlyph(icon: Icons.edit_note_rounded),
      title: Text(
        widget.title,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: t.text,
          fontSize: 18,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.2,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.description != null)
              Padding(
                padding: const EdgeInsets.only(bottom: SenseiTokens.gapMd),
                child: Text(
                  widget.description!,
                  style: TextStyle(
                    color: t.textMuted,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ),
            for (var i = 0; i < widget.fields.length; i++) ...[
              if (widget.fields[i].isBool)
                _BoolField(
                  label: widget.fields[i].label,
                  value: _bools[_boolIndex(i)],
                  onChanged: (v) => setState(() => _bools[_boolIndex(i)] = v),
                )
              else
                SenseiField(
                  label: widget.fields[i].label,
                  controller: _controllers[i - _boolIndex(i)],
                  hint: widget.fields[i].hint,
                  number: widget.fields[i].number,
                  // No autofocus: an autofocused TextField inside a popped
                  // dialog trips the framework's InheritedElement teardown
                  // ("_dependents.isEmpty") when the dialog closes without
                  // any input — the ping target modal's on-device red screen.
                  // The user taps the field instead.
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: _actionStyle(t),
          child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
        ),
        TextButton(
          onPressed: () {
            final text = _controllers.map((c) => c.text.trim()).iterator;
            final bools = _bools.iterator;
            final out = <String>[];
            for (final f in widget.fields) {
              if (f.isBool) {
                bools.moveNext();
                out.add(bools.current ? 'true' : 'false');
              } else {
                text.moveNext();
                out.add(text.current);
              }
            }
            Navigator.pop(context, out);
          },
          style: _actionStyle(t, filled: true),
          child: Text(widget.saveLabel),
        ),
      ],
    );
  }
}

ButtonStyle _actionStyle(
  SenseiTokens t, {
  bool filled = false,
  bool danger = false,
}) {
  final fg = danger ? t.alert : (filled ? t.onAccent : t.accent);
  final bg = filled && !danger ? t.accent : Colors.transparent;
  return TextButton.styleFrom(
    foregroundColor: fg,
    backgroundColor: bg,
    minimumSize: const Size(86, 42),
    padding: const EdgeInsets.symmetric(horizontal: SenseiTokens.gapLg),
    shape: RoundedRectangleBorder(borderRadius: SenseiTokens.brMd),
    textStyle: const TextStyle(fontWeight: FontWeight.w800),
  );
}

class _ModalGlyph extends StatelessWidget {
  final IconData icon;
  final bool danger;

  const _ModalGlyph({required this.icon, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = danger ? t.alert : t.accent;
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.28),
            t.lime.withValues(alpha: danger ? 0.08 : 0.18),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.18),
            blurRadius: 24,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Icon(icon, color: color, size: 26),
    );
  }
}

/// Label + switch row used for [SenseiModalField.isBool] fields. The whole
/// row toggles — no typing "true"/"false" into a text field.
class _BoolField extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _BoolField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: SenseiTokens.gapMd + 2),
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: SenseiTokens.brSm,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SenseiTokens.gapSm,
            vertical: SenseiTokens.gapXs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}
