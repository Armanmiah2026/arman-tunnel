import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snapdark_tunnel/services/settings_provider.dart';
import 'package:snapdark_tunnel/theme/snapdark_theme.dart';
import 'package:snapdark_tunnel/widgets/snapdark/theme_toggle.dart';
import 'package:snapdark_tunnel/widgets/ui/snapdark_modal.dart';
import 'package:snapdark_tunnel/widgets/ui/snapdark_wallpaper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  final glass = SnapDarkTokens.dark.copyWith(
    wallpaperPath: '/data/nope/snapdark_wallpaper.png',
    wallpaperDim: 0.4,
    wallpaperBlur: 6,
    wallpaperCardOpacity: 0.5,
  );

  test('glass tokens: pages and scaffolds go fully transparent', () {
    expect(glass.glass, isTrue);
    expect(glass.pageGradient, everyElement(Colors.transparent));
    expect(glass.scaffoldBg, Colors.transparent);
    // Card fill follows the user's card-opacity knob, not the raw surface
    // (withOpacity quantizes alpha to 8 bits, so allow rounding slack).
    expect(glass.surfaceFill.a, closeTo(0.5, 0.005));
  });

  test('glass tokens: LIGHT palette gets a card-opacity floor', () {
    // Light glass keeps a readability floor, but it must still remain visibly
    // translucent so the card-opacity slider actually changes the result.
    final lightGlass = SnapDarkTokens.light.copyWith(
      wallpaperPath: '/data/nope/wall.png',
      wallpaperCardOpacity: 0.55,
    );
    expect(lightGlass.glass, isTrue);
    expect(lightGlass.surfaceFill.a,
        greaterThanOrEqualTo(0.59), reason: 'light cards need the floor');
    expect(lightGlass.surfaceFill.a,
        lessThan(0.80), reason: 'light cards must not look solid white');
    expect(lightGlass.surfaceAltFill.a,
        greaterThanOrEqualTo(0.65), reason: 'nested rows need the floor');
    // Dark keeps the raw knob (its near-black fill reads fine at 55%).
    expect(glass.surfaceFill.a, closeTo(0.5, 0.005));
    // Hero surfaces (idle dial etc.) use the translucent fills in glass
    // mode — no opaque slab over the wallpaper, in EITHER theme.
    expect(lightGlass.heroGradient, everyElement(isNot(equals(lightGlass.surface))));
    expect(glass.heroGradient, everyElement(isNot(equals(glass.surfaceAlt))));
  });

  test('glass tokens: active card fill composites the wash on the surface', () {
    // SnapDarkCard's active fill = accentWash blended ON surfaceFill. On the
    // LIGHT palette the floor must survive the tint without turning solid
    // white; dark intentionally keeps the raw knob, where
    // alphaBlend only softens it slightly.
    final lightGlass = SnapDarkTokens.light.copyWith(
      wallpaperPath: '/data/nope/wall.png',
      wallpaperCardOpacity: 0.55,
    );
    final active = Color.alphaBlend(lightGlass.accentWash, lightGlass.surfaceFill);
    expect(active.a, greaterThanOrEqualTo(0.62),
        reason: 'active light glass card must keep the surface floor');
    expect(active.a, lessThan(0.90),
        reason: 'active light glass card must stay translucent');

    final darkGlass = SnapDarkTokens.dark.copyWith(
      wallpaperPath: '/data/nope/wall.png',
      wallpaperCardOpacity: 0.55,
    );
    final activeDark =
        Color.alphaBlend(darkGlass.accentWash, darkGlass.surfaceFill);
    // Dark has no floor — the blend lands between the raw knob and opaque.
    expect(activeDark.a, greaterThanOrEqualTo(0.55));
    expect(activeDark.a, lessThanOrEqualTo(1.0));
  });

  test('glass tokens off: everything stays opaque and unchanged', () {
    const t = SnapDarkTokens.dark;
    expect(t.glass, isFalse);
    expect(t.scaffoldBg, t.bg);
    expect(t.pageGradient, [t.bgAlt, t.bg]);
    expect(t.surfaceFill, t.surface);
  });

  testWidgets('SnapDarkTheme.buildFor: glass theme keeps every surface '
      'translucent', (tester) async {
    final theme = SnapDarkTheme.buildFor(glass);
    expect(theme.scaffoldBackgroundColor, Colors.transparent);
    expect(theme.dialogTheme.backgroundColor, glass.surfaceFill);
    expect(theme.bottomSheetTheme.backgroundColor, glass.surfaceFill);
    expect(theme.popupMenuTheme.color, glass.surfaceFill);
    // The tokens ride along as the extension so widgets can read them.
    expect(theme.extension<SnapDarkTokens>(), glass);
  });

  testWidgets('SnapDarkWallpaperLayer: nothing without a wallpaper', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SnapDarkTheme.buildFor(SnapDarkTokens.dark),
        home: const Scaffold(body: SnapDarkWallpaperLayer()),
      ),
    );
    // Off mode must not reserve any space or paint anything.
    expect(find.byType(SnapDarkWallpaperLayer), findsOneWidget);
    expect(
      tester.getSize(find.byType(SnapDarkWallpaperLayer)),
      Size.zero,
      reason: 'off-mode layer should be a shrink widget',
    );
  });

  testWidgets('SnapDarkWallpaperLayer: paints scrim + missing-file fallback',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SnapDarkTheme.buildFor(glass),
        home: const Scaffold(body: SnapDarkWallpaperLayer()),
      ),
    );
    // testWidgets runs in a FakeAsync zone where real file IO never
    // completes — runAsync lets the (failing) read finish so the
    // errorBuilder fallback actually builds.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    // The wallpaper file does not exist, so the image falls back to a solid
    // bg fill — and the dim scrim (black in BOTH themes: Dim = darkness)
    // still paints on top of it at the user's dim value. A missing
    // wallpaper must degrade, never crash.
    final boxes = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .map((b) => b.color)
        .toList();
    expect(
      boxes,
      containsAll(<Color>[
        glass.bg, // missing-file fallback
        Colors.black.withValues(alpha: glass.wallpaperDim), // dim scrim
      ]),
      reason: 'layer = image (fallback) + black dim scrim',
    );
  });

  testWidgets('SnapDarkModal bool field: renders a switch and returns '
      'true/false strings', (tester) async {
    List<String>? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: SnapDarkTheme.buildFor(SnapDarkTokens.dark),
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                saved = await SnapDarkModal.edit(
                  context,
                  title: 'Engine',
                  fields: const [
                    SnapDarkModalField(label: 'MTU', initialValue: '1500',
                        number: true),
                    SnapDarkModalField(
                        label: 'TLS Fragmentation', isBool: true,
                        initialBool: true),
                    SnapDarkModalField(
                        label: 'Connection Mux', isBool: true,
                        initialBool: false),
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Boolean fields are switches, not "true/false" text inputs.
    final switches = tester.widgetList<Switch>(find.byType(Switch));
    expect(switches, hasLength(2));
    expect(switches.first.value, isTrue);
    expect(switches.last.value, isFalse);
    expect(find.textContaining('true/false'), findsNothing);

    // Toggle mux on, keep MTU, save — values come back in field order.
    await tester.tap(find.text('Connection Mux'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1400');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved, ['1400', 'true', 'true']);
  });
  testWidgets('SnapDarkThemeToggle: tap flips the persisted theme with the '
      'sun/moon animation', (tester) async {
    // Store 'dark' so the provider's async first-launch detection (which
    // follows the TEST env's light platform brightness) cannot flip it.
    SharedPreferences.setMockInitialValues({'snapdark_theme_mode': 'dark'});
    final settings = SettingsProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: settings)],
        child: MaterialApp(
          theme: SnapDarkTheme.buildFor(SnapDarkTokens.light),
          darkTheme: SnapDarkTheme.buildFor(SnapDarkTokens.dark),
          themeMode: settings.themeMode,
          home: const Scaffold(
            body: Center(child: _ToggleHost()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);

    // Dark shows the sun (the destination); tapping flips to light + moon.
    expect(find.byIcon(Icons.light_mode_rounded), findsOneWidget);
    await tester.tap(find.byType(SnapDarkThemeToggle));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.light);
    expect(find.byIcon(Icons.dark_mode_rounded), findsOneWidget);

    // And back.
    await tester.tap(find.byType(SnapDarkThemeToggle));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
  });
}

/// Host that feeds the watched provider into the toggle (const-friendly).
class _ToggleHost extends StatelessWidget {
  const _ToggleHost();

  @override
  Widget build(BuildContext context) {
    return SnapDarkThemeToggle(
      settings: context.watch<SettingsProvider>(),
    );
  }
}
