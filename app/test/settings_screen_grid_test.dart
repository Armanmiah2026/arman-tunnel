import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snapdark_tunnel/screens/settings_screen.dart';
import 'package:snapdark_tunnel/services/config_service.dart';
import 'package:snapdark_tunnel/services/log_service.dart';
import 'package:snapdark_tunnel/services/settings_provider.dart';
import 'package:snapdark_tunnel/theme/snapdark_theme.dart';
import 'package:snapdark_tunnel/widgets/ui/snapdark_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
    // verifyIntegrity -> false makes ConfigService.loadServers bail before
    // any storage or network access.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.snapdark.tunnel/vpn'),
      (call) async => false,
    );
  });

  Future<SettingsProvider> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(420, 3400),
    double textScale = 1.0,
  }) async {
    // Roomy surface by default so every section is built and visible; the
    // overflow regression test passes a small screen + large font instead.
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = SettingsProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider(create: (_) => ConfigService()),
          ChangeNotifierProvider(create: (_) => LogService()),
        ],
        child: MaterialApp(
          theme: SnapDarkTheme.dark,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: const SettingsScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  testWidgets('renders every section header and card', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Settings'), findsOneWidget);

    // Section headers.
    for (final header in ['CONNECTION', 'APPEARANCE', 'ENGINE']) {
      expect(find.text(header), findsOneWidget, reason: 'missing $header');
    }

    // Every tile renders in one scrollable column.
    for (final tile in [
      'Wake Lock', 'Auto Reconnect', 'Kill Switch', 'Bypass LAN',
      'Theme', 'Wallpaper Mode', 'MTU', 'DNS Servers',
      'Ping Target', 'Keepalive', 'Split Tunnel', 'Direct / Block', 'TLS & Mux',
    ]) {
      expect(find.text(tile), findsOneWidget, reason: 'missing $tile');
    }

    // Removed options stay removed.
    expect(find.text('System'), findsNothing);
    expect(find.text('Custom SNI'), findsNothing);
    expect(find.text('Native Cores'), findsNothing);
  });

  testWidgets('cards are laid out in a 2-column grid', (tester) async {
    await pumpScreen(tester);

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    double left(String text) => tester.getTopLeft(find.text(text)).dx;

    // Connection: Wake Lock | Auto Reconnect on one row.
    expect(top('Wake Lock'), closeTo(top('Auto Reconnect'), 1));
    expect(left('Wake Lock'), lessThan(left('Auto Reconnect')));

    // Second row starts below and pairs up too.
    expect(top('Kill Switch'), greaterThan(top('Wake Lock')));
    expect(top('Kill Switch'), closeTo(top('Bypass LAN'), 12));

    // The right-hand card starts past the middle of the 420px surface.
    expect(left('Auto Reconnect'), greaterThan(420 / 2 - 1));

    // Every section pairs its columns the same way (MTU | DNS Servers).
    expect(top('MTU'), closeTo(top('DNS Servers'), 12));
    expect(top('Ping Target'), closeTo(top('Keepalive'), 12));
    expect(top('Split Tunnel'), closeTo(top('Direct / Block'), 12));
    expect(top('TLS & Mux'), greaterThan(top('Direct / Block')));

    // Cards in a row share the SAME height (IntrinsicHeight row). Measured
    // on the SnapDarkCard containers, not the texts — a 2-line title centres
    // differently inside its row than a 1-line one.
    double cardBottom(String text) => tester.getBottomLeft(
          find.ancestor(
            of: find.text(text),
            matching: find.byType(SnapDarkCard),
          ),
        ).dy;
    expect(cardBottom('MTU'), closeTo(cardBottom('DNS Servers'), 1));
    expect(cardBottom('Wake Lock'), closeTo(cardBottom('Auto Reconnect'), 1));
    expect(cardBottom('Ping Target'), closeTo(cardBottom('Keepalive'), 1));
    expect(
        cardBottom('Split Tunnel'), closeTo(cardBottom('Direct / Block'), 1));
  });

  testWidgets('small screens + large fonts: no overflow anywhere',
      (tester) async {
    // The old paged Expanded layout threw "BOTTOM OVERFLOWED BY n pixels"
    // on short screens with big system fonts. The scrollable content-sized
    // layout must survive both — any RenderFlex overflow throws during
    // layout and fails this test.
    await pumpScreen(tester, size: const Size(360, 640), textScale: 1.25);

    expect(tester.takeException(), isNull);
    expect(find.text('Wake Lock'), findsOneWidget);

    // Scroll through the FULL page — the bottom rows must lay out cleanly
    // too, and the last row must clear the bottom of the viewport.
    for (var i = 0; i < 3; i++) {
      await tester.dragFrom(const Offset(180, 320), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('theme card: compact segmented selector switches the palette',
      (tester) async {
    // Seed dark so the provider's first-launch detection (which follows the
    // TEST env's light platform brightness) cannot race the expectation.
    SharedPreferences.setMockInitialValues({'snapdark_theme_mode': 'dark'});
    final settings = await pumpScreen(tester);

    // No chevron / value text anymore — the selector is the control.
    expect(find.text('Theme'), findsOneWidget);
    final themeCard = find.ancestor(
      of: find.text('Theme'),
      matching: find.byType(SnapDarkCard),
    );
    expect(
      find.descendant(of: themeCard, matching: find.byType(Switch)),
      findsNothing,
      reason: 'theme card must not use an ON/OFF switch',
    );

    // In dark mode the sun segment is the only sun on the screen (the
    // card's leading icon is the moon) — tap it to go light.
    await tester.tap(find.byIcon(Icons.light_mode_rounded));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.light);

    // In light mode the moon segment is the only moon — tap to go dark.
    await tester.tap(find.byIcon(Icons.dark_mode_rounded));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
  });

  testWidgets('tapping a card toggles the switch and provider', (tester) async {
    final settings = await pumpScreen(tester);

    final initial = settings.wakeLock;
    final cardFinder = find.ancestor(
      of: find.text('Wake Lock'),
      matching: find.byType(SnapDarkCard),
    );

    await tester.tap(find.text('Wake Lock'));
    await tester.pumpAndSettle();

    expect(settings.wakeLock, isNot(initial));
    final cardSwitch = tester.widget<Switch>(
      find.descendant(of: cardFinder, matching: find.byType(Switch)),
    );
    expect(cardSwitch.value, settings.wakeLock);
  });

  testWidgets('tapping a value card opens its edit modal', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('MTU'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Valid range 576–1500'), findsOneWidget);
    expect(find.text('Bytes'), findsOneWidget);
  });

  testWidgets('ping target modal: cancel with empty field does not throw',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Ping Target'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Ping Target'), findsOneWidget);
  });

  testWidgets('ping target modal: apply with empty field falls back to the default',
      (tester) async {
    final settings = await pumpScreen(tester);

    await tester.tap(find.text('Ping Target'));
    await tester.pumpAndSettle();
    // Field starts with the current value (empty on a fresh install) — make
    // sure it is really empty, then apply.
    expect(find.text('Host or URL'), findsOneWidget);
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField.first, '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(settings.pingHost, isEmpty);
  });
}
