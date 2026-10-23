import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapdark_tunnel/theme/snapdark_theme.dart';
import 'package:snapdark_tunnel/widgets/snapdark/golden_lion_background.dart';

/// The golden-lion backdrop must be bullet-proof in every environment: in
/// widget tests (and on any device that cannot play the bundled loop) the
/// video platform layer fails, and the widget has to fall back to its
/// painterly golden-jungle gradient — never a red screen, never a stuck
/// ticker after the test ends.
void main() {
  testWidgets(
      'background falls back to the painterly golden jungle when video is unavailable',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SnapDarkTheme.dark,
        home: const Scaffold(body: GoldenLionBackground()),
      ),
    );
    // Video init fails asynchronously (no platform player in tests); give
    // the catch path a couple of frames to settle into the fallback.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('goldenLionFallback')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'shockwave stays idle until the connect-success edge, then sweeps without throwing',
      (tester) async {
    const sceneKey = Key('shockwave-scene');

    Widget scene(bool connected) => MaterialApp(
          theme: SnapDarkTheme.dark,
          home: Scaffold(
            body: GoldenLionShockwaveOverlay(
              key: sceneKey,
              isConnected: connected,
            ),
          ),
        );

    // Disconnected: idle box, no animation running.
    await tester.pumpWidget(scene(false));
    expect(find.byType(GoldenLionShockwaveOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);

    // THE moment: the tunnel comes up → the boom fires and paints.
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    // Let the one-shot finish so no ticker outlives the test.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reconnecting fires a fresh shockwave each time', (tester) async {
    Widget scene(bool connected) => MaterialApp(
          theme: SnapDarkTheme.dark,
          home: Scaffold(
            body: GoldenLionShockwaveOverlay(isConnected: connected),
          ),
        );

    await tester.pumpWidget(scene(false));
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    // Drop the connection and connect again — second boom must not throw.
    await tester.pumpWidget(scene(false));
    await tester.pumpWidget(scene(true));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
