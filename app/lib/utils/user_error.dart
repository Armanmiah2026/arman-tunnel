import 'package:flutter/foundation.dart';

import '../models/vpn_state.dart';

/// User-safe error text.
///
/// A RELEASE build must never toast raw exception text or code slugs
/// ("hijibiji code error") — users understand categories, not stack traces:
/// Network error / Server error / Access error / App error. The raw detail
/// always stays in the Logs tab and ErrorCapture (support path); DEBUG builds
/// additionally show it inline in every toast so development keeps its
/// diagnosability.
class UserError {
  const UserError._();

  /// True when raw details may be shown to the user (debug/profile builds).
  static bool get showRaw => !kReleaseMode;

  /// Categorized VPN error → toast/error-screen text.
  static String forCategory(ErrorCategory category, {String? raw}) {
    final friendly = switch (category) {
      ErrorCategory.network =>
        'Network error — check your internet connection and try again.',
      ErrorCategory.server =>
        'Server error — this server is not responding. Try another one.',
      ErrorCategory.auth =>
        'Access error — the server rejected the login details.',
      ErrorCategory.config =>
        'App error — this configuration could not be used.',
      ErrorCategory.unknown || ErrorCategory.none =>
        'Something went wrong — please try again.',
    };
    return withRaw(friendly, raw);
  }

  /// A raw log line (LogService's error-toast) → release-safe category text,
  /// same vocabulary as [forCategory]. Debug keeps the line verbatim.
  static String forRawLine(String line) {
    if (showRaw) return line;
    final m = line.toLowerCase();
    if (m.contains('auth') ||
        m.contains('credential') ||
        m.contains('password') ||
        m.contains('login') ||
        m.contains('permission denied')) {
      return 'Access error — the server rejected the login details.';
    }
    if (m.contains('integrity') ||
        m.contains('config') ||
        m.contains('parse') ||
        m.contains('invalid') ||
        m.contains('decrypt')) {
      return 'App error — configuration could not be loaded.';
    }
    if (m.contains('server') ||
        m.contains('relay') ||
        m.contains('refused') ||
        m.contains('blocked') ||
        m.contains('tunnel') ||
        m.contains('handshake') ||
        m.contains('engine')) {
      return 'Server error — the tunnel server did not respond. Try another one.';
    }
    if (m.contains('network') ||
        m.contains('internet') ||
        m.contains('unreachable') ||
        m.contains('timeout') ||
        m.contains('timed out') ||
        m.contains('dns') ||
        m.contains('dropped')) {
      return 'Network error — check your internet connection and try again.';
    }
    return 'Something went wrong — please try again.';
  }

  /// Any Dart exception (zone guard, connect call, file IO) → safe text.
  static String forException(Object error, {String? friendly}) {
    final base = friendly ?? 'App error — something unexpected happened.';
    return showRaw ? '$base (${error.toString().split('\n').first})' : base;
  }

  /// Append raw detail only for debug builds.
  static String withRaw(String friendly, [Object? raw]) {
    if (!showRaw) return friendly;
    final r = raw?.toString().trim() ?? '';
    if (r.isEmpty || r == friendly) return friendly;
    final cut = r.length > 160 ? '${r.substring(0, 157)}…' : r;
    return '$friendly [$cut]';
  }
}
