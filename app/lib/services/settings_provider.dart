import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ad_service.dart';
import 'device_trial.dart';
import 'vpn_service.dart';

/// App-wide persisted settings (theme + engine tunables). Drives the dark/light
/// toggle and the detailed options screen.
class SettingsProvider extends ChangeNotifier {
  static const _kThemeMode = 'snapdark_theme_mode';
  static const _kMtu = 'snapdark_mtu';
  /// Stored as a comma-separated string so the whole ordered list round-trips
  /// through one pref key. The old `snapdark_dns1`/`snapdark_dns2` keys are still
  /// read once, as a migration seed, then left alone.
  static const _kDnsServers = 'snapdark_dns_servers';
  static const _kDnsLegacy1 = 'snapdark_dns1';
  static const _kDnsLegacy2 = 'snapdark_dns2';

  /// Google-first, Cloudflare as backup. See [_dnsServers] for why the order
  /// and the multiplicity matter.
  static const List<String> defaultDnsServers = <String>[
    '8.8.8.8',
    '8.8.4.4',
    '1.1.1.1',
  ];
  static const _kWakeLock = 'snapdark_wakelock';
  static const _kAutoReconnect = 'snapdark_autoreconnect';
  static const _kKillSwitch = 'snapdark_killswitch';
  static const _kBypassLan = 'snapdark_bypass_lan';
  static const _kCustomSni = 'snapdark_custom_sni';
  static const _kSplitMode = 'snapdark_split_mode';
  static const _kSplitApps = 'snapdark_split_apps';
  static const _kRouteRules = 'snapdark_route_rules';
  static const _kTlsFragment = 'snapdark_tls_fragment';
  static const _kMuxEnabled = 'snapdark_mux_enabled';
  static const _kOvpnUseOvpn3 = 'snapdark_ovpn_use_ovpn3';
  static const _kKeepAliveMode = 'snapdark_keepalive_mode';
  static const _kPingEnabled = 'snapdark_ping_enabled';
  static const _kPingLogging = 'snapdark_ping_logging';
  static const _kPingHost = 'snapdark_ping_host';
  static const _kPingHttps = 'snapdark_ping_https';
  static const _kHotspotShare = 'snapdark_hotspot_share';
  static const _kHotspotIp = 'snapdark_hotspot_ip';
  static const _kHotspotInterface = 'snapdark_hotspot_interface';
  static const _kWallpaperPath = 'snapdark_wallpaper_path';
  static const _kWallpaperDim = 'snapdark_wallpaper_dim';
  static const _kWallpaperBlur = 'snapdark_wallpaper_blur';
  static const _kWallpaperCard = 'snapdark_wallpaper_card';
  static const _kWallpaperTitle = 'snapdark_wallpaper_title';
  static const _kWallpaperEnabled = 'snapdark_wallpaper_enabled';
  static const _kUserTweakTypes = 'snapdark_user_tweak_types';

  /// VIP unlock expiries: configId -> millisecond-epoch when the rewarded-ad
  /// unlock runs out. Persisted as a JSON string map.
  static const _kVipUnlocks = 'snapdark_vip_unlocks';

  /// Target used when the user has not set one. `connectivitycheck.gstatic.com`
  /// answers /generate_204 with an empty 204 and is demonstrably reachable
  /// through every tunnel path (SSH/OVPN). `ping.google` is NOT — the remote
  /// SSH server refuses the direct-tcpip channel for it, and trilead's
  /// optimistic SOCKS_SUCCESS + abrupt close surfaces as a local
  /// "Connection reset" on every probe.
  static const defaultPingHost = 'connectivitycheck.gstatic.com/generate_204';

  ThemeMode _themeMode = ThemeMode.dark;
  int _mtu = 1500;
  /// Resolvers handed to the tunnel, in order. Android's VpnService takes as
  /// many `addDnsServer` calls as we like, but a list still beats two named
  /// fields: several BDIX/exit routes silently drop or refuse Cloudflare's
  /// 1.1.1.1, and a single wedged resolver then looks like "the internet is
  /// down" — YouTube failing to resolve is the usual symptom.
  ///
  /// Google first (8.8.8.8 / 8.8.4.4) because users on local BDIX exits reach
  /// it reliably, then Cloudflare as a distinct-operator backup.
  List<String> _dnsServers = SettingsProvider.defaultDnsServers;
  bool _wakeLock = false;
  bool _autoReconnect = true;
  bool _killSwitch = false;
  bool _bypassLan = true;
  String _customSni = '';

  /// Split tunnel: 'off' = all apps tunneled; 'exclude' = listed apps bypass the
  /// VPN (everything else tunneled); 'include' = ONLY listed apps are tunneled.
  String _splitMode = 'off';
  Set<String> _splitApps = <String>{};
  bool _tlsFragment = true;
  bool _muxEnabled = true;

  /// OpenVPN engine choice: false = the OpenVPN 2.x exec engine (default —
  /// it accepts the weak ciphers many tunnel panels ship), true = the legacy
  /// SWIG openvpn3 ClientAPI binding kept as a compatibility escape hatch.
  bool _ovpnUseOvpn3 = false;
  int _keepAliveMode = 1;
  bool _pingEnabled = true;
  bool _pingLogging = true;
  String _pingHost = '';
  bool _pingHttps = false;
  bool _hotspotShare = true;
  String _hotspotIp = '';
  String _hotspotInterface = '';

  /// VIP rewarded-ad unlocks: configId -> native `sensei:vip:` ticket. A config
  /// that is `vip` and has no valid ticket (or a past expiry) is locked behind
  /// another watched ad. The ticket is a cert-bound AES-GCM envelope issued by
  /// libsnapdarkcrypto, so editing this line in SharedPreferences yields nothing
  /// that verifies.
  Map<String, String> _vipTickets = <String, String>{};

  /// Verified expiry (millisecond epoch) per configId, derived from the native
  /// ticket. Kept in memory so the (async) native verify never runs on a paint;
  /// `vipUnlockExpiry` reads this cache. Repopulated on load and on unlock.
  Map<String, int> _vipUnlocks = <String, int>{};

  /// When the given config's VIP unlock expires (millisecond epoch), or null
  /// if it is not currently unlocked.
  int? vipUnlockExpiry(String configId) {
    final expiry = _vipUnlocks[configId];
    if (expiry == null) return null;
    if (expiry <= DateTime.now().millisecondsSinceEpoch) {
      _vipUnlocks.remove(configId);
      return null;
    }
    return expiry;
  }

  bool isVipUnlocked(String configId, {required bool vip}) {
    if (!vip) return true;
    // Admin-granted VIP device (panel "Grant VIP"): paid access — every VIP
    // server is open without the rewarded ad, everywhere in the app.
    if (DeviceTrial.instance.isVipDevice) return true;
    // Ads gate open (pre-Play-Store): the rewarded-ad gate cannot run, so
    // every VIP config is treated as unlocked — ServerPingCache resolves +
    // pings vaulted endpoints, and the resolve path goes ticket-less.
    if (!AdConfig.adsEnabled) return true;
    return vipUnlockExpiry(configId) != null;
  }

  /// The raw native unlock ticket for [configId], or null if none/unlocked-lost.
  /// Used to present to the Worker's /api/vip/resolve, which re-verifies it
  /// server-side before releasing a vaulted VIP endpoint. Null while the ads
  /// gate is open — the Worker resolves without a ticket then.
  String? vipTicket(String configId) {
    if (!AdConfig.adsEnabled) return null;
    if (vipUnlockExpiry(configId) == null) return null;
    return _vipTickets[configId];
  }

  /// Re-verify every stored ticket natively and rebuild the expiry cache.
  /// Drops (and un-persists) any ticket that fails the GCM tag, names a
  /// different config, or has expired.
  Future<void> _refreshVipCache() async {
    final good = <String, String>{};
    final expiries = <String, int>{};
    for (final entry in _vipTickets.entries) {
      final expiry = await VpnService.verifyVipTicket(entry.value, entry.key);
      if (expiry != null) {
        good[entry.key] = entry.value;
        expiries[entry.key] = expiry.millisecondsSinceEpoch;
      }
    }
    if (good.length != _vipTickets.length) {
      _vipTickets = good;
      await _persistVipTickets();
    }
    _vipUnlocks = expiries;
  }

  Future<void> _persistVipTickets() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kVipUnlocks,
      _vipTickets.isNotEmpty
          ? _vipTickets.entries.map((e) => '${e.key}|${e.value}').join('\n')
          : '',
    );
  }

  /// Records a VIP unlock lasting [duration] for the given config. Mints a
  /// native ticket; if native refuses (integrity off) nothing is stored.
  /// Returns true only when a ticket was actually minted, verified and
  /// persisted, so callers can surface a failure instead of pretending the
  /// unlock worked.
  Future<bool> unlockVip(String configId, Duration duration) async {
    final ticket = await VpnService.issueVipTicket(configId, duration);
    if (ticket == null || ticket.isEmpty) return false;
    final expiry = await VpnService.verifyVipTicket(ticket, configId);
    if (expiry == null) return false;
    _vipTickets[configId] = ticket;
    _vipUnlocks[configId] = expiry.millisecondsSinceEpoch;
    notifyListeners();
    await _persistVipTickets();
    return true;
  }

  /// Glass/wallpaper mode: absolute path of the persisted background image.
  /// Empty = no wallpaper (the classic painted background). The file lives in
  /// the app's documents directory and is kept until app data is cleared.
  String _wallpaperPath = '';
  Uint8List? _wallpaperBytes;
  bool _wallpaperEnabled = true;

  /// Display name of the applied wallpaper (admin title / file name / '').
  String _wallpaperTitle = '';

  /// Glass tuning: dark scrim over the wallpaper, gaussian blur of the
  /// wallpaper itself, and card fill opacity — all persisted with the image.
  double _wallpaperDim = 0.35;
  double _wallpaperBlur = 0.0;
  double _wallpaperCardOpacity = 0.55;

  /// Custom routing rules, in priority order. Each entry is
  /// {action: 'direct'|'block', value: '...'} — 'direct' bypasses the tunnel
  /// (goes out raw), 'block' drops the traffic. Persisted as 'action|value'.
  List<Map<String, String>> _routeRules = <Map<String, String>>[];

  /// User-defined tweak types (Custom Tweak picker) — the admin panel's types
  /// plus whatever the user adds/imports, all editable on-device.
  List<String> _userTweakTypes = <String>[];

  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode != ThemeMode.light;
  int get mtu => _mtu;
  List<String> get dnsServers => List.unmodifiable(_dnsServers);

  /// First resolver — the TUN's primary, and what a DNSTT gateway falls back to.
  String get dnsPrimary => _dnsServers.isEmpty ? '8.8.8.8' : _dnsServers.first;

  /// Second resolver when one exists. Kept for the OpenVPN engines' two-field
  /// API and for the settings dialog's "primary / secondary" shape.
  String get dnsSecondary =>
      _dnsServers.length > 1 ? _dnsServers[1] : dnsPrimary;
  bool get wakeLock => _wakeLock;
  bool get autoReconnect => _autoReconnect;
  bool get killSwitch => _killSwitch;
  bool get bypassLan => _bypassLan;

  /// Optional SNI / bug-host that overrides the selected server's SNI at connect
  /// time, so one server can be used with different SNIs (DPI bypass). Empty =
  /// use the server's own SNI.
  String get customSni => _customSni;

  /// 'off' | 'exclude' | 'include' — see [_splitMode].
  String get splitMode => _splitMode;
  bool get splitTunnelActive => _splitMode != 'off' && _splitApps.isNotEmpty;

  /// TLS fragmentation toggle (surface UI preference; engine integration is native-side).
  bool get tlsFragment => _tlsFragment;

  /// TCP Mux multiplexing toggle (surface UI preference; engine integration is native-side).
  bool get muxEnabled => _muxEnabled;

  bool get ovpnUseOvpn3 => _ovpnUseOvpn3;

  /// 0 = battery saver, 1 = balanced, 2 = aggressive.
  int get keepAliveMode => _keepAliveMode;
  String get keepAliveLabel => switch (_keepAliveMode) {
        0 => 'Battery Saver',
        2 => 'Aggressive',
        _ => 'Balanced',
      };

  /// Whether periodic ping results are written to the Logs tab. The dial keeps
  /// showing latency either way — this only controls the log spam.
  bool get pingEnabled => _pingEnabled;

  /// Whether periodic ping results are written to the Logs tab. The dial keeps
  /// showing latency either way — this only controls the log spam.
  bool get pingLogging => _pingLogging;

  /// Probe target. Empty = [defaultPingHost]. Accepts `host`, `host/path`,
  /// `host:port/path` or a full `http(s)://…` URL.
  String get pingHost => _pingHost;

  /// Effective probe target, with the default filled in.
  String get effectivePingHost =>
      _pingHost.trim().isEmpty ? defaultPingHost : _pingHost.trim();

  /// Probe over TLS. Measures the full handshake, so expect a higher number.
  bool get pingHttps => _pingHttps;

  /// When true the engine's SOCKS/HTTP proxy endpoints bind on 0.0.0.0 so Wi-Fi
  /// hotspot clients pointed at this phone's IP can use the tunnel. When false
  /// they bind on loopback only — external devices cannot reach the proxy.
  bool get hotspotShare => _hotspotShare;

  /// Preferred endpoint shown to clients when multiple tether/LAN interfaces
  /// exist. Empty means auto-detect the best reachable private address.
  String get hotspotIp => _hotspotIp;
  String get hotspotInterface => _hotspotInterface;

  /// Package names selected for split tunneling.
  Set<String> get splitApps => Set.unmodifiable(_splitApps);

  /// Absolute path of the wallpaper image, or '' when wallpaper mode is off.
  String get wallpaperPath => _wallpaperPath;
  Uint8List? get wallpaperBytes => _wallpaperBytes;

  /// Display name of the applied wallpaper ('' = untitled).
  String get wallpaperTitle => _wallpaperTitle;
  bool get wallpaperEnabled => _wallpaperEnabled;
  bool get hasWallpaper => _wallpaperEnabled && _wallpaperPath.isNotEmpty;

  /// 0..1 dark scrim painted over the wallpaper (readability).
  double get wallpaperDim => _wallpaperDim;

  /// 0..20 gaussian blur applied to the wallpaper itself.
  double get wallpaperBlur => _wallpaperBlur;

  /// 0.2..1 card fill opacity in glass mode.
  double get wallpaperCardOpacity => _wallpaperCardOpacity;

  Future<void> setWallpaperLook({
    double? dim,
    double? blur,
    double? cardOpacity,
  }) async {
    _wallpaperDim = (dim ?? _wallpaperDim).clamp(0.0, 1.0);
    _wallpaperBlur = (blur ?? _wallpaperBlur).clamp(0.0, 20.0);
    _wallpaperCardOpacity =
        (cardOpacity ?? _wallpaperCardOpacity).clamp(0.2, 1.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kWallpaperDim, _wallpaperDim);
    await p.setDouble(_kWallpaperBlur, _wallpaperBlur);
    await p.setDouble(_kWallpaperCard, _wallpaperCardOpacity);
    notifyListeners();
  }

  /// Custom routing rules, in priority order.
  List<Map<String, String>> get routeRules => List.unmodifiable(_routeRules);

  /// User-defined tweak types (Custom Tweak picker), in display order.
  List<String> get userTweakTypes => List.unmodifiable(_userTweakTypes);

  SettingsProvider() {
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final mode = p.getString(_kThemeMode);
    // Only Dark and Light exist. First launch (no stored value) and a legacy
    // 'system' value both follow the DEVICE theme, then stay fixed until the
    // user changes it.
    if (mode == null || mode == 'system') {
      final deviceDark =
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark;
      _themeMode = deviceDark ? ThemeMode.dark : ThemeMode.light;
    } else {
      _themeMode = mode == 'light' ? ThemeMode.light : ThemeMode.dark;
    }
    _wallpaperPath = p.getString(_kWallpaperPath) ?? '';
    _wallpaperTitle = p.getString(_kWallpaperTitle) ?? '';
    _wallpaperEnabled = p.getBool(_kWallpaperEnabled) ?? true;
    if (_wallpaperPath.isNotEmpty) {
      try {
        final f = File(_wallpaperPath);
        if (await f.exists()) {
          _wallpaperBytes = await f.readAsBytes();
        } else {
          _wallpaperPath = '';
          _wallpaperTitle = '';
        }
      } catch (_) {
        _wallpaperBytes = null;
      }
    }
    _wallpaperDim = (p.getDouble(_kWallpaperDim) ?? 0.35).clamp(0.0, 1.0);
    _wallpaperBlur = (p.getDouble(_kWallpaperBlur) ?? 0.0).clamp(0.0, 20.0);
    _wallpaperCardOpacity =
        (p.getDouble(_kWallpaperCard) ?? 0.55).clamp(0.2, 1.0);
    _mtu = p.getInt(_kMtu) ?? 1500;
    _dnsServers = _loadDnsServers(p);
    _wakeLock = p.getBool(_kWakeLock) ?? false;
    // Default ON: a dropped tunnel (NAT timeout, server restart) must
    // reconnect itself — users experienced "network dies until I reconnect".
    _autoReconnect = p.getBool(_kAutoReconnect) ?? true;
    _killSwitch = p.getBool(_kKillSwitch) ?? false;
    _bypassLan = p.getBool(_kBypassLan) ?? true;
    _customSni = p.getString(_kCustomSni) ?? '';
    _splitMode = p.getString(_kSplitMode) ?? 'off';
    _splitApps = (p.getStringList(_kSplitApps) ?? const <String>[]).toSet();
    _tlsFragment = p.getBool(_kTlsFragment) ?? true;
    _muxEnabled = p.getBool(_kMuxEnabled) ?? true;
    _ovpnUseOvpn3 = p.getBool(_kOvpnUseOvpn3) ?? false;
    _keepAliveMode = (p.getInt(_kKeepAliveMode) ?? 1).clamp(0, 2);
    _pingEnabled = p.getBool(_kPingEnabled) ?? true;
    _pingLogging = p.getBool(_kPingLogging) ?? true;
    _pingHost = p.getString(_kPingHost) ?? '';
    _pingHttps = p.getBool(_kPingHttps) ?? false;
    _hotspotShare = p.getBool(_kHotspotShare) ?? true;
    _hotspotIp = p.getString(_kHotspotIp) ?? '';
    _hotspotInterface = p.getString(_kHotspotInterface) ?? '';
    _routeRules = (p.getStringList(_kRouteRules) ?? const <String>[])
        .map(_decodeRule)
        .whereType<Map<String, String>>()
        .toList();
    _userTweakTypes = p.getStringList(_kUserTweakTypes) ?? const <String>[];
    // VIP unlocks: "id|<sensei:vip:…>" lines. The value is a native ticket, not
    // a bare epoch — anything else (including the pre-2026-10 `id|epoch` lines)
    // cannot be authenticated and is dropped here.
    final rawUnlocks = p.getString(_kVipUnlocks) ?? '';
    final tickets = <String, String>{};
    if (rawUnlocks.isNotEmpty) {
      for (final line in rawUnlocks.split('\n')) {
        final i = line.indexOf('|');
        if (i <= 0) continue;
        final id = line.substring(0, i);
        final ticket = line.substring(i + 1);
        if (id.isEmpty || !ticket.startsWith(_vipTicketPrefix)) continue;
        tickets[id] = ticket;
      }
    }
    _vipTickets = tickets;
    _vipUnlocks = <String, int>{};
    notifyListeners();
    if (tickets.isNotEmpty) {
      await _refreshVipCache();
      // The verified expiry cache only exists after the native round-trip
      // above, so listeners have to be told a second time or the first
      // build of the VIP badge renders the "locked" state until something
      // else happens to notify.
      notifyListeners();
    }
  }

  /// Envelope prefix of a native VIP unlock ticket.
  static const _vipTicketPrefix = 'sensei:vip:';

  static Map<String, String>? _decodeRule(String raw) {
    final i = raw.indexOf('|');
    if (i <= 0) return null;
    final action = raw.substring(0, i);
    final value = raw.substring(i + 1).trim();
    if (value.isEmpty) return null;
    return {
      'action': action == 'block' ? 'block' : 'direct',
      'value': value,
    };
  }

  Future<void> _persistRules() async {
    final list =
        _routeRules.map((r) => '${r['action']}|${r['value']}').toList();
    (await SharedPreferences.getInstance()).setStringList(_kRouteRules, list);
  }

  Future<void> setUserTweakTypes(List<String> types) async {
    _userTweakTypes = List.of(types);
    (await SharedPreferences.getInstance())
        .setStringList(_kUserTweakTypes, _userTweakTypes);
    notifyListeners();
  }

  Future<void> addRouteRule(String value, String action) async {
    final v = value.trim();
    if (v.isEmpty) return;
    final a = action == 'block' ? 'block' : 'direct';
    // De-dup on value; last action wins.
    _routeRules.removeWhere((r) => r['value'] == v);
    _routeRules.add({'action': a, 'value': v});
    await _persistRules();
    notifyListeners();
  }

  Future<void> removeRouteRuleAt(int index) async {
    if (index < 0 || index >= _routeRules.length) return;
    _routeRules.removeAt(index);
    await _persistRules();
    notifyListeners();
  }

  Future<void> setSplitMode(String mode) async {
    _splitMode = (mode == 'exclude' || mode == 'include') ? mode : 'off';
    (await SharedPreferences.getInstance()).setString(_kSplitMode, _splitMode);
    notifyListeners();
  }

  Future<void> toggleSplitApp(String pkg, bool selected) async {
    if (selected) {
      _splitApps.add(pkg);
    } else {
      _splitApps.remove(pkg);
    }
    (await SharedPreferences.getInstance())
        .setStringList(_kSplitApps, _splitApps.toList());
    notifyListeners();
  }

  Future<void> clearSplitApps() async {
    _splitApps.clear();
    (await SharedPreferences.getInstance())
        .setStringList(_kSplitApps, const <String>[]);
    notifyListeners();
  }

  Future<void> setCustomSni(String v) async {
    _customSni = v.trim();
    // Notify listeners FIRST (synchronously,) before the async gap, so the
    // widget tree rebuilds while the dialog's context is still valid. The
    // old order (await → notifyListeners) caused `_dependents.isEmpty` when
    // the widget was deactivated during the SharedPreferences await.
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kCustomSni, _customSni);
  }

  Future<void> toggleTheme() async {
    _themeMode = isDark ? ThemeMode.light : ThemeMode.dark;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kThemeMode, isDark ? 'dark' : 'light');
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode == ThemeMode.light ? ThemeMode.light : ThemeMode.dark;
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kThemeMode, _themeMode == ThemeMode.light ? 'light' : 'dark');
    notifyListeners();
  }

  /// Persist a picked wallpaper image to the app's documents directory and
  /// enable glass mode. Kept until app data is cleared. [title] is the
  /// display name (admin wallpaper title / gallery file name / '').
  Future<void> setWallpaperBytes(Uint8List bytes, {String title = ''}) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/snapdark_wallpaper.png');
    await file.writeAsBytes(bytes, flush: true);
    // FileImage is cached by path, so rewriting the bytes alone would keep
    // showing the OLD decode until an app restart. Evicting the bare
    // FileImage is NOT enough: every renderer in this app decodes this file
    // through an Image.file cacheWidth/cacheHeight (SnapDarkWallpaperLayer at
    // screen×DPR, the sheet preview at 420px, gallery thumbs at 120px,
    // avatars at 2x size), and Flutter keys those entries as ResizeImage
    // (file path + width/height), which no single evict call can match.
    // The whole cache must go so the notify rebuild below re-decodes the
    // new bytes — the new wallpaper appears IMMEDIATELY (the avatar cache
    // refills from disk on the next frame; it is only a few KB per entry).
    PaintingBinding.instance.imageCache.clear();
    _wallpaperPath = file.path;
    _wallpaperBytes = bytes;
    _wallpaperEnabled = true;
    _wallpaperTitle = title.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kWallpaperPath, _wallpaperPath);
    await p.setString(_kWallpaperTitle, _wallpaperTitle);
    await p.setBool(_kWallpaperEnabled, true);
    notifyListeners();
  }

  /// Same as [setWallpaperBytes] but from an existing file (an admin gallery
  /// pick). COPIES into the user's wallpaper file — the admin files are
  /// overwritten by feed refreshes (same index reused), so the user's applied
  /// wallpaper must never reference one directly.
  Future<void> setWallpaperFile(File source, {String title = ''}) async {
    try {
      final bytes = await source.readAsBytes();
      await setWallpaperBytes(bytes, title: title);
    } catch (_) {/* unreadable source — keep the current wallpaper */}
  }

  /// Turn wallpaper mode off (keeps nothing — the file is removed too).
  Future<void> clearWallpaper() async {
    if (_wallpaperPath.isNotEmpty) {
      try {
        final f = File(_wallpaperPath);
        // Clear BEFORE deleting so no rebuild races the removed file. The
        // bare-FileImage evict would miss every ResizeImage(cacheWidth)
        // entry anyway (see setWallpaperBytes).
        PaintingBinding.instance.imageCache.clear();
        if (await f.exists()) await f.delete();
      } catch (_) {/* best effort */}
    }
    _wallpaperPath = '';
    _wallpaperBytes = null;
    _wallpaperEnabled = false;
    _wallpaperTitle = '';
    final p = await SharedPreferences.getInstance();
    await p.setString(_kWallpaperPath, '');
    await p.setString(_kWallpaperTitle, '');
    await p.setBool(_kWallpaperEnabled, false);
    notifyListeners();
  }

  Future<void> setWallpaperEnabled(bool v) async {
    _wallpaperEnabled = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kWallpaperEnabled, v);
  }

  /// Update only the applied wallpaper's display name (re-apply of the
  /// same file with a different title).
  Future<void> renameWallpaper(String title) async {
    _wallpaperTitle = title.trim();
    (await SharedPreferences.getInstance())
        .setString(_kWallpaperTitle, _wallpaperTitle);
    notifyListeners();
  }

  Future<void> setMtu(int v) async {
    _mtu = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setInt(_kMtu, v);
  }

  /// Replace the resolver list. Blank entries are dropped, duplicates collapse
  /// (keeping first-seen order, so the user's priority survives), and an empty
  /// result falls back to [defaultDnsServers] rather than handing the engine
  /// no DNS at all.
  Future<void> setDnsServers(List<String> servers) async {
    final cleaned = <String>[];
    for (final raw in servers) {
      final v = raw.trim();
      if (v.isEmpty || cleaned.contains(v)) continue;
      cleaned.add(v);
    }
    _dnsServers = cleaned.isEmpty ? List<String>.from(defaultDnsServers) : cleaned;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDnsServers, _dnsServers.join(','));
  }

  /// Kept for callers that think in two fields (the settings dialog).
  Future<void> setDns(String primary, String secondary) =>
      setDnsServers(<String>[primary, secondary]);

  /// Read the resolver list, seeding from the old two-key layout once.
  ///
  /// An install from before the list existed has `snapdark_dns1/2` set (and the
  /// user may have deliberately chosen them — one of them being a local
  /// resolver), so honour those instead of silently overwriting with the new
  /// defaults.
  static List<String> _loadDnsServers(SharedPreferences p) {
    final stored = p.getString(_kDnsServers);
    if (stored != null) {
      final list = stored
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (list.isNotEmpty) return list;
    }
    final legacy = <String>[
      if ((p.getString(_kDnsLegacy1) ?? '').trim().isNotEmpty)
        p.getString(_kDnsLegacy1)!.trim(),
      if ((p.getString(_kDnsLegacy2) ?? '').trim().isNotEmpty)
        p.getString(_kDnsLegacy2)!.trim(),
    ];
    if (legacy.isNotEmpty) return legacy;
    return List<String>.from(defaultDnsServers);
  }

  Future<void> setWakeLock(bool v) async {
    _wakeLock = v;
    (await SharedPreferences.getInstance()).setBool(_kWakeLock, v);
    notifyListeners();
  }

  Future<void> setAutoReconnect(bool v) async {
    _autoReconnect = v;
    (await SharedPreferences.getInstance()).setBool(_kAutoReconnect, v);
    notifyListeners();
  }

  Future<void> setKillSwitch(bool v) async {
    _killSwitch = v;
    (await SharedPreferences.getInstance()).setBool(_kKillSwitch, v);
    notifyListeners();
  }

  Future<void> setBypassLan(bool v) async {
    _bypassLan = v;
    (await SharedPreferences.getInstance()).setBool(_kBypassLan, v);
    notifyListeners();
  }

  Future<void> setTlsFragment(bool v) async {
    _tlsFragment = v;
    (await SharedPreferences.getInstance()).setBool(_kTlsFragment, v);
    notifyListeners();
  }

  Future<void> setMuxEnabled(bool v) async {
    _muxEnabled = v;
    (await SharedPreferences.getInstance()).setBool(_kMuxEnabled, v);
    notifyListeners();
  }

  Future<void> setOvpnUseOvpn3(bool v) async {
    _ovpnUseOvpn3 = v;
    (await SharedPreferences.getInstance()).setBool(_kOvpnUseOvpn3, v);
    notifyListeners();
  }

  Future<void> setKeepAliveMode(int v) async {
    _keepAliveMode = v.clamp(0, 2);
    (await SharedPreferences.getInstance())
        .setInt(_kKeepAliveMode, _keepAliveMode);
    notifyListeners();
  }

  Future<void> setHotspotShare(bool v) async {
    _hotspotShare = v;
    (await SharedPreferences.getInstance()).setBool(_kHotspotShare, v);
    notifyListeners();
  }

  Future<void> setHotspotEndpoint(
      {required String ip, required String name}) async {
    _hotspotIp = ip.trim();
    _hotspotInterface = name.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kHotspotIp, _hotspotIp);
    await p.setString(_kHotspotInterface, _hotspotInterface);
    notifyListeners();
  }

  Future<void> setPingLogging(bool v) async {
    _pingLogging = v;
    (await SharedPreferences.getInstance()).setBool(_kPingLogging, v);
    notifyListeners();
  }

  Future<void> setPingEnabled(bool v) async {
    _pingEnabled = v;
    (await SharedPreferences.getInstance()).setBool(_kPingEnabled, v);
    notifyListeners();
  }

  /// Blank clears the override and restores [defaultPingHost].
  Future<void> setPingHost(String v) async {
    _pingHost = v.trim();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kPingHost, _pingHost);
  }

  Future<void> setPingHttps(bool v) async {
    _pingHttps = v;
    (await SharedPreferences.getInstance()).setBool(_kPingHttps, v);
    notifyListeners();
  }
}
