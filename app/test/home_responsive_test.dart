import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snapdark_tunnel/models/vpn_state.dart';
import 'package:snapdark_tunnel/screens/main_shell.dart';
import 'package:snapdark_tunnel/services/config_service.dart';
import 'package:snapdark_tunnel/services/location_service.dart';
import 'package:snapdark_tunnel/services/log_service.dart';
import 'package:snapdark_tunnel/services/settings_provider.dart';
import 'package:snapdark_tunnel/theme/snapdark_theme.dart';

/// Whole-app high-DPI regression suite.
///
/// "Crashes badly after update" reports came from old phones whose Display
/// size is set to 260/320/400 dpi — the logical viewport collapses to
/// 240–300dp wide / 400–640dp tall. Every layout exception (RenderFlex
/// overflow, unbounded box, NaN constraint) throws in a widget test exactly
/// where it white-screens the UI on the device, so the full shell — home
/// dashboard, configs, logs, settings AND the error state — is pumped at the
/// real device classes below with the app's own max text scaling.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
    // verifyIntegrity -> false makes ConfigService.loadServers bail before
    // any storage or network access; every other channel call answers with a
    // harmless default instead of MissingPluginException.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.snapdark.tunnel/vpn'),
      (call) async {
        switch (call.method) {
          case 'sessionInfo':
            return {'running': false, 'isConnected': false, 'mode': ''};
          case 'isVpnRunning':
            return false;
          default:
            return null;
        }
      },
    );
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    required Size size,
    double textScale = 1.0,
    void Function(VpnState vpn)? setup,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final vpn = VpnState();
    setup?.call(vpn);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider.value(value: vpn),
          ChangeNotifierProvider(create: (_) => ConfigService()),
          ChangeNotifierProvider(create: (_) => LogService()),
          ChangeNotifierProvider(create: (_) => LocationService()),
        ],
        child: MaterialApp(
          theme: SnapDarkTheme.dark,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: const MainShell(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1600));
  }

  // The pill nav only renders the LABEL of the active tab — inactive tabs are
  // icon-only, so switching must tap the icons, not the labels.
  Future<void> switchTab(WidgetTester tester, IconData icon) async {
    await tester.tap(find.byIcon(icon));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  // Old phones with Display size 260/320/400 dpi land in this band:
  // 720x1600 @400dpi → 288x640 dp, 480x800 @260dpi → 295x525 dp, and the
  // Android-Go 480p class bottoms out around 240dp wide.
  const smallSizes = <Size>[
    Size(288, 640), // 400 dpi on a 720p phone
    Size(295, 492), // 260 dpi on a 480p phone
    Size(320, 568), // classic small phone
    Size(240, 400), // extreme: 400 dpi on a 480p panel
  ];

  for (final size in smallSizes) {
    for (final scale in const [1.0, 1.25]) {
      testWidgets(
        'home tab lays out clean at ${size.width.toInt()}x${size.height.toInt()} '
        'text ${scale * 100}%',
        (tester) async {
      await pumpShell(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(find.text('SNAPDARK'), findsOneWidget);
        });
    }
  }

  testWidgets('all four shell tabs lay out clean at 288x568 / text 125%',
      (tester) async {
    await pumpShell(tester, size: const Size(288, 568), textScale: 1.25);
    // NOTE: no takeException() here — a layout exception must surface as the
    // framework's full console dump (it includes the creator chain).
    await switchTab(tester, Icons.dns_rounded);
    await switchTab(tester, Icons.terminal_rounded);
    await switchTab(tester, Icons.tune_rounded);
  });

  testWidgets('error state lays out clean at 240x400 with a long message',
      (tester) async {
    await pumpShell(
      tester,
      size: const Size(240, 400),
      textScale: 1.25,
      setup: (vpn) => vpn.setError(
        'Network error — the connection failed with a very long raw detail '
        'line that on a tiny screen must wrap instead of pushing the dial '
        'off the bottom of the column.',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('SNAPDARK'), findsOneWidget);
  });

  testWidgets('connected dashboard with ping history lays out clean',
      (tester) async {
    await pumpShell(
      tester,
      size: const Size(288, 568),
      textScale: 1.25,
      setup: (vpn) {
        vpn.setConnected();
        vpn.updateSpeed(1024 * 1024, 512 * 1024, 100 * 1024 * 1024,
            50 * 1024 * 1024);
      },
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
