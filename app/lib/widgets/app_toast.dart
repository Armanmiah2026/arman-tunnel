import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


enum ToastType { success, error, warning, info }

/// App-wide notifications that feel like ANDROID, not a website.
///
/// Messages go through the platform channel to a real `android.widget.Toast` —
/// the same grey pill at the bottom of the screen every Android app uses — so
/// users get the native look (with the app icon on Android 11+) instead of a
/// floating web-style card. If the platform is unavailable (tests, non-Android)
/// it falls back to a minimal dark Material snackbar.
class AppToast {
  const AppToast._();

  static const MethodChannel _channel = MethodChannel('com.snapdark.tunnel/vpn');

  /// Global messenger so error handlers WITHOUT a BuildContext (zone guard,
  /// FlutterError.onError, PlatformDispatcher.onError) can still surface a
  /// toast. Assign it to MaterialApp.scaffoldMessengerKey in main.dart.
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    if (message.trim().isEmpty) return;
    final long = type == ToastType.error || type == ToastType.warning ||
        message.length > 60;
    // Capture the messenger BEFORE the async gap: by the time the native call
    // returns the original widget may be disposed, and touching a dead
    // context is exactly what crashes with "_dependents.isEmpty is not true".
    final messenger = context.mounted ? ScaffoldMessenger.maybeOf(context) : null;
    _native(message, long).then((shown) {
      if (!shown) {
        messenger?.showSnackBar(_buildFallbackSnackBar(message));
      }
    });
  }

  /// Context-free toast for global error handlers. Tries the native channel
  /// first; falls back to the global messenger's snackbar.
  static void showGlobal(String message, {ToastType type = ToastType.error}) {
    if (message.trim().isEmpty) return;
    final long = type == ToastType.error || type == ToastType.warning ||
        message.length > 60;
    _native(message, long).then((shown) {
      if (!shown) {
        messengerKey.currentState?.showSnackBar(_buildFallbackSnackBar(message));
      }
    });
  }

  static Future<bool> _native(String message, bool long) async {
    try {
      final res = await _channel.invokeMethod<bool>(
        'showToast',
        {'msg': message, 'long': long},
      );
      return res == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Minimal fallback: plain dark snackbar, floating near the bottom — close
  /// to the Android toast look (#323232 @ ~80% like the platform widget), no
  /// borders or glows.
  static SnackBar _buildFallbackSnackBar(String message) {
    const toastGrey = Color(0xCC323232);
    return SnackBar(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      duration: const Duration(seconds: 2),
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 48),
      backgroundColor: toastGrey,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      content: Text(
        message,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }

  static void success(BuildContext c, String m) =>
      show(c, m, type: ToastType.success);
  static void error(BuildContext c, String m) =>
      show(c, m, type: ToastType.error);
  static void warning(BuildContext c, String m) =>
      show(c, m, type: ToastType.warning);
  static void info(BuildContext c, String m) =>
      show(c, m, type: ToastType.info);
}
