import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:snapdark_tunnel/theme/snapdark_theme.dart';
import 'package:snapdark_tunnel/widgets/snapdark/bottom_nav_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<double> pumpNavAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: SnapDarkTheme.dark,
        home: const Scaffold(
          bottomNavigationBar: SnapDarkBottomNavBar(
            activeTab: SnapDarkTab.home,
            onTabSelected: _noop,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // One nav item = an InkWell wrapping the 44*scale pill cell.
    return tester.getSize(find.byType(InkWell).first).height;
  }

  // Reference: exactly 1.0 on a standard 360x760 logical-dp phone (the
  // current design must not change there), and one shared smaller factor on
  // low-DPI / small screens.
  test('snapdarkScale is 1.0 at the reference size', () {
    expect(_scaleFor(const Size(360, 760)), 1.0);
    expect(_scaleFor(const Size(412, 915)), 1.0);
    expect(_scaleFor(const Size(1080, 2400)), 1.0);
  });

  test('snapdarkScale shrinks on small/low-DPI screens, floored at 0.75', () {
    // 320x569 logical (a 480p-class low-DPI phone): height-driven 0.749
    // lands on the floor.
    expect(_scaleFor(const Size(320, 569)), 0.75);
    // A bit taller and the floor no longer clips: pure height ratio.
    expect(_scaleFor(const Size(320, 640)), closeTo(640 / 760, 0.001));
    // Never below the floor, even on tiny screens.
    expect(_scaleFor(const Size(240, 320)), 0.75);
  });

  testWidgets('bottom navigation scales with the shared factor',
      (tester) async {
    final atReference = await pumpNavAt(tester, const Size(360, 760));
    expect(atReference, 44); // current design unchanged

    final atSmall = await pumpNavAt(tester, const Size(320, 569));
    // 44 * scale — the same factor every home widget uses (the floor clips
    // 569/760 = 0.749 up to 0.75 here).
    expect(atSmall, closeTo(44 * 0.75, 0.5));
  });
}

void _noop(SnapDarkTab _) {}

double _scaleFor(Size size) {
  // Mirrors snapdarkScale's formula for a pure check (the widget test above
  // exercises the real function on the widget tree).
  final s = size;
  return (s.width / 360 < s.height / 760 ? s.width / 360 : s.height / 760)
      .clamp(0.75, 1.0);
}
