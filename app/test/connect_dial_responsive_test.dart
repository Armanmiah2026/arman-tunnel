import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sensei_tunnel/theme/sensei_theme.dart';
import 'package:sensei_tunnel/widgets/sensei/connection_area.dart';

Widget _host(Size screen, Widget child) {
  return MediaQuery(
    data: MediaQueryData(size: screen),
    child: MaterialApp(
      theme: SenseiTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

/// The FittedBox the dial builds is the art's real rendered box.
Finder _dialArt() => find.descendant(
      of: find.byType(SenseiConnectionDial),
      matching: find.byType(FittedBox),
      matchRoot: true,
    );

void main() {
  testWidgets('dial keeps a usable size on a 320-wide low-DPI phone',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        const Size(320, 568),
        SenseiConnectionDial(
          isConnected: false,
          isConnecting: false,
          durationText: '00:00:00',
          caption: 'No tunnel selected',
          onToggleConnect: () {},
        ),
      ),
    );
    await tester.pump();

    final size = tester.getSize(_dialArt().first);
    // Minimum usable connect button: never the old "abnormally small" result.
    expect(size.width, greaterThanOrEqualTo(150));
    expect(size.width, lessThanOrEqualTo(320));
    expect(size.width, size.height);
  });

  testWidgets('dial never balloons on a tablet', (tester) async {
    tester.view.physicalSize = const Size(900, 1280);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        const Size(900, 1280),
        SenseiConnectionDial(
          isConnected: true,
          isConnecting: false,
          durationText: '01:00:00',
          caption: 'server',
          onToggleConnect: () {},
        ),
      ),
    );
    await tester.pump();

    final size = tester.getSize(_dialArt().first);
    expect(size.width, lessThanOrEqualTo(320));
    // …but a big screen still gets a big (not tiny) dial.
    expect(size.width, greaterThanOrEqualTo(240));
  });

  testWidgets('dial scales proportionally on a standard phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        const Size(360, 760),
        SenseiConnectionDial(
          isConnected: false,
          isConnecting: true,
          durationText: '00:00:00',
          caption: 'server',
          onToggleConnect: () {},
        ),
      ),
    );
    await tester.pump();

    final size = tester.getSize(_dialArt().first);
    // ~33% of height on this aspect ratio, bounded by the band.
    expect(size.width, greaterThanOrEqualTo(170));
    expect(size.width, lessThanOrEqualTo(320));
  });
}
