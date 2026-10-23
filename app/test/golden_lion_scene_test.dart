import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:snapdark_tunnel/theme/snapdark_theme.dart';
import 'package:snapdark_tunnel/widgets/snapdark/connection_area.dart';
import 'package:snapdark_tunnel/widgets/snapdark/golden_lion_dial.dart';

/// Golden-lion connect animation regression suite.
///
/// Locks the three-phase story of the dial's inner scene:
///   connecting → lion runs through the golden jungle
///   success    → one-shot roar burst (aura wave), then…
///   connected  → lion runs on with the pride (companions fade in)
///
/// NOTE: the scene intentionally runs an infinite ticker while busy/connected,
/// so these tests pump fixed durations — never pumpAndSettle.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: SnapDarkTheme.dark,
        home: Scaffold(body: Center(child: SizedBox(width: 244, height: 244, child: child))),
      );

  GoldenLionSceneState sceneOf(WidgetTester tester) =>
      tester.state<GoldenLionSceneState>(find.byType(GoldenLionScene));

  testWidgets('scene stays idle (no ticker) while disconnected',
      (tester) async {
    await tester.pumpWidget(
      host(const GoldenLionScene(isConnected: false, isConnecting: false)),
    );
    await tester.pump();
    expect(sceneOf(tester).phase, LionScenePhase.idle);
    // Idle must not burn battery: no frame scheduled by the scene.
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('connecting runs the lion; success roars then joins the pride',
      (tester) async {
    await tester.pumpWidget(
      host(const GoldenLionScene(isConnected: false, isConnecting: true)),
    );
    await tester.pump();
    expect(sceneOf(tester).phase, LionScenePhase.connecting);

    // Tunnel comes up → the one-shot roar fires exactly once.
    await tester.pumpWidget(
      host(const GoldenLionScene(isConnected: true, isConnecting: false)),
    );
    await tester.pump();
    expect(sceneOf(tester).phase, LionScenePhase.roar);

    // Roar is a 1.5s burst; after it the scene settles into connected.
    await tester.pump(const Duration(milliseconds: 1600));
    expect(sceneOf(tester).phase, LionScenePhase.connected);

    // Disconnect → back to idle.
    await tester.pumpWidget(
      host(const GoldenLionScene(isConnected: false, isConnecting: false)),
    );
    await tester.pump();
    expect(sceneOf(tester).phase, LionScenePhase.idle);
  });

  testWidgets('restored session skips the roar and shows the pride',
      (tester) async {
    // App reopened while already connected: no fresh-connect burst.
    await tester.pumpWidget(
      host(const GoldenLionScene(isConnected: true, isConnecting: false)),
    );
    await tester.pump();
    expect(sceneOf(tester).phase, LionScenePhase.connected);
    await tester.pump(const Duration(milliseconds: 100));
    // Still connected — the roar never fired.
    expect(sceneOf(tester).phase, LionScenePhase.connected);
  });

  testWidgets('dial crossfades the scene in while busy and paints at every '
      'state without exceptions', (tester) async {
    for (final state in const [false, true]) {
      await tester.pumpWidget(
        host(
          SnapDarkConnectionDial(
            isConnected: state,
            isConnecting: !state,
            durationText: state ? '00:01:00' : '00:00:00',
            caption: 'server',
            onToggleConnect: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byType(GoldenLionScene), findsOneWidget);
      expect(find.byIcon(Icons.power_settings_new_rounded), findsOneWidget);
    }
  });
}
