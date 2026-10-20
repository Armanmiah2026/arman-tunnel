import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_meta.dart';
import 'obf.dart';

/// BDIX device trial system (key + device-id).
///
/// The device is identified by a stable hardware hash (ANDROID_ID + build
/// fingerprint + install cert — see `ShareEnvelope.deviceHwid`), which survives
/// an app delete + reinstall, so a reinstall cannot farm a fresh trial. The
/// first time the app registers, the Worker auto-starts a 1-day trial; after
/// that the admin extends the expiry from the panel (the "purchase").
///
/// The device also reports its app version + platform info so the admin
/// panel's user management shows detailed per-user records.
///
/// All calls are best-effort: a failure to reach the Worker must never brick
/// the app, it just means the trial state is unknown (the connect gate treats
/// "unknown" conservatively for BDIX servers only).
class DeviceTrial {
  DeviceTrial._();
  static final DeviceTrial instance = DeviceTrial._();

  static const MethodChannel _channel = MethodChannel('com.snapdark.tunnel/vpn');

  String? _deviceId;
  Map<String, dynamic>? _status;

  /// Last known admin-granted VIP flag, persisted so the VIP-server gate
  /// works offline on the next cold start (before the CDN status read).
  static const _kVipFlag = 'snapdark_device_vip';
  bool _vipCached = false;

  /// Stable hardware id, or null when the platform call fails.
  String? get deviceId => _deviceId;

  /// Last known trial status (null = not fetched yet).
  Map<String, dynamic>? get status => _status;

  bool get isActive => _status?['active'] == true;

  /// Admin-granted VIP (paid/permanent) — the panel's `Grant VIP`. VIP
  /// devices open every VIP server WITHOUT the rewarded ad, and the Worker
  /// resolves vaulted endpoints for them by device id. Falls back to the
  /// last persisted flag until the fresh status arrives.
  bool get isVipDevice => _status?['vip'] == true || _vipCached;

  /// Load the persisted VIP flag (call once at startup, after prefs exist).
  Future<void> restoreCached() async {
    try {
      final p = await SharedPreferences.getInstance();
      _vipCached = p.getBool(_kVipFlag) ?? false;
    } catch (_) {
      // Prefs unavailable (tests) — stay non-VIP; the status read fixes it.
    }
  }

  Future<void> _rememberVip(bool vip) async {
    _vipCached = vip;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kVipFlag, vip);
    } catch (_) {
      // Best-effort cache only — never fail the flow for this.
    }
  }

  /// Fetch (and cache) the device id from the platform. Returns null on failure.
  Future<String?> ensureDeviceId() async {
    if (_deviceId != null && _deviceId!.isNotEmpty) return _deviceId;
    try {
      final id = await _channel.invokeMethod<String>('getDeviceId');
      if (id != null && id.isNotEmpty) {
        _deviceId = id;
        return id;
      }
    } catch (_) {
      // Platform unavailable (tests, desktop) — fall through to null.
    }
    return null;
  }

  /// Platform info (Android version + device model) for the admin panel.
  Future<Map<String, String>> _deviceInfo() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('getDeviceInfo');
      if (info != null) {
        return {
          'appVersion': kAppVersion,
          'platform': info['platform']?.toString() ?? '',
        };
      }
    } catch (_) {
      // Platform unavailable — fall through to app version only.
    }
    return {'appVersion': kAppVersion, 'platform': ''};
  }

  /// Register this device with the Worker. Idempotent: the first call starts
  /// the 1-day trial, later calls just refresh `lastSeen`. Returns the status
  /// map, or null when the Worker could not be reached.
  Future<Map<String, dynamic>?> register() async {
    final id = await ensureDeviceId();
    if (id == null) return null;
    final info = await _deviceInfo();
    try {
      final res = await http.post(
        Uri.parse('${Obf.adminUrl}/api/device/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': id,
          'appVersion': info['appVersion'],
          'platform': info['platform'],
        }),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        _status = data['status'] as Map<String, dynamic>?;
        _rememberVip(_status?['vip'] == true);
        return _status;
      }
    } catch (_) {
      // Offline / worker down — leave the cached status as-is.
    }
    return _status;
  }

  /// Poll the current trial status (the connect gate calls this before BDIX).
  ///
  /// Reads the per-device status file the Worker publishes to the configs
  /// repo (`<deviceId>.json` on the your CONFIG_RAW_BASE host GitHub-Pages CDN).
  /// That read is free and unlimited, so an active device costs the admin's
  /// Cloudflare Worker NOTHING (the free tier is 100k requests and 1000 KV
  /// writes a day). Returns null when the file is missing or unreadable —
  /// the caller then registers (the ONLY Worker call the app makes), which
  /// publishes the file so every subsequent read comes from the CDN.
  Future<Map<String, dynamic>?> refreshStatus() async {
    final id = await ensureDeviceId();
    if (id == null) return null;
    final cdn = await _statusFromCdn(id);
    if (cdn != null) {
      _status = cdn;
      _rememberVip(_status?['vip'] == true);
      return _status;
    }
    return null;
  }

  /// Fetch the published per-device status file from the configs CDN. No
  /// cache-buster: the whole point is a free cached read; a file stale by a
  /// few minutes is fine because the connect gate falls back to the Worker
  /// (whose register response carries the fresh status). Returns null when
  /// the file is missing or unreadable.
  Future<Map<String, dynamic>?> _statusFromCdn(String id) async {
    try {
      final res = await http.get(Uri.parse('${Obf.githubConfigBase}/$id.json'));
      if (res.statusCode == 200) {
        final file = jsonDecode(res.body) as Map<String, dynamic>;
        if (file['deviceId']?.toString() == id) return file;
      }
    } catch (_) {
      // Offline / CDN down — caller falls back to the Worker.
    }
    return null;
  }
}
