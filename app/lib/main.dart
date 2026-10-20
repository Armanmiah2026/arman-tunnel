import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'models/server_config.dart';
import 'models/vpn_state.dart';
import 'screens/splash_screen.dart';
import 'services/config_service.dart';
import 'services/device_trial.dart';
import 'services/vpn_service.dart';
import 'widgets/app_toast.dart';
import 'widgets/ui/snapdark_modal.dart';
import 'widgets/ui/snapdark_wallpaper.dart';
import 'services/error_capture_service.dart';
import 'services/location_service.dart';
import 'services/log_service.dart';
import 'services/settings_provider.dart';
import 'services/ad_service.dart';
import 'theme/snapdark_theme.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    ErrorCapture.instance.install();
    // VIP-device flag first: the VIP-server gate must know an admin-granted
    // device even on a fully offline cold start.
    await DeviceTrial.instance.restoreCached();
    await AdService.initialize();
    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => VpnState()),
          ChangeNotifierProvider(create: (_) => ConfigService()),
          ChangeNotifierProvider(create: (_) => LogService()),
          ChangeNotifierProvider(create: (_) => LocationService()),
        ],
        child: const SnapDarkTunnelApp(),
      ),
    );
  }, (e, st) {
    ErrorCapture.instance.record('zone', e, st);
    // Release users get the category sentence only (raw detail is recorded);
    // debug/profile keeps the exception's first line.
    AppToast.showGlobal(kReleaseMode
        ? 'App error — something unexpected happened. Please try again.'
        : 'Unexpected error: ${e.toString().split('\n').first}');
  });
}

class SnapDarkTunnelApp extends StatefulWidget {
  const SnapDarkTunnelApp({super.key});

  @override
  State<SnapDarkTunnelApp> createState() => _SnapDarkTunnelAppState();
}

class _SnapDarkTunnelAppState extends State<SnapDarkTunnelApp> {
  static const platform = MethodChannel('com.snapdark.tunnel/vpn');

  late final SettingsProvider _settings;

  /// Last known wallpaper state, so the system UI mode is only switched when
  /// glass mode actually toggles (not on every unrelated settings change).
  bool _wasGlass = false;

  /// Wallpaper Mode must run EDGE TO EDGE: a transparent nav-bar colour alone
  /// does not make the window draw behind the bar (it would render a solid
  /// black strip instead). Switching the system UI mode sets the real layout
  /// flags; leaving glass mode restores the classic bars.
  ///
  /// Works in BOTH themes: the root layer's dim scrim is palette-aware
  /// (near-black on dark, near-white frost on light), so text keeps its
  /// contrast in either mode.
  void _applySystemUiForGlass() {
    final glass = _settings.hasWallpaper;
    if (glass == _wasGlass) return;
    _wasGlass = glass;
    if (glass) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }
  /// Import shared/link/file text from OUTSIDE the app's UI (no navigator
  /// above this widget, so PIN prompts use the modal helper directly).
  /// Password-gated shares (legacy v2p marker or v48 LockPinRequired) ask
  /// for the password and the import is retried once.
  Future<void> _importText(BuildContext context, String text,
      {bool darkTunnel = false}) async {
    final cfg = context.read<ConfigService>();

    Future<String?> askPin(String title, String hint) async {
      final pinCtrl = TextEditingController();
      final ok = await SnapDarkModal.popup<bool>(
        context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.lock_outline_rounded,
              color: context.tokens.accent, size: 26),
          title: Text(title),
          content: TextField(
            controller: pinCtrl,
            obscureText: true,
            decoration: InputDecoration(hintText: hint),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Unlock')),
          ],
        ),
      );
      final pin = ok == true ? pinCtrl.text.trim() : null;
      pinCtrl.dispose();
      return (pin == null || pin.isEmpty) ? null : pin;
    }

    var pin = isPinLockedText(text)
        ? await askPin('Locked config', 'Lock PIN from the sharer')
        : null;
    if (isPinLockedText(text) && pin == null) return;

    for (var attempt = 0;; attempt++) {
      try {
        final ServerConfig? last;
        final int count;
        if (darkTunnel) {
          last = await cfg.importFromUri(text, lockPin: pin);
          count = last == null ? 0 : 1;
        } else {
          final r = await cfg.importFromText(text, lockPin: pin);
          count = r.count;
          last = r.last;
        }
        if (!context.mounted) return;
        if (count > 0 && last != null) {
          AppToast.success(
            context,
            count > 1
                ? 'Imported: $count configs'
                : 'Imported: ${last.displayName}',
          );
        } else {
          AppToast.error(
            context,
            isPinLockedText(text)
                ? 'Wrong lock PIN — ask the sharer for it'
                : 'Could not import that',
          );
        }
        return;
      } on LockPinRequired {
        if (!context.mounted) return;
        if (attempt > 0) {
          AppToast.error(context, 'This config is password-locked');
          return;
        }
        pin = await askPin('Password-locked share', 'Password from the sharer');
        if (pin == null) {
          if (context.mounted) {
            AppToast.error(context, 'Import cancelled — password required');
          }
          return;
        }
      } catch (e, st) {
        logImportError('text', e, st);
        if (context.mounted) {
          AppToast.error(context, 'Could not import that — check the format.');
        }
        return;
      }
    }
  }
  Future<void> _handleConfigFile(String uri) async {
    if (!mounted) return;
    final body = await VpnService.readConfigFile(uri);
    if (!mounted) return;
    if (body == null || body.trim().isEmpty) {
      AppToast.error(context, 'Could not read that file');
      return;
    }
    await _importText(context, body);
  }

  @override
  void initState() {
    super.initState();
    // Glass on/off also flips the system bars (edge-to-edge ↔ classic).
    _settings = context.read<SettingsProvider>();
    _settings.addListener(_applySystemUiForGlass);
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onConfigFile') {
        // A config file (.st/.txt/.cfg) opened from a file manager: read the
        // content URI through the native channel and run the text importer.
        final uri = call.arguments as String;
        if (mounted) {
          unawaited(_handleConfigFile(uri));
        }
        return;
      }
      if (call.method == 'onSharedText') {
        final text = call.arguments as String;
        if (mounted) await _importText(context, text);
        return;
      }
      if (call.method == 'onDeepLink') {
        final link = call.arguments as String;
        if (mounted) {
          // darktunnel:// goes through its own parser; every other supported
          // scheme (vless/vmess/trojan/ss) flows through the generic text
          // importer, which dispatches on the prefix.
          await _importText(context, link,
              darkTunnel: link.startsWith('darktunnel://'));
        }
      }
    });
    // The handler above is what cold-start intents were racing against —
    // native now releases any queued deep link / share / file-open.
    VpnService.notifyNativeReady();
    // Pre-warm installed build facts so the force-update gate compares against
    // the REAL version code (split APKs report 591/592, not the baked 59).
    unawaited(context.read<ConfigService>().primeInstallInfo());
    // Register this device with the Worker so the admin sees it in the panel
    // and the BDIX trial auto-starts. Best-effort: a failure here is silent.
    unawaited(DeviceTrial.instance.register());
  }

  @override
  void dispose() {
    _settings.removeListener(_applySystemUiForGlass);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    // Wallpaper Mode rides the THEME, not a per-screen stack: the glass knobs
    // (path/dim/blur/card opacity) are folded into the active palette and the
    // theme is rebuilt through SnapDarkTheme.buildFor, so every Material
    // surface — pages, dialogs, sheets, menus, the drawer — turns glass
    // together. The wallpaper itself is painted once, at the root, by
    // [SnapDarkWallpaperLayer] (see builder below). The layer's dim scrim is
    // palette-aware, so BOTH themes render it (dark = near-black scrim,
    // light = near-white frost) and text keeps contrast in either mode.
    final wallpaperActive = settings.hasWallpaper;
    SnapDarkTokens decorate(SnapDarkTokens base) => wallpaperActive
        ? base.copyWith(
            wallpaperPath: settings.wallpaperPath,
            wallpaperBytes: settings.wallpaperBytes,
            wallpaperDim: settings.wallpaperDim,
            wallpaperBlur: settings.wallpaperBlur,
            wallpaperCardOpacity: settings.wallpaperCardOpacity,
          )
        : base;
    return MaterialApp(
      title: 'SnapDark Tunnel',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: AppToast.messengerKey,
      theme: SnapDarkTheme.buildFor(decorate(SnapDarkTokens.light)),
      darkTheme: SnapDarkTheme.buildFor(decorate(SnapDarkTokens.dark)),
      themeMode: settings.themeMode,
      // Keep text scaling sane: the connect dial and the pill nav break down
      // past ~1.3x, and system fonts on some OEM ROMs default very large.
      builder: (context, child) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        // Brightness-aware system bars. Without this, whatever style the last
        // screen set (e.g. the always-dark splash) persisted after navigation
        // and left WHITE status-bar icons on the light theme.
        final dark = settings.themeMode != ThemeMode.light &&
            (settings.themeMode == ThemeMode.dark ||
                MediaQuery.platformBrightnessOf(context) == Brightness.dark);
        final style = SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              dark ? Brightness.light : Brightness.dark,
          // Glass mode (dark theme + wallpaper): transparent so the wallpaper
          // runs edge to edge behind the floating pill nav instead of ending
          // at a solid strip. contrastEnforced MUST be false too — on 3-button
          // nav Android paints its own grey scrim over a transparent bar,
          // which would hide the wallpaper behind a dull strip.
          systemNavigationBarColor: wallpaperActive
              ? Colors.transparent
              : (dark ? const Color(0xFF0B0913) : Colors.white),
          systemNavigationBarContrastEnforced:
              wallpaperActive ? false : null,
          systemNavigationBarIconBrightness:
              dark ? Brightness.light : Brightness.dark,
        );
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: style,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale.clamp(0.9, 1.25)),
            ),
            // Wallpaper Mode: the image sits BEHIND the whole Navigator, so
            // it is visible not only behind the four shell tabs but behind
            // every pushed route as well. Screens/scaffolds go translucent
            // via the glass tokens; opaque screens (the splash) still cover
            // it by painting their own background.
            child: Stack(
              fit: StackFit.expand,
              children: [
                const SnapDarkWallpaperLayer(),
                child ?? const SizedBox.shrink(),
              ],
            ),
          ),
        );
      },
      home: const SplashScreen(),
    );
  }
}
