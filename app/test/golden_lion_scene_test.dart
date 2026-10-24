import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:snapdark_tunnel/theme/snapdark_theme.dart';
import 'package:snapdark_tunnel/widgets/snapdark/connection_area.dart';

/// Connect-dial regression suite.
///
/// The dial face is deliberately STATIC (owner request): a plain power icon
/// on the glass / accent circle. The golden-lion animation was removed from
/// the button entirely — the lion lives only in the full-screen background
/// video, which starts on Connect.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: SnapDarkTheme.dark,
        home: Scaffold(
            body: Center(
                child: SizedBox(width: 244, height: 244, child: child))),
      );

  SnapDarkConnectionDial dial({required bool connected}) =>
      SnapDarkConnectionDial(
        isConnected: connected,
        isConnecting: false,
        durationText: connected ? '00:01:00' : '00:00:00',
        caption: 'server',
        onToggleConnect: () {},
      );

  testWidgets(
      'dial face is a static power icon at every state — no scene, no '
      'animation inside the button', (tester) async {
    for (final connected in const [false, true]) {
      await tester.pumpWidget(host(dial(connected: connected)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.power_settings_new_rounded), findsOneWidget);
      expect(find.text(connected ? 'CONNECTED' : 'TAP TO CONNECT'),
          findsOneWidget);
    }
  });

  testWidgets('the static dial is still a working button', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      SnapDarkConnectionDial(
        isConnected: false,
        isConnecting: false,
        durationText: '00:00:00',
        caption: 'server',
        onToggleConnect: () => taps++,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.power_settings_new_rounded));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
}
