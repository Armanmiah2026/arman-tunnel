import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../widgets/app_toast.dart';

/// On-device exception recorder. Hooks the framework error handler, the
/// platform dispatcher and (via [main]'s zone guard) uncaught async errors,
/// keeping a ring buffer in memory plus a persistent log file under the
/// app documents directory so crashes survive an app restart.
///
/// Open `FlutterErrorLogScreen` from the drawer (debug builds) to read them.
class ErrorCapture {
  ErrorCapture._();
  static final ErrorCapture instance = ErrorCapture._();

  static const int _maxMemoryEntries = 100;
  static const int _maxFileBytes = 256 * 1024;

  final List<String> _entries = [];

  /// Bumped on every new entry so listeners (log screen badge/body) refresh.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool _installed = false;
  File? _file;

  List<String> get entries => List.unmodifiable(_entries);

  Future<void> install() async {
    if (_installed) return;
    _installed = true;

    // Handlers FIRST — synchronously. The old order awaited the documents
    // directory before hooking FlutterError.onError, so every error raised
    // during the first frames (exactly the high-DPI layout errors this
    // app must survive) landed on the default handler with no capture and
    // no toast. File resolution is fine to finish later; entries recorded
    // before it exist only in the memory ring buffer.
    FlutterError.onError = (details) {
      record('framework', details.exception, details.stack,
          context: details.library);
      // Still dump to console so adb logcat keeps working as before.
      FlutterError.presentError(details);
      AppToast.showGlobal(_toastMessage(details.exception));
    };

    PlatformDispatcher.instance.onError = (e, st) {
      record('platform', e, st);
      AppToast.showGlobal(_toastMessage(e));
      return true; // keep the app alive; the error is visible in-app
    };

    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/flutter_errors.log');
    } catch (_) {
      _file = null;
    }
  }

  /// First line of an error, truncated — a toast must be readable, not a stack.
  /// RELEASE builds get the plain category sentence instead (raw stays in the
  /// captured entry below, which is what support reads); debug shows detail.
  static String _toastMessage(Object error) {
    if (kReleaseMode) {
      return 'App error — something unexpected happened. '
          'Please try again.';
    }
    final firstLine = error.toString().split('\n').first.trim();
    if (firstLine.isEmpty) return 'Unexpected error';
    return firstLine.length > 120 ? '${firstLine.substring(0, 120)}…' : firstLine;
  }

  void record(String source, Object error, StackTrace? stack,
      {String? context}) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ts =
        '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';

    final buf = StringBuffer()
      ..writeln('──[$ts] $source${context == null ? '' : ' • $context'}')
      ..writeln(error.toString());
    if (stack != null) {
      final st = stack.toString().trim();
      if (st.isNotEmpty) {
        buf.writeln(st.split('\n').take(14).join('\n'));
      }
    }
    final entry = buf.toString().trimRight();

    _entries.add(entry);
    while (_entries.length > _maxMemoryEntries) {
      _entries.removeAt(0);
    }
    revision.value++;
    unawaited(_appendToFile(entry));
  }

  Future<void> _appendToFile(String entry) async {
    final f = _file;
    if (f == null) return;
    try {
      if (await f.exists() && await f.length() > _maxFileBytes) {
        await f.writeAsString('');
      }
      await f.writeAsString('$entry\n\n', mode: FileMode.append);
    } catch (_) {
      // Logging must never throw.
    }
  }

  /// Persisted history first (previous sessions), then this session's buffer.
  Future<String> fullLogText() async {
    final sb = StringBuffer();
    try {
      final f = _file;
      if (f != null && await f.exists()) {
        sb.write(await f.readAsString());
      }
    } catch (_) {}
    for (final e in _entries) {
      sb
        ..writeln(e)
        ..writeln();
    }
    return sb.toString();
  }

  Future<void> clearAll() async {
    _entries.clear();
    revision.value++;
    try {
      await _file?.writeAsString('');
    } catch (_) {}
  }
}
