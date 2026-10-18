import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sensei_tunnel/theme/sensei_theme.dart';
import 'package:sensei_tunnel/utils/banner_renderer.dart';

/// Collect the rendered text of every span, so we can assert what the user sees.
String _plain(List<InlineSpan> spans) {
  final sb = StringBuffer();
  for (final s in spans) {
    s.visitChildren((span) {
      if (span is TextSpan && span.text != null) sb.write(span.text);
      return true;
    });
  }
  return sb.toString();
}

List<TextSpan> _styled(List<InlineSpan> spans) {
  final out = <TextSpan>[];
  for (final s in spans) {
    s.visitChildren((span) {
      if (span is TextSpan && span.text != null) out.add(span);
      return true;
    });
  }
  return out;
}

void main() {
  group('looksLikeHtml', () {
    test('detects the tags the renderer supports', () {
      expect(looksLikeHtml('<font color="red">hi</font>'), isTrue);
      expect(looksLikeHtml('line<br>break'), isTrue);
      expect(looksLikeHtml('<b>bold</b>'), isTrue);
      expect(looksLikeHtml('<span style="color:#00ff00">x</span>'), isTrue);
      expect(looksLikeHtml('a &amp; b'), isTrue);
    });

    test('leaves ordinary log lines alone', () {
      // These must NOT be treated as markup, or the log would mangle them.
      expect(looksLikeHtml('Injector[1]: upstream TCP connected'), isFalse);
      expect(looksLikeHtml('client->upstream first 29B'), isFalse);
      expect(looksLikeHtml('SSH-2.0-dropbear_2019.78'), isFalse);
      expect(looksLikeHtml('a < b and c > d'), isFalse);
      expect(looksLikeHtml('VPN state: error:<unknown>'), isFalse);
    });
  });

  group('buildHtmlSpans', () {
    late BuildContext ctx;

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SenseiTheme.dark,
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
    }

    testWidgets('strips tags and keeps the text', (tester) async {
      await pump(tester);
      final spans = buildHtmlSpans(
        ctx,
        '<font color="lime">Welcome</font> to <b>Sensei</b>',
        const TextStyle(),
      );
      expect(_plain(spans), 'Welcome to Sensei');
    });

    testWidgets('applies bold from markup', (tester) async {
      await pump(tester);
      final spans =
          buildHtmlSpans(ctx, 'plain <b>strong</b>', const TextStyle());
      final strong = _styled(spans).firstWhere((s) => s.text == 'strong');
      expect(strong.style!.fontWeight, FontWeight.w800);
    });

    testWidgets('<br> becomes a newline in one span list', (tester) async {
      await pump(tester);
      final spans = buildHtmlSpans(ctx, 'one<br>two', const TextStyle());
      expect(_plain(spans), 'one\ntwo');
    });

    testWidgets('inherits the base style it is given', (tester) async {
      await pump(tester);
      const base = TextStyle(fontSize: 11.5, fontFamily: 'monospace');
      final spans = buildHtmlSpans(ctx, '<b>x</b>', base);
      final span = _styled(spans).first;
      expect(span.style!.fontSize, 11.5);
      expect(span.style!.fontFamily, 'monospace');
    });

    testWidgets('unknown tags survive as literal text', (tester) async {
      await pump(tester);
      // <secret> is not markup we know; dropping it would hide log content.
      final spans =
          buildHtmlSpans(ctx, 'keep <secret> and <b>bold</b>', const TextStyle());
      expect(_plain(spans), contains('<secret>'));
      expect(_plain(spans), contains('bold'));
    });

    testWidgets('decodes named and numeric entities', (tester) async {
      await pump(tester);
      final spans =
          buildHtmlSpans(ctx, 'a &amp; b &#8226; c', const TextStyle());
      expect(_plain(spans), 'a & b • c');
    });

    testWidgets('never emits a non-brand hue', (tester) async {
      await pump(tester);
      // A banner asking for pure blue must land on the violet/lavender/amber ramp.
      final spans =
          buildHtmlSpans(ctx, '<font color="#0000ff">x</font>', const TextStyle());
      final color = _styled(spans).first.style!.color!;
      final hue = HSLColor.fromColor(color).hue;
      final onRamp = (hue - 262).abs() < 25 ||
          (hue - 270).abs() < 25 ||
          (hue - 34).abs() < 25;
      expect(onRamp, isTrue, reason: 'hue $hue is outside the brand ramp');
    });
  });

  group('buildBannerWidget', () {
    testWidgets('renders MOTD markup without showing tags', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SenseiTheme.dark,
          home: Builder(
            builder: (c) => Scaffold(
              body: buildBannerWidget(
                c,
                '<center><font color="#00ff00">ARMAN VPN</font><br>'
                    '<b>No DDOS</b></center>',
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('<font'), findsNothing);
      expect(find.byType(RichText), findsWidgets);
    });
  });
}
