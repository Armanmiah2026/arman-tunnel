import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_meta.dart';
export '../app_meta.dart' show kAppVersion, kAppBuildNumber;
import '../models/vpn_state.dart';
import '../theme/snapdark_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/snapdark/about_dialog.dart';
import '../widgets/snapdark/bottom_nav_bar.dart';
import '../widgets/snapdark/navigation_drawer.dart';
import '../widgets/snapdark/speed_test_modal.dart';
import '../widgets/ui/snapdark_modal.dart';
import 'log_screen.dart';
import 'snapdark_home_screen.dart';
import 'servers_screen.dart';
import 'settings_screen.dart';

/// App shell: floating pill bottom navigation hosting
/// Home / Configs / Logs / Settings, plus the side drawer for everything else.
///
/// The main content scales, translates and dims as one synchronized unit,
/// while the drawer remains behind it with the same animation value.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin {
  static const _drawerDuration = Duration(milliseconds: 280);
  static const double _contentScaleDelta = 0.055;
  static const double _drawerMaxWidth = 320;
  static const double _drawerWidthFraction = 0.84;
  static const double _edgeDragWidthFraction = 0.08;
  static const double _minOpenVelocity = 360;

  late final AnimationController _drawerController;
  late final Animation<double> _drawerCurve;
  SnapDarkTab _tab = SnapDarkTab.home;
  DateTime? _lastBackPress;

  bool get _isDrawerOpen => _drawerController.value > 0;

  @override
  void initState() {
    super.initState();
    _drawerController = AnimationController(
      vsync: this,
      duration: _drawerDuration,
      reverseDuration: _drawerDuration,
      value: 0,
    );
    _drawerCurve = CurvedAnimation(
      parent: _drawerController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _drawerController.dispose();
    super.dispose();
  }

  void _openDrawer() {
    if (_isDrawerOpen) return;
    HapticFeedback.lightImpact();
    _animateDrawer(open: true);
  }

  void _closeDrawer() {
    if (!_isDrawerOpen) return;
    HapticFeedback.selectionClick();
    _animateDrawer(open: false);
  }

  void _animateDrawer({required bool open}) {
    final media = MediaQuery.maybeOf(context);
    final reduceMotion =
        media?.disableAnimations == true || media?.accessibleNavigation == true;
    if (reduceMotion) {
      _drawerController.value = open ? 1 : 0;
      return;
    }
    if (open) {
      _drawerController.forward();
    } else {
      _drawerController.reverse();
    }
  }

  void _handleDrawerDragUpdate(DragUpdateDetails details, double drawerWidth) {
    final delta = details.primaryDelta ?? 0;
    _drawerController.value =
        (_drawerController.value + delta / drawerWidth).clamp(0.0, 1.0);
  }

  void _handleDrawerDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() >= _minOpenVelocity) {
      _animateDrawer(open: velocity > 0);
      return;
    }
    _animateDrawer(open: _drawerController.value >= 0.5);
  }

  void _handleDrawerDragCancel() {
    _animateDrawer(open: _drawerController.value >= 0.5);
  }

  void _selectTab(SnapDarkTab t) {
    if (_tab == t) return;
    setState(() => _tab = t);
  }

  /// Back button: from any tab, return to Home first; from Home, require a
  /// second press to leave the app. Tabs are not routes, so this is the only
  /// place the behaviour can live.
  void _handleBack(bool didPop) {
    if (didPop) return;
    if (_isDrawerOpen) {
      _closeDrawer();
      return;
    }
    if (_tab != SnapDarkTab.home) {
      setState(() => _tab = SnapDarkTab.home);
      return;
    }
    final now = DateTime.now();
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      AppToast.info(context, 'Press back again to exit');
      return;
    }
    SystemNavigator.pop();
  }

  void _openSpeedTest() {
    // The test measures through the tunnel — only meaningful when connected.
    if (!context.read<VpnState>().isConnected) {
      AppToast.warning(
          context,
          'Connect the tunnel first — the test measures '
          'through it');
      return;
    }
    SnapDarkModal.sheet<void>(
      context,
      padded: false,
      scrollable: false,
      builder: (_) => const SnapDarkSpeedTestSheet(),
    );
  }

  void _openAbout() {
    SnapDarkModal.popup<void>(
      context,
      builder: (_) => const SnapDarkAboutDialog(version: kAppVersion),
    );
  }

  double _drawerWidth(double availableWidth) {
    return (availableWidth * _drawerWidthFraction)
        .clamp(240.0, _drawerMaxWidth)
        .toDouble();
  }

  Widget _buildDrawer(double drawerWidth, double animationValue) {
    // The drawer rides UNDER the main content, which is fully transparent in
    // glass (wallpaper) mode. Painting it while closed made every menu row
    // bleed through the whole UI — so nothing is painted until the slide
    // actually starts.
    if (animationValue <= 0) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: drawerWidth,
      child: IgnorePointer(
        ignoring: _drawerController.value <= 0,
        child: Opacity(
          opacity: 0.72 + (0.28 * animationValue),
          child: SnapDarkNavigationDrawer(
            currentTab: _tab,
            version: kAppVersion,
            onNavigateTab: _selectTab,
            onOpenSpeedTest: _openSpeedTest,
            onOpenAbout: _openAbout,
            onCloseDrawer: _closeDrawer,
          ),
        ),
      ),
    );
  }

  Widget _buildMainContent(
    BuildContext context,
    double progress,
    double slide,
  ) {
    return Transform.translate(
      offset: Offset(slide, 0),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: progress > 0
            ? (details) => _handleDrawerDragUpdate(
                  details,
                  _drawerWidth(MediaQuery.sizeOf(context).width),
                )
            : null,
        onHorizontalDragEnd: progress > 0 ? _handleDrawerDragEnd : null,
        onHorizontalDragCancel:
            progress > 0 ? _handleDrawerDragCancel : null,
        child: Transform.scale(
          scale: 1 - (_contentScaleDelta * progress),
          alignment: Alignment.centerLeft,
          child: Material(
            color: Colors.transparent,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Scaffold(
                  backgroundColor: context.tokens.scaffoldBg,
                  body: IndexedStack(
                    index: _tab.index,
                    children: [
                      SnapDarkHomeScreen(
                        onMenuClick: _openDrawer,
                        onOpenConfigs: () => _selectTab(SnapDarkTab.configs),
                        onOpenSpeedTest: _openSpeedTest,
                      ),
                      ServersScreen(
                        // Inside the shell there is nothing to pop; jump to
                        // Home instead.
                        onServerSelected: () => _selectTab(SnapDarkTab.home),
                      ),
                      const LogScreen(),
                      const SettingsScreen(),
                    ],
                  ),
                  bottomNavigationBar: SnapDarkBottomNavBar(
                    activeTab: _tab,
                    onTabSelected: _selectTab,
                  ),
                ),
                if (progress > 0)
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: progress < 0.02,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _closeDrawer,
                        child: ColoredBox(
                          color: Colors.black.withValues(
                            alpha: 0.48 * progress,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEdgeDrag(double edgeDragWidth) {
    if (_drawerController.value >= 1) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: edgeDragWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => _handleDrawerDragUpdate(
          details,
          _drawerWidth(MediaQuery.sizeOf(context).width),
        ),
        onHorizontalDragEnd: _handleDrawerDragEnd,
        onHorizontalDragCancel: _handleDrawerDragCancel,
      ),
    );
  }

  Widget _buildShell() {
    // Wallpaper Mode lives at the app ROOT (main.dart): the image is painted
    // behind the whole Navigator and the glass tokens ride the theme, so this
    // shell needs no wallpaper handling of its own — every surface below is
    // already translucent when glass mode is on.
    final t = context.tokens;
    return LayoutBuilder(
      builder: (context, constraints) {
        final drawerWidth = _drawerWidth(constraints.maxWidth);
        final edgeDragWidth = constraints.maxWidth * _edgeDragWidthFraction;
        return AnimatedBuilder(
          animation: _drawerCurve,
          builder: (context, _) {
            final progress = _drawerCurve.value;
            return Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: t.scaffoldBg),
                _buildDrawer(drawerWidth, progress),
                _buildMainContent(
                  context,
                  progress,
                  drawerWidth * progress,
                ),
                _buildEdgeDrag(edgeDragWidth),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // ignore: deprecated_member_use
      onPopInvoked: _handleBack,
      child: _buildShell(),
    );
  }
}
