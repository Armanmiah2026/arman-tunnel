import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real per-session connection records — not keyword guesses over the log.
///
/// A session begins when the VPN reports `connected` and ends on disconnect
/// (or app restart, where it is closed out as "interrupted"). Totals come from
/// the native stats stream (session deltas).
class SessionHistory extends ChangeNotifier {
  static const _storageKey = 'snapdark_session_history';
  static const _activeKey = 'snapdark_session_active';
  static const _maxEntries = 60;

  SessionHistory._();

  static final SessionHistory instance = SessionHistory._();

  final List<Map<String, dynamic>> _sessions = [];
  Map<String, dynamic>? _active;
  bool _loaded = false;

  List<Map<String, dynamic>> get sessions => List.unmodifiable(_sessions);
  Map<String, dynamic>? get active => _active;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _sessions
      ..clear()
      ..addAll(
        (prefs.getStringList(_storageKey) ?? const <String>[])
            .map(_decode)
            .whereType<Map<String, dynamic>>()
            .toList(),
      );
    _active = prefs.getString(_activeKey) == null
        ? null
        : _decode(prefs.getString(_activeKey)!);
    _loaded = true;
  }

  /// Mark a session start. Replaces any stale "active" record (app killed
  /// mid-session) by closing it out first.
  Future<void> begin(String serverName, {String protocol = ''}) async {
    await _ensureLoaded();
    if (_active != null) {
      await end(bytesDown: 0, bytesUp: 0);
    }
    _active = {
      'server': serverName,
      'protocol': protocol,
      'start': DateTime.now().millisecondsSinceEpoch,
      'end': null,
      'down': 0,
      'up': 0,
      'ok': true,
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, _encode(_active!));
    notifyListeners();
  }

  /// Close the active session and persist it with its traffic totals.
  Future<void> end({required int bytesDown, required int bytesUp}) async {
    await _ensureLoaded();
    final s = _active;
    if (s == null) return;
    s['end'] = DateTime.now().millisecondsSinceEpoch;
    // Only overwrite with real numbers; zero totals on an immediate stop are
    // legitimate but stale zeros from a previous crash are handled above.
    s['down'] = bytesDown > 0 ? bytesDown : (s['down'] ?? 0);
    s['up'] = bytesUp > 0 ? bytesUp : (s['up'] ?? 0);

    _sessions.insert(0, s);
    if (_sessions.length > _maxEntries) {
      _sessions.removeRange(_maxEntries, _sessions.length);
    }
    _active = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeKey);
    await prefs.setStringList(
      _storageKey,
      _sessions.map(_encode).toList(),
    );
    notifyListeners();
  }

  String _encode(Map<String, dynamic> m) =>
      m.entries.map((e) => '${e.key}=${e.value}').join('|');

  Map<String, dynamic>? _decode(String raw) {
    final out = <String, dynamic>{};
    for (final part in raw.split('|')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final k = part.substring(0, i);
      final v = part.substring(i + 1);
      out[k] = v == 'null'
          ? null
          : (int.tryParse(v) ?? (v == 'true' ? true : v == 'false' ? false : v));
    }
    return out.containsKey('server') && out.containsKey('start') ? out : null;
  }
}
