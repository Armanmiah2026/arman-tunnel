import 'package:flutter/material.dart';

import '../theme/sensei_tokens.dart';

class _HtmlStyle {
  const _HtmlStyle({
    this.color,
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });

  final Color? color;
  final bool bold;
  final bool italic;
  final bool underline;

  _HtmlStyle merge({Color? color, bool? bold, bool? italic, bool? underline}) {
    return _HtmlStyle(
      color: color ?? this.color,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
    );
  }
}

/// Hues the brand allows: violet (`#7C3AED`), lavender (`#C084FC`) and amber
/// (`#FBBF24`, warnings only).
const double _violetHue = 262;
const double _lavenderHue = 270;
const double _amberHue = 34;

/// Snap an arbitrary banner colour into the violet brand ramp.
///
/// Server MOTDs are attacker-controlled HTML and routinely ask for red, blue and
/// pink. Rather than dropping their intent, keep the saturation/lightness they
/// asked for and move the hue to the nearest allowed one — a "red warning" stays
/// visibly a warning (amber), everything else lands on violet or lavender. The
/// lightness window follows the active palette so banners stay readable on a
/// white background too.
Color _brandSafe(Color color, SenseiTokens t) {
  final hsl = HSLColor.fromColor(color);
  // Greys and near-whites carry no hue; leave them alone.
  if (hsl.saturation < 0.12) return color;

  final h = hsl.hue;
  // Reds/oranges/yellows (roughly 0–60° and 330–360°) read as "warning".
  final warmish = h < 60 || h >= 330;
  final target = warmish
      ? (h >= 45 && h < 60 ? _lavenderHue : _amberHue)
      : (h >= 60 && h < 105 ? _lavenderHue : _violetHue);

  return hsl
      .withHue(target)
      .withSaturation(hsl.saturation.clamp(0.35, 1.0))
      .withLightness(
        t.isDark
            ? hsl.lightness.clamp(0.35, 0.92)
            : hsl.lightness.clamp(0.18, 0.46),
      )
      .toColor();
}

Color? _parseColor(String value, SenseiTokens t) {
  final v = value.trim().toLowerCase().replaceAll(RegExp("[\"']"), '');
  // Named colours are mapped straight onto the brand ramp so the common cases
  // are exact rather than approximated.
  final named = <String, Color>{
    'black': t.isDark ? Colors.black : t.text,
    'white': t.isDark ? Colors.white : t.text,
    'red': t.alert, // rose — the palette's error colour
    'green': t.accent,
    'yellow': t.lime,
    'blue': t.accent,
    'cyan': t.accentBright,
    'aqua': t.accentBright,
    'pink': t.lime,
    'magenta': t.lime,
    'orange': t.warning,
    'gold': t.lime,
    'gray': t.textMuted,
    'grey': t.textMuted,
  };
  if (named.containsKey(v)) return named[v];

  final hex = v.startsWith('#') ? v.substring(1) : v;
  if (RegExp(r'^[0-9a-f]{6}$').hasMatch(hex)) {
    return _brandSafe(Color(int.parse('FF$hex', radix: 16)), t);
  }
  if (RegExp(r'^[0-9a-f]{3}$').hasMatch(hex)) {
    return _brandSafe(
      Color(int.parse(
        'FF${hex[0] * 2}${hex[1] * 2}${hex[2] * 2}',
        radix: 16,
      )),
      t,
    );
  }
  return null;
}

String _decodeEntities(String s) {
  var out = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  // Numeric entities (&#8226; and friends) show up in generated MOTDs.
  out = out.replaceAllMapped(RegExp(r'&#(\d{1,7});'), (m) {
    final code = int.tryParse(m.group(1)!);
    if (code == null || code < 9 || code > 0x10FFFF) return m.group(0)!;
    return String.fromCharCode(code);
  });
  return out;
}

String _clean(String s) {
  return _decodeEntities(s).replaceAll(
    RegExp(r'[\u2000-\u200F\u2028-\u202F\u2060-\u206F\uFEFF]'),
    '',
  );
}

Map<String, String> _attrs(String tag) {
  final out = <String, String>{};
  for (final m in RegExp("([a-zA-Z-]+)\\s*=\\s*([\"'])(.*?)\\2").allMatches(tag)) {
    out[m.group(1)!.toLowerCase()] = m.group(3)!;
  }
  for (final m in RegExp(r'([a-zA-Z-]+)\s*=\s*([^\s>]+)').allMatches(tag)) {
    out.putIfAbsent(m.group(1)!.toLowerCase(), () => m.group(2)!);
  }
  return out;
}

Color? _styleColor(String style, SenseiTokens t) {
  final m = RegExp(r'color\s*:\s*([^;]+)', caseSensitive: false).firstMatch(style);
  return m == null ? null : _parseColor(m.group(1)!, t);
}

TextSpan _span(String text, _HtmlStyle style, TextStyle base, SenseiTokens t) {
  return TextSpan(
    text: text,
    style: base.copyWith(
      color: style.color ?? base.color ?? t.text,
      fontWeight: style.bold ? FontWeight.w800 : base.fontWeight,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
      decoration:
          style.underline ? TextDecoration.underline : TextDecoration.none,
    ),
  );
}

/// Tags this renderer understands. Anything outside the list is not treated as
/// markup, so a log line that merely mentions `<something>` is left as text.
const _tagNames =
    r'br|font|span|b|strong|i|em|u|p|div|center|pre|small|big';

/// A tag must open with `<` or `</` immediately followed by the name, then
/// either `>` or whitespace plus attributes. Requiring that is what keeps
/// arithmetic in a log line (`a < b and c > d`) from being parsed as `<b>`.
final _htmlTagRe =
    RegExp('</?(?:$_tagNames)(?:\\s[^>]*)?/?>', caseSensitive: false);
final _entityRe = RegExp(r'&(?:nbsp|amp|lt|gt|quot|#\d+);', caseSensitive: false);

/// Whether [raw] carries markup worth rendering instead of printing verbatim.
///
/// Used by the log view so ANY line containing HTML gets formatted, not only
/// the ones recognised as an SSH MOTD banner. Servers and proxies emit coloured
/// HTML in ordinary replies too, and showing the raw tags there looked broken.
bool looksLikeHtml(String raw) =>
    _htmlTagRe.hasMatch(raw) || _entityRe.hasMatch(raw);

/// One parsed block: spans per visual line, plus each line's alignment.
class _Parsed {
  _Parsed(this.lines, this.aligns);
  final List<List<TextSpan>> lines;
  final List<TextAlign> aligns;
}

/// Shared HTML walker for both the banner card and inline log lines.
///
/// Supports nested `<font color>`, `<span style="color:">`, `<b>`, `<i>`,
/// `<u>`, `<p align>`, `<center>` and `<br>` without pulling in a WebView.
_Parsed _parse(
  String raw,
  SenseiTokens t,
  TextStyle base,
  TextAlign defaultAlign,
) {
  final html = _clean(raw);
  final lines = <List<TextSpan>>[<TextSpan>[]];
  final aligns = <TextAlign>[defaultAlign];
  final stack = <_HtmlStyle>[const _HtmlStyle()];
  var currentAlign = defaultAlign;

  void newLine() {
    lines.add(<TextSpan>[]);
    aligns.add(currentAlign);
  }

  void addText(String text) {
    if (text.isEmpty) return;
    lines.last.add(_span(text, stack.last, base, t));
  }

  for (final token in RegExp(r'<[^>]*>|[^<]+').allMatches(html)) {
    final part = token.group(0)!;
    if (!part.startsWith('<')) {
      // Real newlines in the source are line breaks; other runs of whitespace
      // collapse the way HTML does.
      final segments = part.split('\n');
      for (var i = 0; i < segments.length; i++) {
        if (i > 0) newLine();
        addText(segments[i].replaceAll(RegExp(r'[ \t\r]+'), ' '));
      }
      continue;
    }

    // An unknown tag is not markup — emit it as literal text so nothing
    // silently disappears from a log line.
    if (!_htmlTagRe.hasMatch(part)) {
      addText(part);
      continue;
    }

    final rawTag = part.substring(1, part.length - 1).trim();
    final lower = rawTag.toLowerCase();
    if (lower.startsWith('br')) {
      newLine();
      continue;
    }
    if (lower.startsWith('/p') || lower.startsWith('/div')) {
      newLine();
      currentAlign = defaultAlign;
      continue;
    }
    if (lower.startsWith('/')) {
      if (stack.length > 1) stack.removeLast();
      if (lower.startsWith('/center')) currentAlign = defaultAlign;
      continue;
    }

    final attrs = _attrs(rawTag);
    if (lower.startsWith('p') || lower.startsWith('div')) {
      final align = attrs['align']?.toLowerCase();
      currentAlign = align == 'left'
          ? TextAlign.left
          : align == 'right'
              ? TextAlign.right
              : align == 'center'
                  ? TextAlign.center
                  : defaultAlign;
      aligns[aligns.length - 1] = currentAlign;
      continue;
    }

    var style = stack.last;
    if (lower.startsWith('center')) {
      currentAlign = TextAlign.center;
      style = style.merge();
    } else if (lower.startsWith('font')) {
      style = style.merge(
          color: attrs['color'] == null ? null : _parseColor(attrs['color']!, t));
    } else if (lower.startsWith('span')) {
      style = style.merge(
          color: attrs['style'] == null ? null : _styleColor(attrs['style']!, t));
    } else if (lower.startsWith('b') || lower.startsWith('strong')) {
      style = style.merge(bold: true);
    } else if (lower.startsWith('i') || lower.startsWith('em')) {
      style = style.merge(italic: true);
    } else if (lower.startsWith('u')) {
      style = style.merge(underline: true);
    } else {
      // pre/small/big: no styling of their own, but they still nest.
      style = style.merge();
    }
    stack.add(style);
  }

  return _Parsed(lines, aligns);
}

/// Renders SSH MOTD/banner HTML from common server scripts, centred in a block.
///
/// Colours are resolved against [context]'s palette, so a banner is readable in
/// both themes and can never introduce a non-brand hue.
Widget buildBannerWidget(BuildContext context, String raw) {
  final t = context.tokens;
  final parsed = _parse(
    raw,
    t,
    const TextStyle(
      fontSize: 12,
      fontFamily: 'monospace',
      fontWeight: FontWeight.w500,
      height: 1.4,
    ).copyWith(color: t.text),
    TextAlign.center,
  );

  final children = <Widget>[];
  for (var i = 0; i < parsed.lines.length; i++) {
    final spans = parsed.lines[i];
    final empty = spans.every((s) => (s.text ?? '').trim().isEmpty);
    if (empty) {
      children.add(const SizedBox(height: 4));
      continue;
    }
    children.add(RichText(
      textAlign: parsed.aligns[i],
      text: TextSpan(children: spans),
    ));
  }
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
}

/// Inline variant for a single log line: keeps [base] (the log's own mono size
/// and severity colour) and only applies what the markup asks for on top.
///
/// Line breaks become real newlines inside one paragraph rather than separate
/// widgets, so the line still behaves like one entry in the list.
List<InlineSpan> buildHtmlSpans(
  BuildContext context,
  String raw,
  TextStyle base,
) {
  final parsed = _parse(raw, context.tokens, base, TextAlign.left);
  final out = <InlineSpan>[];
  for (var i = 0; i < parsed.lines.length; i++) {
    if (i > 0) out.add(TextSpan(text: '\n', style: base));
    out.addAll(parsed.lines[i]);
  }
  return out;
}
