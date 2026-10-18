import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/user_error.dart';
import '../widgets/app_toast.dart';

class LogService extends ChangeNotifier {
  static const _storageKey = 'sensei_connection_logs';
  static const _maxEntries = 250;

  final List<String> _entries = [];

  List<String> get entries => List.unmodifiable(_entries);

  /// Last error text toasted + when — suppresses a re-toast of the SAME
  /// repeating line (watchdog ticks, ping retries) without hiding new ones.
  String? _lastToasted;
  DateTime? _lastToastAt;

  /// Anything that reads as a failure gets a toast, not just an `ERROR:`
  /// prefix — the user must never have to open the Logs tab to learn the
  /// tunnel died / the server refused / the config feed is unreachable.
  static final _errorPattern = RegExp(
    r'error|fail|refus|denied|reject|dead|dropped|exhausted|unable|'
    r'blocked|no internet|unreachable|timed[ -]?out|timeout|crash',
    caseSensitive: false,
  );

  LogService() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_storageKey) ?? const <String>[];
    _entries
      ..clear()
      ..addAll(stored.take(_maxEntries));
    // No fabricated seed lines: an empty log stays empty until something real
    // happens (the old fake "native engine ready" lines looked like events).
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_storageKey, _entries);
  }

  void _append(String message) {
    final now = DateTime.now();
    final timestamp =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    _entries.add('[$timestamp] $message');
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
  }

  void add(String message) {
    final isError =
        message.startsWith('ERROR:') || _errorPattern.hasMatch(message);
    // Release builds never show raw engine/exception text — the LOG itself
    // (and the toast) carries the friendly category instead; raw detail still
    // reaches logcat + ErrorCapture for support. Debug keeps everything.
    final clean = message.startsWith('ERROR:')
        ? message.substring(6).trim()
        : message;
    final shown =
        isError && !UserError.showRaw ? UserError.forRawLine(clean) : message;
    _append(shown);
    unawaited(_persist());
    if (isError) _toastError(clean, shown);
    notifyListeners();
  }

  /// Surface every error line as a toast (context-free — works from any tab).
  void _toastError(String raw, String shown) {
    // "VPN state: error:..." lines are toasted by the state handler with a
    // categorized message — don't double-toast the same event.
    if (raw.startsWith('VPN state:')) return;
    final now = DateTime.now();
    if (_lastToasted == shown &&
        _lastToastAt != null &&
        now.difference(_lastToastAt!) < const Duration(seconds: 15)) {
      return;
    }
    _lastToasted = shown;
    _lastToastAt = now;
    AppToast.showGlobal(
      shown.length > 140 ? '${shown.substring(0, 137)}…' : shown,
    );
  }

  void error(Object error) => add('ERROR: $error');

  void clear() {
    _entries.clear();
    _append('Logs cleared');
    unawaited(_persist());
    notifyListeners();
  }
}
