import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode, listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_config.dart';
import '../app_meta.dart';
import '../utils/darktunnel_codec.dart';
import 'vpn_service.dart';
import 'device_trial.dart';
import 'obf.dart';
import 'ad_service.dart';
import 'tunnel_http_client.dart';

/// Thrown when the pasted text is a user-locked share (`sensei:v2p:`) and no
/// lock PIN was supplied. The UI catches this, asks for the PIN, and retries.
class LockPinRequired implements Exception {
  const LockPinRequired();

  @override
  String toString() => 'LockPinRequired';
}

/// One downloaded admin wallpaper: its local file + panel-assigned title.
class AdminWallpaper {
  final String path;
  final String title;
  const AdminWallpaper({required this.path, required this.title});
}

/// True when [text] is a user-locked share that needs a PIN to import.
bool isPinLockedText(String text) {
  final t = text.trim();
  if (t.startsWith('sensei:v2p:')) return true;
  // DarkTunnel locked .dark shares may carry a seller password lock.
  if (t.startsWith('darktunnel://')) {
    return DarkTunnelCodec.requiresPassword(t);
  }
  return false;
}

/// Result of `ConfigService.importFromText`: how many configs landed in
/// My Configs and the last one (for toasts / auto-select). A multi-section
/// .st file or a backup link can import several at once.
typedef ImportResult = ({int count, ServerConfig? last});

/// Shared import failure logging: debug builds print the full exception +
/// stack (so a shared-then-import-fails report can be diagnosed), release
/// builds print only a one-line reason. User-facing toasts elsewhere stay
/// generic — this is the detail channel.
void logImportError(String source, Object error, [StackTrace? stack]) {
  try {
    if (kDebugMode) {
      debugPrint('[import:$source] $error\n$stack');
    } else {
      debugPrint('[import:$source] ${error.toString().split('\n').first}');
    }
  } catch (_) {
    // Logging must never break the import itself.
  }
}

/// A Tweak category published by the admin panel — one section header in the
/// app's Configs menu. [country] is the ISO-2 flag code (earth when empty).
class AppCategory {
  final String name;
  final String country;
  const AppCategory({required this.name, required this.country});

  Map<String, dynamic> toJson() => {'name': name, 'country': country};

  static AppCategory fromJson(Map<String, dynamic> j) => AppCategory(
        name: (j['name'] ?? '').toString(),
        country: (j['country'] ?? '').toString().toUpperCase(),
      );

  @override
  bool operator ==(Object other) =>
      other is AppCategory &&
      other.name.toLowerCase() == name.toLowerCase() &&
      other.country == country;

  @override
  int get hashCode => Object.hash(name.toLowerCase(), country);
}

class AppCapabilityType {
  final String name;
  final String description;
  const AppCapabilityType({required this.name, this.description = ''});

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
      };

  static AppCapabilityType fromJson(Map<String, dynamic> j) => AppCapabilityType(
        name: (j['name'] ?? '').toString().toUpperCase(),
        description: (j['description'] ?? '').toString(),
      );
}

class ConfigService extends ChangeNotifier {
  static const String _storageKey = 'sensei_tunnel_servers';
  static const String _selectedStorageKey = 'sensei_tunnel_selected_server';
  static const String _subUrlKey = 'sensei_subscription_url';
  static const String _categoriesKey = 'sensei_categories';
  static const String _adminWallpapersKey = 'sensei_admin_wallpapers';
  static const String _typesKey = 'sensei_capability_types';
  static const String _typeMetaKey = 'sensei_capability_type_meta';
  static final String _githubConfigUrl = Obf.githubConfigUrl;
  static final String _githubSettingsUrl = Obf.githubSettingsUrl;
  static final String _githubConfigKey = Obf.githubConfigKey;

  List<ServerConfig> _servers = [];
  List<AppCategory> _categories = [];

  /// Capability types published by the panel ([SNI], [PROXY+PAYLOAD]…) —
  /// the Custom Tweak picker's options.
  List<AppCapabilityType> _capabilityTypes = [];
  ServerConfig? _selectedServer;
  bool _isLoading = false;
  String _error = '';

  /// Set when the last [loadServers] could not refresh the official feed
  /// (network / decrypt failure) — manual refreshes surface it honestly
  /// instead of a fake "configs updated".
  bool lastRefreshFailed = false;
  bool _appLocked = false;
  String _lockedMessage = '';
  bool _forceUpdate = false;
  String _latestVersion = '';
  String _updateUrl = '';
  String _updateMessage = '';
  String _subscriptionUrl = '';
  Map<String, dynamic>? _subscriptionUsage;

  // Broadcast notice payload (the panel's "App Control → Broadcast"), delivered
  // inside the encrypted settings bundle.
  String _broadcastKey = ''; // updatedAt — used for show-once semantics
  bool _broadcastShowDialog = false;
  String _broadcastTitle = '';
  String _broadcastMessage = '';
  String _broadcastActionText = '';
  String _broadcastActionUrl = '';
  bool _broadcastMarquee = false;
  String _broadcastMarqueeText = '';
  bool _maintenanceMode = false;
  String _maintenanceMessage = '';
  // Provider branding (panel → GitHub settings bundle → here).
  String _providerName = '';
  String _providerContact = '';
  String _providerWhatsapp = '';
  String _providerDescription = '';

  /// Admin-pushed wallpapers (backend.wallpapers — {url,title} objects with
  /// legacy strings/single-field folded in), downloaded once per changed
  /// list into dedicated admin files. Titles come from the panel; untitled
  /// entries get position-based names (Wallpaper 1/2/…) at parse time.
  List<({String url, String title})> _adminWallpapersRaw = const [];
  Future<String> get _adminWallpaperDir async =>
      (await getApplicationDocumentsDirectory()).path;
  // Numeric versions from the version.json payload (real update gating).
  int _latestVersionCode = 0;
  int _minRequiredVersionCode = 0;

  /// The INSTALLED code/name at runtime. Split APKs report 591/592 (not the
  /// compile-time 59), so these are primed from `VpnService.fetchInstallInfo()`
  /// during startup and fall back to the compile-time constants until then.
  int _installedVersionCode = kAppBuildNumber;
  String _installedVersionName = kAppVersion;

  /// Pre-warm the runtime build facts (called once at startup); the update
  /// gate in [updateRequiredByCode] then compares against the real installed
  /// version code instead of the compile-time constant.
  Future<void> primeInstallInfo() async {
    final info = await VpnService.fetchInstallInfo();
    if (info == null) return;
    if (info.versionCode > 0) _installedVersionCode = info.versionCode;
    if (info.versionName.isNotEmpty) _installedVersionName = info.versionName;
  }

  List<ServerConfig> get servers => _servers;
  // All configs pushed from the admin feed (isCustom == false), regardless of
  // the per-node `isOfficial` flag — a node published without "Official"
  // checked must still appear in the app's category sections.
  List<ServerConfig> get officialServers =>
      _servers.where((s) => !s.isCustom).toList();
  List<ServerConfig> get customServers =>
      _servers.where((s) => s.isCustom).toList();

  /// All UNLOCKED custom configs as one multi-section `.st` text (each
  /// section = the app's key=value share format, `###`-separated). Locked
  /// configs stay out of plain-text exports — their fields must not leak.
  /// Empty string when there is nothing to export.
  String stExportText() {
    final customs = _servers.where((s) => s.isCustom && !s.locked).toList();
    if (customs.isEmpty) return '';
    return customs.map((s) => s.toHttpCustomText()).join('\n');
  }

  /// How many custom configs are locked (kept out of [stExportText]).
  int get lockedCustomCount =>
      _servers.where((s) => s.isCustom && s.locked).length;

  /// Categories published by the panel (settings bundle). When the panel has
  /// none (legacy state), they are derived from the feed's own category
  /// values in first-seen order so grouping still works.
  /// Capability types from the settings bundle (cached in prefs).
  List<String> get capabilityTypes =>
      List.unmodifiable(_capabilityTypes.map((t) => t.name));
  List<AppCapabilityType> get capabilityTypeDetails =>
      List.unmodifiable(_capabilityTypes);
  String capabilityDescription(String name) {
    final key = name.trim().toUpperCase();
    for (final t in _capabilityTypes) {
      if (t.name == key) return t.description;
    }
    return '';
  }

  List<AppCategory> get displayCategories {
    if (_categories.isNotEmpty) return _categories;
    final seen = <String>{};
    final out = <AppCategory>[];
    for (final s in _servers) {
      final name = s.category.isEmpty ? 'global' : s.category;
      if (seen.add(name)) out.add(AppCategory(name: name, country: ''));
    }
    return out;
  }

  ServerConfig? get selectedServer => _selectedServer;
  bool get isLoading => _isLoading;
  String get error => _error;

  /// Bumped after every SUCCESSFUL manual config refresh. The logo cache is
  /// keyed only by URL, so a logo the admin replaces without changing its
  /// imgbb URL would otherwise stay frozen at the first download forever —
  /// restarting the app still shows the old image. `SenseiCachedImage`
  /// watches this and re-downloads its current URL once per manual refresh.
  int _logoCacheEpoch = 0;
  int get logoCacheEpoch => _logoCacheEpoch;
  bool get appLocked => _appLocked;
  String get lockedMessage => _lockedMessage;
  bool get forceUpdate => _forceUpdate;
  String get latestVersion => _latestVersion;
  String get updateUrl => _updateUrl;
  String get updateMessage => _updateMessage;

  /// Show-once key of the current broadcast (its updatedAt). Empty = none.
  String get broadcastKey => _broadcastKey;
  bool get broadcastShowDialog => _broadcastShowDialog;
  String get broadcastTitle => _broadcastTitle;
  String get broadcastMessage => _broadcastMessage;
  bool get broadcastHasAction =>
      _broadcastActionText.isNotEmpty && _broadcastActionUrl.isNotEmpty;
  String get broadcastActionText => _broadcastActionText;
  String get broadcastActionUrl => _broadcastActionUrl;
  bool get broadcastMarquee => _broadcastMarquee;
  String get broadcastMarqueeText => _broadcastMarqueeText;
  bool get maintenanceMode => _maintenanceMode;
  String get maintenanceMessage => _maintenanceMessage;

  /// Provider branding published by the panel (backend.name/contact/whatsapp/description).
  /// Empty strings when the admin has not set them.
  String get providerName => _providerName;
  String get providerContact => _providerContact;
  String get providerWhatsapp => _providerWhatsapp;
  String get providerDescription => _providerDescription;

  /// Download one admin wallpaper into its dedicated admin file. Uses the
  /// same tunnel-aware HTTP client as the config feed. Best-effort: a failed
  /// download keeps the rest of the gallery.
  Future<void> _downloadAdminWallpaper(String url, int index) async {
    try {
      final res = await TunnelHttpClient.get(
        Uri.parse(url),
        timeout: const Duration(seconds: 20),
      );
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return;
      // Writes to SEPARATE admin files — the user's own wallpaper choice is
      // never clobbered by a feed refresh. The wallpaper sheet offers the
      // whole gallery as the "Admin" source; one only becomes the background
      // when the user has not picked one of their own.
      final dir = await _adminWallpaperDir;
      final file = File('$dir/sensei_wallpaper_admin_$index.png');
      await file.writeAsBytes(res.bodyBytes, flush: true);
    } catch (_) {
      // Network/DNS failure — keep whatever wallpapers are already applied.
    }
  }

  /// Downloaded admin wallpapers with their titles, in feed order. Empty
  /// when none were published (or downloaded) yet. Persisted entry metadata
  /// means the gallery + titles survive offline after the first fetch.
  Future<List<AdminWallpaper>> adminWallpapers() async {
    final dir = await _adminWallpaperDir;
    final out = <AdminWallpaper>[];
    for (var i = 0; i < _adminWallpapersRaw.length; i++) {
      final f = File('$dir/sensei_wallpaper_admin_$i.png');
      if (await f.exists()) {
        out.add(AdminWallpaper(
          path: f.path,
          title: _adminWallpapersRaw[i].title,
        ));
      }
    }
    return out;
  }

  /// True when the running build is actually older than what the panel
  /// requires. `forceUpdate=true` alone is not enough: an old panel payload can
  /// otherwise keep blocking the already-updated app.
  ///
  /// IMPORTANT: split-ABI APKs report the REAL installed code (591/592 for the
  /// *10+1/2 scheme), not the compile-time `kAppBuildNumber` (59). The gate
  /// compares against `_installedVersionCode`, primed from the platform channel
  /// during startup (falls back to the compile-time constant until then).
  bool get updateRequiredByCode {
    if (_minRequiredVersionCode > _installedVersionCode) return true;
    if (!_forceUpdate) return false;
    if (_latestVersionCode > 0) return _latestVersionCode > _installedVersionCode;
    if (_latestVersion.trim().isEmpty) return true; // legacy force-only feed
    return _compareVersionNames(_latestVersion, _installedVersionName) > 0;
  }

  static int _compareVersionNames(String a, String b) {
    final left = a.split(RegExp(r'[^0-9]+')).where((s) => s.isNotEmpty).toList();
    final right = b.split(RegExp(r'[^0-9]+')).where((s) => s.isNotEmpty).toList();
    final n = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < n; i++) {
      final x = i < left.length ? int.tryParse(left[i]) ?? 0 : 0;
      final y = i < right.length ? int.tryParse(right[i]) ?? 0 : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// True when a newer build exists but is NOT admin-forced — a soft
  /// "update available" notice (home + About), never a blocker. The forced
  /// path ([updateRequiredByCode]) owns the hard gate; this must stay false
  /// there so the same update never shows twice as different UI.
  bool get updateAvailableSoft {
    if (updateRequiredByCode) return false;
    if (_updateUrl.isEmpty) return false;
    if (_latestVersionCode > 0) {
      return _latestVersionCode > _installedVersionCode;
    }
    if (_latestVersion.trim().isEmpty) return false;
    return _compareVersionNames(_latestVersion, _installedVersionName) > 0;
  }

  /// The saved subscription URL (per-user). Empty if none configured.
  String get subscriptionUrl => _subscriptionUrl;

  /// Parsed usage/expiry from the last subscription fetch, or null. Keys:
  /// usedGB, totalGB, remainingGB, percent, daysLeft, expired, unlimited, expire.
  Map<String, dynamic>? get subscriptionUsage => _subscriptionUsage;

  ConfigService() {
    loadServers();
  }

  /// Load servers from local storage + fetch official from admin.
  /// [manual] marks a user-initiated refresh (button / pull-to-refresh) — it
  /// gets the CDN-staleness cross-check; the automatic refresh on app open
  /// stays a single attempt per spec.
  Future<void> loadServers({bool manual = false}) async {
    _isLoading = true;
    _error = '';
    lastRefreshFailed = false;
    notifyListeners();

    // Hard gate: without the official signing cert, load NOTHING — not even
    // locally cached configs. A re-signed clone must not see any config.
    if (!await VpnService.verifyIntegrity()) {
      _servers = [];
      _isLoading = false;
      _error = 'integrity-failed';
      notifyListeners();
      return;
    }

    try {
      // Load from local storage first
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_storageKey);
      if (stored != null) {
        // Cache is written encrypted (`sek1:` = AndroidKeyStore AES-256-GCM);
        // accept legacy plaintext JSON so existing installs migrate in place
        // on the next save. An unreadable encrypted cache (Keystore rotated /
        // device-owner wipe) is dropped — the fetch below refills it.
        var raw = stored;
        if (raw.startsWith('sek1:')) {
          raw = await VpnService.decryptCache(raw) ?? '';
        }
        if (raw.isNotEmpty) {
          final List<dynamic> jsonList = jsonDecode(raw);
          _servers = jsonList.map((j) => ServerConfig.fromJson(j)).toList();
        }
      }
      final selectedId = prefs.getString(_selectedStorageKey);
      _subscriptionUrl = prefs.getString(_subUrlKey) ?? '';
      _loadCategoriesFromPrefs(prefs.getString(_categoriesKey));
      _loadCapabilityTypesFromPrefs(
        prefs.getString(_typeMetaKey),
        prefs.getStringList(_typesKey),
      );
      // Admin wallpaper gallery metadata (titles) — the image files persist
      // separately, so the sheet's gallery + titles work before the fetch.
      final storedGallery = prefs.getString(_adminWallpapersKey);
      if (storedGallery != null && _adminWallpapersRaw.isEmpty) {
        try {
          final list = jsonDecode(storedGallery) as List<dynamic>;
          _adminWallpapersRaw = [
            for (final w in list.whereType<Map>())
              if ((w['url'] ?? '').toString().trim().isNotEmpty)
                (
                  url: (w['url'] ?? '').toString().trim(),
                  title: (w['title'] ?? '').toString().trim(),
                ),
          ];
        } catch (_) {/* corrupt cache — the fetch refills it */}
      }

      // Restore the selection from the CACHED list immediately — the fetches
      // below take seconds (and right after a kill-from-recents the tunnel
      // is still reconnecting), during which the home screen used to show
      // "No tunnel selected" even though the pick was saved. The post-fetch
      // restore re-runs against the fresh list and keeps everything honest.
      if (_servers.isNotEmpty) {
        _restoreSelectedServer(selectedId);
      }

      // MANUAL-ONLY feed (user decision: no auto-update, ever). The automatic
      // path fetches ONLY when the local cache is empty (fresh install /
      // cleared data — without it the app would open blank forever); every
      // other open shows the cached feed and waits for the user's explicit
      // refresh (pull-to-refresh / drawer "Reload Configs").
      final autoAllowed = _servers.isEmpty;
      if (manual || autoAllowed) {
        lastRefreshFailed = !await fetchEncryptedGithubConfigs(manual: manual);
        if (lastRefreshFailed && manual) {
          // GitHub/CDN down entirely: the Worker's live fallback bundle is the
          // remaining source — a manual refresh should always try it.
          await _refreshStaleCdn(-1);
        }
        // A manual refresh that actually fetched something is the signal that
        // the panel re-published — bump the epoch so visible SenseiCachedImages
        // re-download even when a logo URL did not change.
        if (manual && !lastRefreshFailed) _logoCacheEpoch++;
      } else {
        lastRefreshFailed = false;
      }
      await fetchAppSettings();

      // Refresh the user's subscription ONCE here (loadServers runs once on
      // entry). Imports its servers + reads usage/expiry. Never polled — kept to
      // a single hit per app entry / manual refresh to spare the sub server.
      if (_subscriptionUrl.isNotEmpty) {
        await refreshSubscription(_subscriptionUrl);
      }
      _restoreSelectedServer(selectedId);

      // An empty list is an honest empty state — the old fake "SG Server 1 /
      // demo-uuid" placeholders only produced confusing connect failures.
    } catch (e) {
      _error = 'Failed to load servers: $e';
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> fetchEncryptedGithubConfigs({bool manual = false}) async {
    try {
      if (!await VpnService.verifyIntegrity()) return false;
      // Cache-buster: the configs CDN (custom domain) may serve a stale copy
      // after an admin publish; varying the query string forces a fresh edge
      // fetch so panel changes show up on the next app refresh.
      final bust = DateTime.now().millisecondsSinceEpoch;
      final response = await TunnelHttpClient.get(
        Uri.parse('$_githubConfigUrl?cb=$bust'),
      );
      if (response.statusCode != 200) return false;

      final body = response.body.trim();
      // Prefer native decryption (handles v3 signature-bound + v2 AES-GCM);
      // fall back to the local v1 XOR path for older config bundles.
      String jsonText =
          await VpnService.decryptConfig(body) ?? _decryptGithubConfig(body);
      final List<dynamic> configs = jsonDecode(jsonText);
      final officialConfigs = configs
          .where((c) => c is Map && c['active'] != false)
          .map((c) => _serverFromAdminJson(c as Map<String, dynamic>))
          .where((s) => s.address.isNotEmpty && s.port > 0 || s.vault != null)
          .toList();
      if (officialConfigs.isEmpty) return false;

      _replaceOfficialServers(officialConfigs);
      await _saveServers();
      // The GitHub raw CDN can serve a minutes-old file right after a panel
      // publish (its cache is keyed by path, so the ?cb= buster only busts the
      // edge). On MANUAL refreshes cross-check the live count the panel
      // reports and, when short, pull the always-fresh encrypted bundle
      // straight from the Worker.
      if (manual) await _refreshStaleCdn(officialConfigs.length);
      return true;
    } catch (e) {
      debugPrint('Failed to fetch GitHub configs: $e');
      return false;
    }
  }

  /// Detect a stale CDN copy (fetched fewer configs than the panel says are
  /// live) and replace it with the Worker's live bundle via its public
  /// fallback URL. Best-effort — any failure just keeps the fetched copy.
  Future<void> _refreshStaleCdn(int fetchedCount) async {
    try {
      final r = await TunnelHttpClient.get(
        Uri.parse('${Obf.adminUrl}/api/backend'),
        timeout: const Duration(seconds: 8),
      );
      if (r.statusCode != 200) return;
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      final src = (d['configSource'] ?? {}) as Map<String, dynamic>;
      final published = (src['activeConfigs'] as num?)?.toInt() ?? 0;
      if (published <= fetchedCount) return;
      final fallback = src['fallbackUrl']?.toString() ?? '';
      if (fallback.isEmpty) return;

      final resp = await TunnelHttpClient.get(
        Uri.parse('$fallback?cb=${DateTime.now().millisecondsSinceEpoch}'),
        timeout: const Duration(seconds: 12),
      );
      if (resp.statusCode != 200) return;
      final body = resp.body.trim();
      final jsonText =
          await VpnService.decryptConfig(body) ?? _decryptGithubConfig(body);
      final List<dynamic> configs = jsonDecode(jsonText);
      final fresh = configs
          .where((c) => c is Map && c['active'] != false)
          .map((c) => _serverFromAdminJson(c as Map<String, dynamic>))
          .where((s) => s.address.isNotEmpty && s.port > 0 || s.vault != null)
          .toList();
      if (fresh.length > fetchedCount) {
        _replaceOfficialServers(fresh);
        await _saveServers();
        debugPrint(
            'Config CDN was stale ($fetchedCount/$published) — used the live Worker bundle (${fresh.length})');
      }
    } catch (e) {
      debugPrint('Config freshness check skipped: $e');
    }
  }

  String _decryptGithubConfig(String encrypted) {
    final payload = encrypted.startsWith('sensei:v1:')
        ? encrypted.substring('sensei:v1:'.length)
        : encrypted;
    final data = base64Decode(payload);
    final key = utf8.encode(_githubConfigKey);
    final output = List<int>.generate(
      data.length,
      (index) => data[index] ^ key[index % key.length],
    );
    return utf8.decode(output);
  }

  Future<void> fetchAppSettings() async {
    var bundleOk = false;
    try {
      if (!await VpnService.verifyIntegrity()) return;
      final bust = DateTime.now().millisecondsSinceEpoch;
      final response = await TunnelHttpClient.get(
        Uri.parse('$_githubSettingsUrl?cb=$bust'),
      );

      if (response.statusCode == 200) {
        final body = response.body.trim();
        final jsonText =
            await VpnService.decryptConfig(body) ?? _decryptGithubConfig(body);
        final data = jsonDecode(jsonText) as Map<String, dynamic>;
        bundleOk = true;
        final settings = (data['settings'] ?? data) as Map<String, dynamic>;
        _appLocked = settings['appLocked'] == true;
        _lockedMessage = settings['lockedMessage'] ?? 'App is locked by admin.';
        _forceUpdate = settings['forceUpdate'] == true;
        _latestVersion = settings['latestVersion'] ?? '';
        _updateUrl = settings['updateUrl'] ?? '';
        _updateMessage = settings['updateMessage'] ?? 'New update available.';

        // Broadcast payload (backend.info, with legacy top-level `info`).
        final backend = (data['backend'] ?? {}) as Map<dynamic, dynamic>;

        // Provider branding (shown in About / Support).
        _providerName = backend['name']?.toString() ?? '';
        _providerContact = backend['contact']?.toString() ?? '';
        _providerWhatsapp = backend['whatsapp']?.toString() ?? '';
        _providerDescription = backend['description']?.toString() ?? '';
        // Admin wallpaper gallery (backend.wallpapers — {url,title} entries,
        // legacy plain strings and the single backend.wallpaper folded in).
        // New/changed entries are downloaded so the Wallpaper sheet's
        // "Admin" source can offer them — but nothing is ever AUTO-APPLIED:
        // the background changes only when the user picks one themselves.
        // Untitled entries get position-based names (Wallpaper 1/2/…).
        await _syncAdminWallpapers(
          parseWallpaperEntries(backend['wallpapers'],
              legacySingle: backend['wallpaper']?.toString()),
        );

        final info =
            ((backend['info'] ?? data['info']) ?? {}) as Map<dynamic, dynamic>;
        if (info.isNotEmpty) {
          _broadcastKey =
              (info['updatedAt'] ?? backend['updatedAt'] ?? '').toString();
          _broadcastShowDialog = info['showDialog'] == true &&
              (info['dialogMessage'] ?? '').toString().isNotEmpty;
          _broadcastTitle = info['dialogTitle']?.toString() ?? '';
          _broadcastMessage = info['dialogMessage']?.toString() ?? '';
          _broadcastActionText = info['actionButtonText']?.toString() ?? '';
          _broadcastActionUrl = info['actionButtonUrl']?.toString() ?? '';
          _broadcastMarquee = info['showMarquee'] == true &&
              (info['marqueeNotice'] ?? '').toString().isNotEmpty;
          _broadcastMarqueeText = info['marqueeNotice']?.toString() ?? '';
          _maintenanceMode = info['maintenanceMode'] == true;
          _maintenanceMessage = info['maintenanceMessage']?.toString() ?? '';
        } else {
          _broadcastShowDialog = false;
          _broadcastMarquee = false;
          _maintenanceMode = false;
        }

        // version.json payload → numeric update gating.
        final vers = (data['version'] ?? data['vers'] ?? settings['vers'])
            as Map<dynamic, dynamic>?;
        if (vers != null) {
          _latestVersionCode =
              int.tryParse(vers['versionCode']?.toString() ?? '') ?? 0;
          _minRequiredVersionCode =
              int.tryParse(vers['minRequiredVersionCode']?.toString() ?? '') ??
                  0;
          if (_latestVersion.isEmpty && vers['versionName'] != null) {
            _latestVersion = vers['versionName'].toString();
          }
          if (_updateUrl.isEmpty && vers['apkDownloadUrl'] != null) {
            _updateUrl = vers['apkDownloadUrl'].toString();
          }
        }

        // Tweak categories — one section per category in the Configs menu.
        // Creating/removing a category in the panel updates this list, so the
        // app's sections follow the panel on the next open/refresh.
        final rawCats = data['categories'];
        if (rawCats is List) {
          final cats = <AppCategory>[];
          for (final c in rawCats) {
            if (c is Map) {
              final cat = AppCategory.fromJson(Map<String, dynamic>.from(c));
              if (cat.name.isNotEmpty) cats.add(cat);
            }
          }
          _categories = cats;
          await _saveCategories();
        }

        // Capability types from the panel — the Server↔Tweak compatibility
        // markers. The Custom Tweak picker offers these; a user tweak rides
        // any OFFICIAL server whose capabilities include the chosen type.
        final rawTypes = data['types'];
        if (rawTypes is List) {
          _capabilityTypes = rawTypes
              .map((t) => t is Map
                  ? AppCapabilityType.fromJson(Map<String, dynamic>.from(t))
                  : AppCapabilityType(name: t.toString().toUpperCase()))
              .where((t) => t.name.isNotEmpty)
              .toList();
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(
              _typesKey, List<String>.from(capabilityTypes));
          await prefs.setString(
            _typeMetaKey,
            jsonEncode(_capabilityTypes.map((t) => t.toJson()).toList()),
          );
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch app settings: $e');
    }
    // The v3 bundle is signature-bound to the release cert: debug builds and
    // any cert mismatch can't open it (the v1 XOR fallback throws on v3
    // payloads too). Branding + the wallpaper GALLERY are public by design on
    // /api/backend, so still fill those when the bundle path failed — this is
    // exactly the case that made "Admin" wallpapers look never-published.
    // The gated settings (lock/update/broadcast) never ride this path.
    if (!bundleOk) await _fetchPublicBackendFallback();
  }

  /// Parse a `backend.wallpapers` payload (objects, legacy plain strings) and
  /// fold the legacy single `backend.wallpaper` in. Untitled entries get
  /// position-based names (Wallpaper 1/2/…).
  @visibleForTesting
  static List<({String url, String title})> parseWallpaperEntries(
    dynamic raw, {
    String? legacySingle,
  }) {
    var entries = <({String url, String title})>[];
    if (raw is List) {
      for (final w in raw) {
        if (w is Map) {
          final url = (w['url'] ?? '').toString().trim();
          if (url.isEmpty || entries.any((e) => e.url == url)) continue;
          entries.add((
            url: url,
            title: (w['title'] ?? '').toString().trim(),
          ));
        } else {
          final url = (w ?? '').toString().trim();
          if (url.isEmpty || entries.any((e) => e.url == url)) continue;
          entries.add((url: url, title: ''));
        }
      }
    }
    final single = (legacySingle ?? '').trim();
    if (single.isNotEmpty && !entries.any((e) => e.url == single)) {
      entries.insert(0, (url: single, title: ''));
    }
    return [
      for (var i = 0; i < entries.length; i++)
        (
          url: entries[i].url,
          title:
              entries[i].title.isEmpty ? 'Wallpaper ${i + 1}' : entries[i].title,
        ),
    ];
  }

  /// Download new/changed gallery entries into the indexed admin files and
  /// persist the metadata. Nothing is ever auto-applied — the background
  /// changes only when the user picks an entry in the Wallpaper sheet.
  Future<void> _syncAdminWallpapers(
    List<({String url, String title})> entries,
  ) async {
    if (listEquals(entries, _adminWallpapersRaw)) {
      // Metadata unchanged — but an earlier download may have failed (proxy
      // hiccup while connected, app-cache wipe). Without this self-heal the
      // listEquals short-circuit would make the gallery stay permanently
      // half-empty: the titles persist, the files never arrive.
      await _redownloadMissingWallpapers(entries);
      return;
    }
    _adminWallpapersRaw = List.unmodifiable(entries);
    for (var i = 0; i < entries.length; i++) {
      await _downloadAdminWallpaper(entries[i].url, i);
    }
    // Persist the gallery metadata (titles) so the sheet works offline on
    // later launches — the image files already persist.
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _adminWallpapersKey,
      jsonEncode([
        for (final e in entries) {'url': e.url, 'title': e.title},
      ]),
    );
  }

  /// Re-fetch only the entries whose file is missing on disk. Cheap stat per
  /// entry; the download runs only when it actually has to.
  Future<void> _redownloadMissingWallpapers(
    List<({String url, String title})> entries,
  ) async {
    if (entries.isEmpty) return;
    final dir = await _adminWallpaperDir;
    for (var i = 0; i < entries.length; i++) {
      final f = File('$dir/sensei_wallpaper_admin_$i.png');
      var missing = !await f.exists();
      if (!missing) {
        try {
          missing = await f.length() == 0;
        } catch (_) {
          missing = true;
        }
      }
      if (missing) await _downloadAdminWallpaper(entries[i].url, i);
    }
  }

  /// Public branding/wallpaper fallback straight from the Worker.
  Future<void> _fetchPublicBackendFallback() async {
    try {
      final r = await TunnelHttpClient.get(
        Uri.parse('${Obf.adminUrl}/api/backend'),
        timeout: const Duration(seconds: 10),
      );
      if (r.statusCode != 200) return;
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      if (d['ok'] != true) return;
      final backend = (d['backend'] ?? {}) as Map<dynamic, dynamic>;
      if (_providerName.isEmpty) {
        _providerName = backend['name']?.toString() ?? '';
        _providerContact = backend['contact']?.toString() ?? '';
        _providerWhatsapp = backend['whatsapp']?.toString() ?? '';
        _providerDescription = backend['description']?.toString() ?? '';
      }
      await _syncAdminWallpapers(
        parseWallpaperEntries(backend['wallpapers'],
            legacySingle: backend['wallpaper']?.toString()),
      );
    } catch (e) {
      debugPrint('Public backend fallback skipped: $e');
    }
  }

  void _loadCategoriesFromPrefs(String? stored) {
    if (stored == null || stored.isEmpty) return;
    try {
      final list = jsonDecode(stored) as List<dynamic>;
      _categories = list
          .whereType<Map>()
          .map((m) => AppCategory.fromJson(Map<String, dynamic>.from(m)))
          .where((c) => c.name.isNotEmpty)
          .toList();
    } catch (_) {
      _categories = [];
    }
  }

  void _loadCapabilityTypesFromPrefs(String? stored, List<String>? legacy) {
    if (stored != null && stored.isNotEmpty) {
      try {
        final list = jsonDecode(stored) as List<dynamic>;
        _capabilityTypes = list
            .whereType<Map>()
            .map((m) => AppCapabilityType.fromJson(Map<String, dynamic>.from(m)))
            .where((t) => t.name.isNotEmpty)
            .toList();
        if (_capabilityTypes.isNotEmpty) return;
      } catch (_) {
        _capabilityTypes = [];
      }
    }
    _capabilityTypes = (legacy ?? const [])
        .where((n) => n.isNotEmpty)
        .map((n) => AppCapabilityType(name: n.toUpperCase()))
        .toList();
  }

  Future<void> _saveCategories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _categoriesKey,
        jsonEncode(_categories.map((c) => c.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('Failed to save categories: $e');
    }
  }

  static String? _familyOrNull(dynamic v) {
    final fam = (v ?? '').toString().trim().toLowerCase();
    return fam.isEmpty ? null : fam;
  }

  ServerConfig _serverFromAdminJson(Map<String, dynamic> c) {
    return ServerConfig(
      id: c['id'] ?? '',
      name: c['name'] ?? c['note'] ?? 'Official',
      // Only a REAL note — the old `?? c['name']` fallback put the server
      // name under every tweak card. Blank note = the card hides the line.
      note: c['note'] ?? '',
      protocol: ServerConfig.parseProtocol(c['protocol'] ?? 'vless'),
      transport: ServerConfig.parseTransport(c['transport'] ?? 'tcp'),
      security: ServerConfig.parseSecurity(c['security'] ?? 'none'),
      address: c['address'] ?? c['host'] ?? '',
      port: ServerConfig.parsePort(c['port'], 443),
      uuid: c['uuid'] ?? c['id'] ?? c['password'] ?? '',
      alterId: c['alterId']?.toString() ?? c['aid']?.toString(),
      password: c['password'] ?? c['pass'],
      encryption: c['encryption'] ?? c['method'],
      sni: c['sni'] ?? c['serverName'] ?? c['serverNameIndication'],
      path: c['path'] ?? c['wsPath'],
      host: c['host'] ??
          c['wsHost'] ??
          c['serverName'] ??
          c['serverNameIndication'],
      serviceName: c['serviceName'],
      fingerprint: c['fingerprint'],
      flow: c['flow'],
      publicKey: c['publicKey'],
      shortId: c['shortId'],
      isOfficial: c['isOfficial'] != false,
      logoBase64: c['logoBase64'],
      logoUrl: c['logoUrl'],
      capability: c['capability']?.toString().isNotEmpty == true
          ? c['capability'].toString()
          // The panel's Server entity carries capabilities[] (plural) — fold
          // its first marker into the singular field the app matches on.
          : (c['capabilities'] is List && (c['capabilities'] as List).isNotEmpty
              ? (c['capabilities'] as List).first.toString()
              : null),
      capabilities: c['capabilities'] is List
          ? (c['capabilities'] as List)
              .map((e) => e.toString().trim().toUpperCase())
              .where((e) => e.isNotEmpty)
              .toSet()
              .toList()
          : const [],
      serverPool: _parsePool(c['serverPool']),
      // Preferred anchor (panel's serverId) + declared riding family —
      // without these the app re-joins the tweak on its own and can pick a
      // different server than the panel joined, or drop 'mixed' pools.
      anchorId: c['serverId']?.toString(),
      tweakFamily: _familyOrNull(c['family']),
      payload: c['payload'] ?? c['ndkPayload'],
      sshUser: c['sshUser'] ?? c['user'] ?? c['username'],
      sshPass: c['sshPass'] ?? c['pass'] ?? c['password'],
      injectHost: c['injectHost'] ??
          c['proxyHost'] ??
          c['SquidProxy'] ??
          c['squidProxy'],
      injectPort: c['injectPort']?.toString() ??
          c['proxyPort']?.toString() ??
          c['SquidPort']?.toString() ??
          c['squidPort']?.toString(),
      injectPayload: c['injectPayload'],
      injectMode: ServerConfig.parseInjectMode(c['injectMode'] ?? c['mode']),
      dnsttServer: c['dnsttServer'] ?? c['dnsttServerName'],
      dnsttKey: c['dnsttKey'] ?? c['dnsttPublicKey'],
      dnsttResolver: c['dnsttResolver'] ?? c['dnsttUdpDnsHost'],
      ovpnConfig: c['ovpnConfig'] ?? c['ovpn'],
      wireguardConfig: c['wireguardConfig'],
      psiphonRegion: c['psiphonRegion'],
      // Raw category string — free-form names ("Normal Internet") must match
      // the categories list exactly; legacy enum values arrive lowercase.
      category: (c['category'] ?? 'global').toString(),
      // The REAL server this joined config rides (panel's join label) —
      // groups tweak variants of one host into one server everywhere.
      server: c['server']?.toString(),
      country: c['country'],
      region: c['region'],
      author: c['author'],
      encryptionKey: c['encryptionKey'],
      locked: c['locked'] == true,
      lockMessage: c['lockMessage'],
      expiresAt: ServerConfig.parseNullableInt(c['expiresAt']),
      vip: c['vip'] == true,
      vipUnlockHours: ServerConfig.parseNullableInt(c['vipUnlockHours']),
      vipNote: c['vipNote'] is String && (c['vipNote'] as String).trim().isNotEmpty
          ? (c['vipNote'] as String).trim()
          : null,
      vault: c['vault'] is String && (c['vault'] as String).trim().isNotEmpty
          ? (c['vault'] as String).trim()
          : null,
    );
  }

  /// Add a custom server config
  Future<void> addCustomServer(ServerConfig config) async {
    // Import dedup: same id or same endpoint+method already present → no
    // second copy (re-importing a share file or double-tapping import must
    // not create duplicates).
    final dup = _servers.any((s) =>
        s.isCustom &&
        (s.id == config.id ||
            (s.address == config.address &&
                s.port == config.port &&
                s.protocol == config.protocol &&
                ServerConfig.capabilityKey(s.capability ?? '') ==
                    ServerConfig.capabilityKey(config.capability ?? '') &&
                (s.payload ?? '') == (config.payload ?? '') &&
                (s.sni ?? '') == (config.sni ?? ''))));
    if (dup) return;
    _servers.add(config);
    await _saveServers();
    notifyListeners();
  }

  /// Update an existing custom server config
  Future<void> updateCustomServer(ServerConfig config) async {
    final idx = _servers.indexWhere((s) => s.id == config.id);
    if (idx >= 0) {
      _servers[idx] = config;
      if (_selectedServer?.id == config.id) {
        _selectedServer = config;
      }
      await _saveServers();
      notifyListeners();
    }
  }

  /// Official-backed custom configs must never persist or expose the official
  /// endpoint/credentials. Store only the user's visible tweak choice and join
  /// it with the live official feed in memory right before connecting.
  bool isOfficialTweak(ServerConfig config) {
    return _isOfficialTweakWith(config, officialServers);
  }

  bool _isOfficialTweakWith(
    ServerConfig config,
    List<ServerConfig> official,
  ) {
    if (!config.isCustom || config.isOfficial) return false;
    final type = ServerConfig.capabilityKey(config.capability ?? '');
    if (type.isEmpty) return false;
    if (config.rawConfig == 'official:tweak') return true;
    final compatible = tweakPoolFor(
      official,
      capability: type,
      protocol: config.protocol,
      anchorId: config.anchorId,
      family: config.tweakFamily,
    );
    if (compatible.isEmpty) return false;
    if (config.serverPool.isNotEmpty) return true;
    return compatible.any((s) =>
        s.address == config.address &&
        s.port == config.port &&
        s.protocol == config.protocol);
  }

  /// The Server↔Tweak join — app mirror of `compatibleServersFor` in
  /// admin-panel/src/config-schema.js. A tweak rides an official config when
  ///   · the capability markers match (canonical key), AND
  ///   · they share a protocol family (an SSH payload can't ride a vless host),
  ///     unless the tweak's [family] is 'mixed'/'*' — then every family is a
  ///     compatible pool (panel's cross-engine tweak).
  /// The tweak's saved [anchorId] (preferred anchor) is moved to the front
  /// when still compatible; feed order (panel priority) decides otherwise.
  static List<ServerConfig> tweakPoolFor(
    List<ServerConfig> official, {
    required String? capability,
    required ProtocolType protocol,
    String? anchorId,
    String? family,
  }) {
    final key = ServerConfig.capabilityKey(capability ?? '');
    if (key.isEmpty) return const [];
    final fam = (family ?? '').trim().toLowerCase();
    final crossFamily = fam == 'mixed' || fam == '*';
    final want = crossFamily ? null : (fam.isNotEmpty ? fam : ServerConfig.familyOf(protocol));
    final match = official
        .where((s) =>
            s.supportsCapability(key) &&
            (want == null || ServerConfig.familyOf(s.protocol) == want))
        .toList();
    if (anchorId == null || anchorId.isEmpty || match.isEmpty) return match;
    final anchor = match.firstWhere(
      (s) => s.id == anchorId,
      orElse: () => match.first,
    );
    if (identical(anchor, match.first)) return match;
    return [anchor, ...match.where((s) => !identical(s, anchor))];
  }

  /// Resolve a vaulted VIP config's real endpoint from the Worker.
  ///
  /// Vaulted VIP configs publish with `address:''`/`port:0` and a `vault` id;
  /// the real endpoint is fetched here, at connect time, presenting the native
  /// unlock [ticket] that the Worker re-verifies. The response is the normal
  /// encrypted bundle, decrypted with the same native key as configs. Returns
  /// [config] with the endpoint filled in, or null when the fetch, ticket, or
  /// decrypt fails (caller surfaces "needs internet" or re-gates).
  ///
  /// While the ads gate is OFF ([AdConfig.adsEnabled] — pre-Play-Store), the
  /// ticket is sent only when one exists: the Worker allows ticket-less
  /// resolves then, so BDIX/VIP servers connect + ping without a watched ad.
  Future<ServerConfig?> resolveVipEndpoint(
    ServerConfig config, {
    required String? ticket,
  }) async {
    final vault = config.vault;
    if (vault == null || vault.isEmpty) return config;
    if (ticket == null || ticket.isEmpty) {
      if (!AdConfig.adsEnabled) {
        // Ads gate open — the Worker resolves without a ticket.
        return _resolveVipNoTicket(config, vault);
      }
      if (DeviceTrial.instance.isVipDevice) {
        // Admin-granted VIP device — the Worker trusts the panel's device
        // record (vip && not banned) and releases the endpoint without an ad.
        final dev = await DeviceTrial.instance.ensureDeviceId();
        if (dev != null) {
          return _resolveVipQuery(config, 'id=${Uri.encodeQueryComponent(vault)}'
              '&device=${Uri.encodeQueryComponent(dev)}');
        }
      }
      return null;
    }
    return _resolveVipQuery(config, 'id=${Uri.encodeQueryComponent(vault)}'
        '&ticket=${Uri.encodeQueryComponent(ticket)}');
  }

  /// Shared resolve transport: the ticketed, ticket-less and vip-device paths
  /// all receive the SAME encrypted envelope — only the query differs.
  Future<ServerConfig?> _resolveVipQuery(
      ServerConfig config, String query) async {
    try {
      final uri = Uri.parse('${Obf.adminUrl}/api/vip/resolve?$query');
      final r = await TunnelHttpClient.get(uri, timeout: const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final jsonText = await VpnService.decryptConfig(r.body.trim());
      if (jsonText == null || jsonText.isEmpty) return null;
      final e = jsonDecode(jsonText) as Map<String, dynamic>;
      return _applyResolvedEndpoint(config, e);
    } catch (e) {
      debugPrint('VIP endpoint resolve failed for ${config.vault}: $e');
      return null;
    }
  }

  /// Ticket-less resolve (ads gate open). Same envelope + decrypt as the
  /// ticketed path — only the query string differs.
  Future<ServerConfig?> _resolveVipNoTicket(
      ServerConfig config, String vault) async {
    return _resolveVipQuery(
        config, 'id=${Uri.encodeQueryComponent(vault)}');
  }

  /// Merge the resolve payload's endpoint fields into [config]. Blank payload
  /// fields keep the config's own values.
  ServerConfig _applyResolvedEndpoint(ServerConfig config, Map<String, dynamic> e) {
    final address = (e['address'] ?? '').toString().trim();
    final port = ServerConfig.parsePort(e['port'], 0);
    if (address.isEmpty || port <= 0) return config;
    return config.copyWith(
        address: address,
        port: port,
        sni: e['sni'] is String && (e['sni'] as String).isNotEmpty ? e['sni'] as String : config.sni,
        host: e['host'] is String && (e['host'] as String).isNotEmpty ? e['host'] as String : config.host,
        path: e['path'] is String && (e['path'] as String).isNotEmpty ? e['path'] as String : config.path,
        injectHost: e['injectHost'] is String && (e['injectHost'] as String).isNotEmpty
            ? e['injectHost'] as String
            : config.injectHost,
        injectPort: e['injectPort'] != null && '${e['injectPort']}'.trim().isNotEmpty
            ? '${e['injectPort']}'.trim()
            : config.injectPort,
        // The published bundle strips the failover pool too (each entry carries
        // its own address/port), so restore it here or a vaulted tweak silently
        // loses anchor failover after resolution.
        serverPool: e['serverPool'] is List
            ? (e['serverPool'] as List)
                .whereType<Map>()
                .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
                .toList()
            : config.serverPool,
      );
  }

  static ServerConfig officialTweakPlaceholder(ServerConfig config) {
    final type = ServerConfig.capabilityKey(config.capability ?? '');
    return ServerConfig(
      id: config.id,
      name: config.name,
      // Keep the note as-is — an empty note must stay empty (the card hides
      // the line), never fall back to the server name.
      note: config.note,
      // The tweak's own identity carries the RIDING family (the anchor's
      // protocol/transport chosen in the form) — never a hardcoded VLESS/TCP,
      // or the card and the family join both lie about what it rides.
      protocol: config.protocol,
      transport: config.transport,
      security: config.security,
      address: '',
      port: 443,
      uuid: '',
      isCustom: true,
      isOfficial: false,
      capability: type,
      anchorId: config.anchorId,
      tweakFamily: config.tweakFamily,
      rawConfig: 'official:tweak',
      sni: config.sni,
      payload: config.payload,
      injectHost: config.injectHost,
      injectPort: config.injectPort,
      injectPayload: config.injectPayload,
      injectMode: config.injectMode,
      payloadEnhanced: config.payloadEnhanced,
      author: config.author,
      locked: config.locked,
      lockMessage: config.lockMessage,
      expiresAt: config.expiresAt,
    );
  }

  ServerConfig resolveOfficialTweak(ServerConfig config) {
    if (!isOfficialTweak(config)) return config;
    final pool = tweakPoolFor(
      officialServers,
      capability: config.capability,
      protocol: config.protocol,
      anchorId: config.anchorId,
      family: config.tweakFamily,
    );
    if (pool.isEmpty) return config;
    final anchor = pool.first;
    return anchor.copyWith(
      id: config.id,
      name: config.name,
      // Keep the note as-is — never fall back to the server name.
      note: config.note,
      capability: ServerConfig.capabilityKey(config.capability ?? ''),
      anchorId: anchor.id,
      // Keep the tweak's riding family — re-resolution and the failover pool
      // must stay cross-family for 'mixed' tweaks.
      tweakFamily: config.tweakFamily,
      isCustom: true,
      isOfficial: false,
      rawConfig: 'official:tweak',
      sni: config.sni,
      payload: config.payload,
      injectHost: config.injectHost,
      injectPort: config.injectPort,
      injectPayload: config.injectPayload,
      injectMode: config.injectMode,
      payloadEnhanced: config.payloadEnhanced,
      serverPool: pool.skip(1).map(_officialPoolEntry).toList(),
    );
  }

  static Map<String, dynamic> _officialPoolEntry(ServerConfig s) => {
        'id': s.id,
        'name': s.name,
        'protocol': s.protocol.name,
        'address': s.address,
        'port': s.port,
        'transport': s.transport.name,
        'security': s.security.name,
        'uuid': s.uuid,
        'password': s.password ?? '',
        'encryption': s.encryption ?? '',
        'alterId': s.alterId ?? '',
        'host': s.host ?? '',
        'path': s.path ?? '',
        'serviceName': s.serviceName ?? '',
        'fingerprint': s.fingerprint ?? '',
        'flow': s.flow ?? '',
        'publicKey': s.publicKey ?? '',
        'shortId': s.shortId ?? '',
        'sshUser': s.sshUser ?? '',
        'sshPass': s.sshPass ?? '',
        'sshCompression': s.sshCompression,
        'dnsttServer': s.dnsttServer ?? '',
        'dnsttKey': s.dnsttKey ?? '',
        'dnsttResolver': s.dnsttResolver ?? '',
        'ovpnConfig': s.ovpnConfig ?? '',
      };

  /// Remove a server config
  Future<void> removeServer(String id) async {
    _servers.removeWhere((s) => s.id == id);
    if (_selectedServer?.id == id) {
      _selectedServer = null;
      _saveSelectedServer(null);
    }
    await _saveServers();
    notifyListeners();
  }

  static List<Map<String, dynamic>> _parsePool(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  /// Import config from darktunnel:// URI. A password-locked DarkTunnel
  /// share throws [LockPinRequired] when no [lockPin] was given so the UI
  /// can ask for it — same flow as the app's own v2p/v48 envelopes.
  Future<ServerConfig?> importFromUri(String uri, {String? lockPin}) async {
    if (!await VpnService.verifyIntegrity()) return null;
    if (uri.trim().startsWith('darktunnel://') &&
        DarkTunnelCodec.requiresPassword(uri) &&
        (lockPin == null || lockPin.trim().isEmpty)) {
      throw const LockPinRequired();
    }
    final config = ServerConfig.fromDarkTunnelUri(uri, lockPin: lockPin);
    if (config != null) {
      await addCustomServer(config);
    }
    return config;
  }

  /// THE config-text importer — every entry point (paste box, file picker,
  /// Android share intent, deep link) goes through this one parser. Accepts,
  /// in order:
  ///   · `armantunnel://` links (one config or a whole array)
  ///   · `darktunnel://` URIs
  ///   · `vless:// vmess:// trojan:// ss://` share links
  ///   · `.ovpn` profile bodies
  ///   · raw JSON (single object or array)
  ///   · multi-section `.st` files (`###`-separated key=value blocks)
  ///   · single key=value share text
  ///   · locked envelopes (`sensei:v2:` / PIN-locked `sensei:v2p:`)
  /// [lockPin] unlocks a user-locked share — the UI prompts for it when
  /// [isPinLockedText] says the text needs one.
  Future<ImportResult> importFromText(String text, {String? lockPin}) async {
    lockPin = lockPin?.trim();
    text = text.trim();

    /// One config imported → the standard result.
    ImportResult one(ServerConfig? c) => (count: c == null ? 0 : 1, last: c);

    if (!await VpnService.verifyIntegrity()) return (count: 0, last: null);

    // v48 share envelope(s). Public exports are now opaque
    // `armantunnel://<base64>` wrappers, but legacy `/base64/48/...` links
    // still import. A .st export carries one share per line.
    final v48Lines = _senseiEnvelopeLines(text);
    if (v48Lines.isNotEmpty) {
      final lines = v48Lines;
      if (lines.isEmpty) return (count: 0, last: null);
      if (lines.length == 1) {
        final envelope =
            VpnService.unwrapShareEnvelope(lines.first) ?? lines.first;
        var res =
            await VpnService.shareEnvelopeOpen(envelope, password: lockPin);
        if (res['needsPassword'] == true &&
            (lockPin == null || lockPin.isEmpty)) {
          throw const LockPinRequired();
        }
        if (res['ok'] != true) {
          logImportError('share',
              res['error'] ?? 'envelope open rejected the share');
          return (count: 0, last: null); // wrong PIN / device / restriction
        }
        final json = res['config'] as String?;
        if (json == null || json.isEmpty) return (count: 0, last: null);
        // The opened JSON may be a single config or an array — reuse the
        // JSON branch by recursing without the envelope prefix.
        return importFromText(json, lockPin: lockPin);
      }
      // Bulk: import every share line. A PIN-gated line rethrows
      // LockPinRequired so the UI asks once and retries the whole text.
      var imported = 0;
      ServerConfig? last;
      for (final line in lines) {
        final r = await importFromText(line, lockPin: lockPin);
        imported += r.count;
        last = r.last ?? last;
      }
      return (count: imported, last: last);
    }

    if (text.startsWith('armantunnel://')) {
      // Native backup format: `armantunnel://<base64url(json of one config or
      // an array)>`. Opaque v48 shares were handled above.
      late final String json;
      try {
        final payload = text.substring('armantunnel://'.length).trim();
        final normalized = payload.replaceAll('-', '+').replaceAll('_', '/');
        final padded = normalized + '=' * ((4 - normalized.length % 4) % 4);
        json = utf8.decode(base64.decode(padded));
      } catch (_) {
        return (count: 0, last: null);
      }
      return importFromText(json, lockPin: lockPin);
    }
    if (text.startsWith('darktunnel://')) {
      // Bulk pastes (`darktunnel://A,darktunnel://B` or one per line) used to
      // fail entirely — the comma made the base64 decode throw, so EVERY type
      // reported as unsupported. Import each URI found in the text.
      final uris = DarkTunnelCodec.extractUris(text);
      if (uris.length > 1) {
        var imported = 0;
        ServerConfig? last;
        for (final u in uris) {
          final c = await importFromUri(u, lockPin: lockPin);
          if (c != null) {
            imported++;
            last = c;
          }
        }
        return (count: imported, last: last);
      }
      return one(await importFromUri(uris.isEmpty ? text : uris.first,
          lockPin: lockPin));
    }
    if (text.startsWith('vless://') ||
        text.startsWith('vmess://') ||
        text.startsWith('trojan://') ||
        text.startsWith('hysteria2://') ||
        text.startsWith('hy2://') ||
        text.startsWith('ss://')) {
      final config = text.startsWith('ss://')
          ? _parseSsLink(text)
          : _importFromShareLink(text);
      if (config != null) await addCustomServer(config);
      return one(config);
    }
    // OpenVPN .ovpn file (pasted contents)
    if (_looksLikeOvpn(text)) {
      final config = _importOvpn(text);
      if (config != null) {
        await addCustomServer(config);
        return one(config);
      }
    }
    // Try as raw JSON — a single object OR an exported array (a backup
    // link decodes to an array, so re-importing must accept both).
    try {
      final json = jsonDecode(text);
      if (json is List) {
        if (json.isEmpty) return (count: 0, last: null);
        ServerConfig? last;
        var imported = 0;
        for (final item in json) {
          if (item is! Map) continue;
          final cfg = ServerConfig.fromJson(Map<String, dynamic>.from(item));
          await addCustomServer(cfg);
          last = cfg;
          imported++;
        }
        return (count: imported, last: last);
      }
      if (json is Map) {
        final foreign = await _importForeignTunnelJson(
          Map<String, dynamic>.from(json),
          lockPin: lockPin,
        );
        if (foreign != null) return foreign;
        final config = ServerConfig.fromJson(Map<String, dynamic>.from(json));
        await addCustomServer(config);
        return one(config);
      }
    } catch (_) {}

    // Injector-style `key=value` share text (pasted or opened from a
    // .cfg/.txt/.st file). A multi-config .st export carries several
    // `###`-separated sections — import every one of them. Runs before the
    // locked-config fallback so a pasted share imports straight into
    // My Configs.
    final headers = RegExp(r'^###.*$', multiLine: true).allMatches(text);
    if (headers.length > 1) {
      final blocks = text
          .split(RegExp(r'^###.*$', multiLine: true))
          .map((b) => b.trim())
          .where((b) => b.isNotEmpty);
      ServerConfig? last;
      var imported = 0;
      for (final block in blocks) {
        final hc = ServerConfig.fromHttpCustomConfig(block);
        if (hc == null) continue;
        await addCustomServer(hc);
        last = hc;
        imported++;
      }
      if (imported > 0) return (count: imported, last: last);
      // Nothing parsed as share sections — fall through to the single-text
      // paths below (the ### lines may belong to some other format).
    }
    final hc = ServerConfig.fromHttpCustomConfig(text);
    if (hc != null) {
      await addCustomServer(hc);
      return one(hc);
    }

    // Locked envelope: the plain "v2" kind opens with the app key; the
    // "v2p" kind is a USER-locked share — it only opens with the PIN the
    // sharer sent alongside. Import throws [LockPinRequired] for those so
    // the UI can ask for the PIN and retry.
    if (text.startsWith('sensei:v2p:')) {
      if (lockPin == null || lockPin.isEmpty) {
        throw const LockPinRequired();
      }
      final unlocked = await VpnService.parseLockedConfig(text, pin: lockPin);
      if (unlocked == null || unlocked['ok'] != true) {
        return (count: 0, last: null); // wrong PIN — the UI reports it
      }
      return one(_configFromLockedPayload(unlocked, text));
    }
    final lockedConfig = await VpnService.parseLockedConfig(text);
    if (lockedConfig != null && lockedConfig['ok'] == true) {
      return one(_configFromLockedPayload(lockedConfig, text));
    }
    // Nothing recognized: log a fingerprint so a "shared then cannot import"
    // crash is diagnosable from the device log. Brief in release, full in
    // debug (see [logImportError]).
    if (text.length <= 220) {
      logImportError('format', text.replaceAll('\n', '\\n'));
    } else {
      final head = text.substring(0, 120).replaceAll('\n', '\\n');
      final tail = text.substring(text.length - 100).replaceAll('\n', '\\n');
      logImportError(
          'format', '${text.length} chars (head: $head … tail: $tail)');
    }
    return (count: 0, last: null);
  }

  Future<ImportResult?> _importForeignTunnelJson(
    Map<String, dynamic> json, {
    String? lockPin,
  }) async {
    final hasServers = json['Servers'] is List;
    final hasNetworks = json['HTTPNetworks'] is List;
    if (!hasServers && !hasNetworks) return null;

    var imported = 0;
    ServerConfig? last;
    final cert = (json['Ovpn_Cert'] ?? json['OVPNCert'] ?? '').toString();

    String s(Map<dynamic, dynamic> m, String key) =>
        (m[key] ?? '').toString().trim();
    int portOf(String raw, int fallback) => int.tryParse(raw.trim()) ?? fallback;

    if (hasServers) {
      for (final item in (json['Servers'] as List)) {
        if (item is! Map) continue;
        final m = Map<dynamic, dynamic>.from(item);
        final share = [
          s(m, 'ServerCloudFront'),
          s(m, 'ServerCloudFrontHost'),
          s(m, 'ServerIP'),
          s(m, 'ServerHTTP'),
        ].firstWhere(
          (v) => v.startsWith('darktunnel://'),
          orElse: () => '',
        );
        if (share.isNotEmpty) {
          final cfg = await importFromUri(share, lockPin: lockPin);
          if (cfg != null) {
            imported++;
            last = cfg;
          }
          continue;
        }

        final host = [
          s(m, 'ServerIP'),
          s(m, 'ServerIPHost'),
          s(m, 'ServerCloudFront'),
          s(m, 'ServerCloudFrontHost'),
          s(m, 'ServerHTTP'),
          s(m, 'ServerHTTPHost'),
        ].firstWhere((v) => v.isNotEmpty, orElse: () => '');
        if (host.isEmpty) continue;

        final name = s(m, 'Name').isNotEmpty
            ? s(m, 'Name')
            : 'Imported $host';
        final type = portOf(s(m, 'serverType'), portOf(s(m, 'ServerType'), 0));
        ServerConfig? cfg;
        if (type == 3 ||
            s(m, 'Username').isNotEmpty ||
            s(m, 'Password').isNotEmpty) {
          cfg = ServerConfig(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: name,
            protocol: ProtocolType.ssh,
            address: host,
            port: portOf(s(m, 'TcpPort'), portOf(s(m, 'Port'), 22)),
            sshUser: s(m, 'Username'),
            sshPass: s(m, 'Password'),
            capabilities: const ['IMPORTED'],
            isCustom: true,
          );
        } else if (type == 0 || cert.isNotEmpty) {
          final port =
              portOf(s(m, 'TcpPort'), portOf(s(m, 'OpenVPNTCPPort'), 1194));
          final profile = StringBuffer()
            ..writeln('client')
            ..writeln('dev tun')
            ..writeln('proto tcp')
            ..writeln('remote $host $port')
            ..writeln('resolv-retry infinite')
            ..writeln('nobind')
            ..writeln('persist-key')
            ..writeln('persist-tun')
            ..writeln('verb 3');
          if (cert.trim().isNotEmpty) {
            profile
              ..writeln('<ca>')
              ..writeln(cert.trim())
              ..writeln('</ca>');
          }
          cfg = ServerConfig(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: name,
            protocol: ProtocolType.openvpn,
            address: host,
            port: port,
            ovpnConfig: profile.toString(),
            capabilities: const ['IMPORTED'],
            isCustom: true,
          );
        }
        if (cfg == null) continue;
        await addCustomServer(cfg);
        imported++;
        last = cfg;
      }
    }

    if (hasNetworks) {
      for (final item in (json['HTTPNetworks'] as List)) {
        if (item is! Map) continue;
        final m = Map<dynamic, dynamic>.from(item);
        final payload = s(m, 'NetworkPayload');
        final sni = s(m, 'SSLSNI');
        if (payload.isEmpty && sni.isEmpty) continue;
        final squidRaw = s(m, 'SquidProxy');
        final squid = squidRaw.isEmpty ? kDefaultProxyHost : squidRaw;
        final squidPort =
            s(m, 'SquidPort').isEmpty ? kDefaultProxyPort : s(m, 'SquidPort');
        final netName = s(m, 'Name').isNotEmpty
            ? s(m, 'Name')
            : 'Imported Network';
        final mode = sni.isNotEmpty ? 'proxySni' : 'proxy';
        final text = [
          'official=1',
          'name=$netName',
          'capability=IMPORTED',
          'ridefamily=mixed',
          if (sni.isNotEmpty) 'sni=$sni',
          if (payload.isNotEmpty) 'payload=$payload',
          'bug=$squid',
          'bugport=$squidPort',
          'injectMode=$mode',
        ].join('\n');
        final cfg = ServerConfig.fromHttpCustomConfig(text);
        if (cfg == null) continue;
        await addCustomServer(cfg);
        imported++;
        last = cfg;
      }
    }

    return (count: imported, last: last);
  }

  /// Extract public Sensei share lines that wrap or directly contain a native
  /// v48 envelope. Normal backup links intentionally return no match.
  List<String> _senseiEnvelopeLines(String text) {
    // Chat/notes apps sometimes hard-wrap a long share token across lines.
    // When the WHOLE text (whitespace stripped) is exactly one share, import
    // that — a multi-share .st file's squashed form concatenates envelopes
    // and fails the JSON decode below, so it safely falls back to the
    // line-by-line scan.
    final squashed = text.replaceAll(RegExp(r'\s+'), '');
    if (squashed.startsWith('armantunnel://base64/48/') ||
        VpnService.unwrapShareEnvelope(squashed) != null) {
      return [squashed];
    }
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty);
    final out = <String>[];
    for (final line in lines) {
      if (line.startsWith('armantunnel://base64/48/')) {
        out.add(line);
        continue;
      }
      if (VpnService.unwrapShareEnvelope(line) != null) out.add(line);
    }
    return out;
  }

  /// Build the My Configs entry from an unlocked locked-config payload.
  ServerConfig _configFromLockedPayload(
    Map lockedConfig,
    String envelopeText,
  ) {
    final config = ServerConfig(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: lockedConfig['name'] ?? lockedConfig['address'] ?? 'Locked Config',
      note: lockedConfig['name'] ?? lockedConfig['address'] ?? 'Locked Config',
      protocol: ServerConfig.parseProtocol(
          (lockedConfig['protocol'] ?? 'ssh').toString()),
      transport: ServerConfig.parseTransport(
          (lockedConfig['transport'] ?? 'tcp').toString()),
      security: ServerConfig.parseSecurity(
          (lockedConfig['security'] ?? 'none').toString()),
      address: lockedConfig['address'] ?? '',
      port: ServerConfig.parsePort(lockedConfig['port'], 22),
      uuid: lockedConfig['uuid'] ?? lockedConfig['password'] ?? '',
      password: lockedConfig['password'],
      sni: lockedConfig['sni'],
      payload: lockedConfig['payload'],
      sshUser: lockedConfig['sshUser'] ?? lockedConfig['username'],
      sshPass: lockedConfig['sshPass'] ?? lockedConfig['password'],
      injectHost: lockedConfig['injectHost'],
      injectPort: lockedConfig['injectPort']?.toString(),
      injectMode: lockedConfig['injectMode'] != null
          ? ServerConfig.parseInjectMode(lockedConfig['injectMode'])
          : InjectMode.none,
      ovpnConfig: lockedConfig['ovpnConfig'],
      isCustom: true,
      rawConfig: envelopeText,
      author: lockedConfig['author'],
      encryptionKey: lockedConfig['encryptionKey'],
      // A user-locked share arrives locked and stays locked on this device —
      // the card only offers delete + note so the protected fields can never
      // leak through the share or edit flows.
      locked: lockedConfig['locked'] == true,
      lockMessage: lockedConfig['lockMessage'],
      expiresAt: ServerConfig.parseNullableInt(lockedConfig['expiresAt']),
    );
    return config;
  }

  /// Heuristic: does this text look like an OpenVPN .ovpn profile?
  bool _looksLikeOvpn(String text) {
    final lower = text.toLowerCase();
    if (!RegExp(r'(^|\n)\s*remote\s+\S+', multiLine: true).hasMatch(lower)) {
      return false;
    }
    const markers = [
      'dev tun',
      'dev tap',
      '<ca>',
      'client',
      'proto ',
      'auth-user-pass',
      '<tls-auth>',
      '<tls-crypt>',
      'cipher ',
      'remote-cert',
    ];
    return markers.any(lower.contains);
  }

  /// The `proto` declared in an .ovpn (defaults to udp, as OpenVPN does).
  String _ovpnProto(String text) {
    final p =
        RegExp(r'^\s*proto\s+(tcp|udp)', multiLine: true, caseSensitive: false)
            .firstMatch(text);
    return (p?.group(1) ?? 'udp').toLowerCase();
  }

  /// Build an OpenVPN config from pasted/imported .ovpn file contents.
  /// Tolerant of `remote host`, `remote host port`, `remote host port proto`
  /// and picks a sane default port from the declared proto when absent.
  ServerConfig? _importOvpn(String text, {String? name}) {
    try {
      final m = RegExp(r'^\s*remote\s+(\S+)(?:\s+(\d+))?(?:\s+(tcp|udp))?',
              multiLine: true, caseSensitive: false)
          .firstMatch(text);
      if (m == null) return null;
      final host = m.group(1) ?? '';
      if (host.isEmpty) return null;
      final proto = (m.group(3) ?? _ovpnProto(text)).toLowerCase();
      final port =
          int.tryParse(m.group(2) ?? '') ?? (proto == 'tcp' ? 443 : 1194);
      return ServerConfig(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: (name != null && name.trim().isNotEmpty)
            ? name.trim()
            : (host.isNotEmpty ? 'OpenVPN $host' : 'OpenVPN'),
        protocol: ProtocolType.openvpn,
        address: host,
        port: port,
        ovpnConfig: text,
        isCustom: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse a share link / URI into a config WITHOUT persisting it. Used to
  /// pre-fill the manual form (e.g. "Import from Clipboard").
  ServerConfig? parseForPrefill(String text) {
    text = text.trim();
    if (text.startsWith('darktunnel://')) {
      return ServerConfig.fromDarkTunnelUri(text);
    }
    if (text.startsWith('ss://')) {
      return _parseSsLink(text);
    }
    if (text.startsWith('vless://') ||
        text.startsWith('vmess://') ||
        text.startsWith('trojan://') ||
        text.startsWith('hysteria2://') ||
        text.startsWith('hy2://')) {
      return _importFromShareLink(text);
    }
    if (_looksLikeOvpn(text)) {
      return _importOvpn(text);
    }
    // Plain-text `key=value` shares (payload/sni/bug/proxy).
    final hc = ServerConfig.fromHttpCustomConfig(text);
    if (hc != null) return hc;
    return null;
  }

  ServerConfig? _importFromShareLink(String link) {
    // Parse standard v2ray share links
    try {
      if (link.startsWith('vless://')) {
        return _parseVlessLink(link);
      } else if (link.startsWith('vmess://')) {
        return _parseVmessLink(link);
      } else if (link.startsWith('trojan://')) {
        return _parseTrojanLink(link);
      } else if (link.startsWith('hysteria2://') || link.startsWith('hy2://')) {
        return _parseHysteriaLink(link);
      }
    } catch (_) {}
    return null;
  }

  /// Hysteria 2 share link: `hysteria2://auth@host:port?sni=…&insecure=1#name`
  /// (also the `hy2://` shorthand). The auth segment is the password; the
  /// common TLS/obfuscation knobs ride as query params.
  ServerConfig? _parseHysteriaLink(String link) {
    try {
      final uri = Uri.parse(link);
      final auth = uri.userInfo;
      final address = uri.host;
      final port = uri.port > 0 ? uri.port : 443;
      final params = uri.queryParameters;
      final fragment = uri.fragment;
      return ServerConfig(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: fragment.isNotEmpty ? fragment : 'Hysteria $address',
        note: fragment,
        protocol: ProtocolType.hysteria,
        transport: TransportType.tcp,
        security: params['insecure'] == '1' ? SecurityType.none : SecurityType.tls,
        address: address,
        port: port,
        password: auth,
        sni: params['sni'],
        isCustom: true,
      );
    } catch (_) {
      return null;
    }
  }

  ServerConfig? _parseVlessLink(String link) {
    try {
      final uri = Uri.parse(link);
      final uuid = uri.userInfo;
      final address = uri.host;
      // `Uri.port` is 0 when the link carries no ":port" — importing a bare
      // `vless://uuid@host` used to store port 0 (the feed filter drops those,
      // the importer never did). Default like every other VLESS parser.
      final port = uri.port > 0 ? uri.port : 443;
      final params = uri.queryParameters;
      final fragment = uri.fragment;

      return ServerConfig(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: fragment.isNotEmpty ? fragment : 'VLESS $address',
        note: fragment,
        protocol: ProtocolType.vless,
        transport: ServerConfig.parseTransport(params['type'] ?? ''),
        security: params['security'] == 'tls'
            ? SecurityType.tls
            : params['security'] == 'reality'
                ? SecurityType.reality
                : SecurityType.none,
        address: address,
        port: port,
        uuid: uuid,
        encryption: params['encryption'] ?? 'none',
        sni: params['sni'],
        path: params['path'],
        host: params['host'],
        serviceName: params['serviceName'],
        flow: params['flow'],
        fingerprint: params['fp'],
        publicKey: params['pbk'],
        shortId: params['sid'],
        isCustom: true,
      );
    } catch (_) {
      return null;
    }
  }

  ServerConfig? _parseVmessLink(String link) {
    try {
      final encoded = link.replaceFirst('vmess://', '');
      final jsonStr =
          utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
      final data = jsonDecode(jsonStr);

      return ServerConfig(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: data['ps'] ?? 'VMess',
        note: data['ps'] ?? '',
        protocol: ProtocolType.vmess,
        transport: ServerConfig.parseTransport(data['net'] ?? ''),
        security: (data['tls'] == 'tls' || data['tls'] == true)
            ? SecurityType.tls
            : (data['tls'] == 'reality'
                ? SecurityType.reality
                : SecurityType.none),
        address: data['add'] ?? '',
        port: int.tryParse(data['port']?.toString() ?? '') ?? 443,
        uuid: data['id'] ?? '',
        alterId: data['aid']?.toString(),
        encryption: data['scy'] ?? 'auto',
        sni: data['sni'],
        // gRPC carries the service name in `path` on the wire — putting it
        // into `path` produces empty grpcSettings, so route it properly.
        path: data['net'] == 'grpc' ? null : data['path'],
        host: data['host'],
        serviceName: data['net'] == 'grpc' ? data['path'] : null,
        fingerprint: data['fp'],
        isCustom: true,
      );
    } catch (_) {
      return null;
    }
  }

  ServerConfig? _parseTrojanLink(String link) {
    try {
      final uri = Uri.parse(link);
      final password = uri.userInfo;
      final address = uri.host;
      final port = uri.port > 0 ? uri.port : 443; // see _parseVlessLink
      final params = uri.queryParameters;
      final fragment = uri.fragment;

      return ServerConfig(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: fragment.isNotEmpty ? fragment : 'Trojan $address',
        note: fragment,
        protocol: ProtocolType.trojan,
        transport: ServerConfig.parseTransport(params['type'] ?? ''),
        security:
            params['security'] == 'none' ? SecurityType.none : SecurityType.tls,
        address: address,
        port: port,
        uuid: password,
        password: password,
        sni: params['sni'],
        path: params['type'] == 'grpc' ? null : params['path'],
        host: params['host'],
        serviceName: params['serviceName'] ??
            (params['type'] == 'grpc' ? params['path'] : null),
        flow: params['flow'],
        fingerprint: params['fp'],
        isCustom: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Save a subscription URL and immediately fetch it (servers + usage).
  /// Returns the number of servers imported.
  Future<int> setSubscriptionUrl(String url) async {
    url = url.trim();
    final prefs = await SharedPreferences.getInstance();
    if (url.isEmpty) {
      await clearSubscription();
      return 0;
    }
    await prefs.setString(_subUrlKey, url);
    _subscriptionUrl = url;
    return refreshSubscription(url);
  }

  /// Remove the saved subscription, its imported servers and cached usage.
  Future<void> clearSubscription() async {
    final prefs = await SharedPreferences.getInstance();
    _servers.removeWhere((s) => s.id.startsWith('sub_'));
    await prefs.remove(_subUrlKey);
    _subscriptionUrl = '';
    _subscriptionUsage = null;
    await _saveServers();
    notifyListeners();
  }

  /// Fetch a subscription URL: read usage/expiry from the `subscription-userinfo`
  /// response header and import its base64 share-link list as servers (replacing
  /// any previously imported from a subscription). Single network hit — callers
  /// must NOT poll this. Returns the number of servers imported.
  Future<int> refreshSubscription(String url, {bool replace = true}) async {
    url = url.trim();
    if (url.isEmpty) return 0;
    if (!await VpnService.verifyIntegrity()) return 0;
    try {
      final resp = await TunnelHttpClient.get(
        Uri.parse(url),
        headers: {'User-Agent': 'ArmanTunnel/1.0'},
      );
      if (resp.statusCode != 200) return 0;

      // Usage/expiry (HTTP headers are lower-cased by the http package).
      final info = _parseUserinfo(resp.headers['subscription-userinfo']);
      if (info != null) _subscriptionUsage = info;

      // Body: base64 of newline-separated share links, or the raw links.
      String body = resp.body.trim();
      if (!body.contains('://')) {
        try {
          final norm = body.replaceAll(RegExp(r'\s'), '');
          body = utf8.decode(base64.decode(base64.normalize(norm)));
        } catch (_) {}
      }

      final imported = <ServerConfig>[];
      for (var line in const LineSplitter().convert(body)) {
        line = line.trim();
        if (line.isEmpty) continue;
        final cfg = line.startsWith('ss://')
            ? _parseSsLink(line)
            : _importFromShareLink(line);
        if (cfg == null || cfg.address.isEmpty) continue;
        // Force a unique, recognizable id (`sub_…`) so subscription servers
        // can be replaced wholesale and never collide with same-ms parser ids.
        final json = cfg.toJson();
        json['id'] =
            'sub_${DateTime.now().microsecondsSinceEpoch}_${imported.length}';
        imported.add(ServerConfig.fromJson(json));
      }

      // Only touch the server list when we actually parsed servers, so a
      // transient empty/failed body never wipes previously-imported servers.
      if (imported.isNotEmpty) {
        if (replace) _servers.removeWhere((s) => s.id.startsWith('sub_'));
        _servers.addAll(imported);
        await _saveServers();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_subUrlKey, url);
      _subscriptionUrl = url;
      notifyListeners();
      return imported.length;
    } catch (e) {
      debugPrint('Subscription refresh failed: $e');
      return 0;
    }
  }

  /// Parse the standard `Subscription-Userinfo` header value into usage/expiry.
  /// Form: `upload=<bytes>; download=<bytes>; total=<bytes>; expire=<unix-sec>`.
  /// Tolerant of spacing/casing, `,`/`;` separators and forks sending expire ms.
  Map<String, dynamic>? _parseUserinfo(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final o = <String, int>{};
    for (final part in header.split(RegExp(r'[;,]'))) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final k = part.substring(0, eq).trim().toLowerCase();
      final val = int.tryParse(part.substring(eq + 1).trim());
      if (k.isNotEmpty && val != null) o[k] = val;
    }
    if (o.isEmpty) return null;
    final upload = o['upload'] ?? 0;
    final download = o['download'] ?? 0;
    final total = o['total'] ?? 0;
    final used = upload + download;
    const giB = 1073741824;
    var expire = o['expire'] ?? 0;
    if (expire > 100000000000) expire = expire ~/ 1000; // ms -> s safety
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    double gb(num b) => double.parse((b / giB).toStringAsFixed(2));
    return {
      'upload': upload,
      'download': download,
      'used': used,
      'total': total,
      'usedGB': gb(used),
      'totalGB': total > 0 ? gb(total) : 0.0,
      'remainingGB': total > 0 ? gb((total - used).clamp(0, total)) : 0.0,
      'percent': total > 0
          ? double.parse((used / total * 100).toStringAsFixed(1))
          : 0.0,
      'unlimited': total == 0,
      'expire': expire,
      'daysLeft': expire > 0
          ? ((expire - nowSec) / 86400).round().clamp(0, 1 << 31)
          : 0,
      'expired': expire > 0 && expire < nowSec,
    };
  }

  /// Parse a `ss://` share link (base64 method:pass, either side of `@`).
  ServerConfig? _parseSsLink(String link) {
    try {
      var rest = link.substring(5);
      String name = '';
      final h = rest.indexOf('#');
      if (h >= 0) {
        name = Uri.decodeComponent(rest.substring(h + 1));
        rest = rest.substring(0, h);
      }
      final q = rest.indexOf('?');
      if (q >= 0) rest = rest.substring(0, q);
      String method = '', password = '', address = '';
      int port = 443;
      String b64dec(String s) {
        try {
          return utf8.decode(base64.decode(base64.normalize(s)));
        } catch (_) {
          return s;
        }
      }

      if (rest.contains('@')) {
        final at = rest.lastIndexOf('@');
        final creds = b64dec(rest.substring(0, at));
        final ci = creds.indexOf(':');
        method = ci < 0 ? creds : creds.substring(0, ci);
        password = ci < 0 ? '' : creds.substring(ci + 1);
        final hp = rest.substring(at + 1).split(':');
        address = hp[0];
        port = int.tryParse(hp.length > 1 ? hp[1] : '') ?? 443;
      } else {
        final dec = b64dec(rest);
        final at = dec.lastIndexOf('@');
        final creds = dec.substring(0, at);
        final ci = creds.indexOf(':');
        method = ci < 0 ? creds : creds.substring(0, ci);
        password = ci < 0 ? '' : creds.substring(ci + 1);
        final hp = dec.substring(at + 1).split(':');
        address = hp[0];
        port = int.tryParse(hp.length > 1 ? hp[1] : '') ?? 443;
      }
      if (address.isEmpty) return null;
      return ServerConfig(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.isNotEmpty ? name : 'SS $address',
        note: name,
        protocol: ProtocolType.shadowsocks,
        address: address,
        port: port,
        password: password,
        encryption: method,
        isCustom: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Pending-selection write chain. Fire-and-forget SharedPreferences writes
  /// from two rapid selects could land out of order (or be lost to a fast
  /// app kill), leaving prefs disagreeing with the on-screen pick after a
  /// restart — every save now awaits its predecessor.
  Future<void> _selectedSaveTail = Future.value();

  /// Select a server for connection
  void selectServer(ServerConfig? server) {
    _selectedServer = server;
    _selectedSaveTail = _selectedSaveTail
        .then((_) => _saveSelectedServer(server?.id))
        .catchError((Object e) {
      debugPrint('persist selection failed: $e');
    });
    notifyListeners();
  }

  /// Await the queued selection persists (tests + graceful-exit hook).
  Future<void> flushPendingSelectionSave() => _selectedSaveTail;

  void _replaceOfficialServers(List<ServerConfig> officialConfigs) {
    final seen = <String>{};
    final dedupedOfficial = <ServerConfig>[];
    for (final server in officialConfigs) {
      final key =
          server.id.isNotEmpty ? server.id : '${server.address}:${server.port}';
      if (seen.add(key)) dedupedOfficial.add(server);
    }
    final customServers = _servers
        .where((s) => s.isCustom)
        .map((s) => _isOfficialTweakWith(s, dedupedOfficial)
            ? ConfigService.officialTweakPlaceholder(s)
            : s)
        .toList();
    _servers = [...dedupedOfficial, ...customServers];
    _applyPendingSelection();
  }

  /// A saved selection that didn't match any server at restore time (feed
  /// not loaded yet / GitHub fetch failed). Re-applied the moment the list
  /// gains the matching server — the user's picked tunnel is never silently
  /// replaced by "first usable".
  String? _pendingSelectedId;

  void _applyPendingSelection() {
    final id = _pendingSelectedId;
    if (id == null || id.isEmpty) return;
    for (final server in _servers) {
      if (server.id == id) {
        _pendingSelectedId = null;
        if (_selectedServer?.id != id) {
          _selectedServer = server;
          _saveSelectedServer(id);
          notifyListeners();
        }
        return;
      }
    }
  }

  void _restoreSelectedServer(String? selectedId) {
    if (_servers.isEmpty) {
      _selectedServer = null;
      return;
    }
    if (selectedId != null && selectedId.isNotEmpty) {
      for (final server in _servers) {
        if (server.id == selectedId) {
          _selectedServer = server;
          _pendingSelectedId = null;
          return;
        }
      }
      // Not found YET (feed still loading / offline): remember it and pick a
      // usable stand-in for the UI, but DO NOT overwrite the saved id.
      _pendingSelectedId = selectedId;
    }
    if (_selectedServer == null ||
        !_servers.any((s) => s.id == _selectedServer!.id)) {
      // Prefer a usable node over a dead one; never fabricate placeholders.
      final usable = _servers.where((s) => !s.isBlocked).toList();
      _selectedServer = (usable.isNotEmpty ? usable : _servers).first;
    }
  }

  /// The failover pool for a selected config: every usable server in the same
  /// category (the admin's "plan"), in feed order (panel publishes pre-sorted
  /// by priority), so the app always has a next server to try when one fails
  /// to start. Custom servers are included too when they share the category,
  /// so a user's own node can back up an official plan.
  List<ServerConfig> poolFor(ServerConfig anchor) =>
      ServerPool.build(_servers, anchor);

  Future<void> _saveSelectedServer(String? id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id == null || id.isEmpty) {
        await prefs.remove(_selectedStorageKey);
      } else {
        await prefs.setString(_selectedStorageKey, id);
      }
    } catch (e) {
      debugPrint('Failed to save selected server: $e');
    }
  }

  Future<void> _saveServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _servers.map((s) => s.toJson()).toList();
      final json = jsonEncode(jsonList);
      // Encrypt the decrypted config list before it hits disk (see the load
      // path for the matching `sek1:` decrypt). Falls back to plaintext only
      // if Keystore crypto is unavailable — a rare, degraded case.
      final encrypted = await VpnService.encryptCache(json);
      await prefs.setString(_storageKey, encrypted ?? json);
    } catch (e) {
      debugPrint('Failed to save servers: $e');
    }
  }
}

/// Failover-pool selection for "connect with automatic fallback".
///
/// Order: the anchor (the config the user picked) first, then every usable
/// server sharing the anchor's category in feed order, then every remaining
/// usable server as a last tier — the user asked for automatic server change
/// when one fails, so connect should never be a dead-end while any usable
/// server exists. Blocked (locked/expired) servers are always skipped.
class ServerPool {
  static List<ServerConfig> build(
    List<ServerConfig> servers,
    ServerConfig anchor,
  ) {
    final pool = <ServerConfig>[];
    final seen = <String>{};
    void add(ServerConfig s) {
      if (s.isBlocked) return;
      if (seen.add(s.id)) pool.add(s);
    }

    add(anchor);
    for (final s in servers) {
      if (s.category == anchor.category) add(s);
    }
    for (final s in servers) {
      add(s);
    }
    return pool;
  }
}
