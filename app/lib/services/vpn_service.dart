import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart'; // Uint8List lives in dart:typed_data re-exported by services

import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_config.dart';

/// Saved-credential preference keys (written by the Account screen). Used as a
/// fallback when the selected config has no SSH/OpenVPN login of its own.
const _kAccountUser = 'snapdark_acc_user';
const _kAccountPass = 'snapdark_acc_pass';

/// Runtime build facts fetched once from the native side. The installed app
/// reports the PER-ABI versionCode (split APKs: 59*10+1/2 → 591/592), which is
/// NOT the compile-time `kAppBuildNumber` — force-update gates must compare
/// against what Android actually installed, or they misfire.
class AppInstallInfo {
  const AppInstallInfo({
    required this.versionCode,
    required this.versionName,
    required this.supportedAbis,
    required this.is64Bit,
  });

  final int versionCode;
  final String versionName;
  final List<String> supportedAbis;
  final bool is64Bit;

  String get abiLabel {
    for (final abi in supportedAbis) {
      if (abi == 'arm64-v8a') return 'arm64-v8a';
      if (abi == 'armeabi-v7a') return 'armeabi-v7a';
    }
    return supportedAbis.isEmpty ? 'unknown' : supportedAbis.first;
  }
}

class VpnService {
  static const MethodChannel _channel = MethodChannel('com.snapdark.tunnel/vpn');
  static const EventChannel _stateChannel =
      EventChannel('com.snapdark.tunnel/vpn_state');
  static const EventChannel _statsChannel =
      EventChannel('com.snapdark.tunnel/vpn_stats');

  static Stream<String>? _stateStream;
  static Stream<Map>? _statsStream;

  static AppInstallInfo? _installInfo;

  /// Runtime build facts (cached after the first fetch). Pre-warm this during
  /// startup — see `primeInstallInfo` — so update gates read the real code.
  static AppInstallInfo? get installInfo => _installInfo;

  /// Best-effort fetch of installed build facts. Safe to call repeatedly.
  static Future<AppInstallInfo?> fetchInstallInfo() async {
    if (_installInfo != null) return _installInfo;
    try {
      final m =
          await _channel.invokeMapMethod<String, dynamic>('installedPackageInfo');
      if (m == null) return null;
      _installInfo = AppInstallInfo(
        versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
        versionName: m['versionName']?.toString() ?? '',
        supportedAbis: (m['supportedAbis'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        is64Bit: m['is64Bit'] == true,
      );
    } catch (_) {
      return null;
    }
    return _installInfo;
  }

  /// Start VPN connection
  static Future<bool> startVpn(
    ServerConfig config, {
    int mtu = 1500,
    List<String> dnsServers = const <String>['8.8.8.8', '8.8.4.4', '1.1.1.1'],
    bool bypassLan = true,
    bool wakeLock = false,
    bool autoReconnect = false,
    bool killSwitch = false,
    bool hotspotShare = true,
    String? sniOverride,
    String splitMode = 'off',
    List<String> splitApps = const [],
    List<Map<String, String>> routeRules = const [],
    bool muxEnabled = false,
    bool tlsFragment = false,
    int keepAliveMode = 1,
    bool ovpnUseOvpn3 = false,
  }) async {
    try {
      // A custom SNI / bug-host lets the same server be used with a different
      // SNI for DPI bypass. Override the server's SNI (and the WS/host bug-host
      // when it was empty) before building the engine config.
      if (sniOverride != null && sniOverride.trim().isNotEmpty) {
        final sni = sniOverride.trim();
        final j = config.toJson();
        j['sni'] = sni;
        if ((j['host'] ?? '').toString().isEmpty) j['host'] = sni;
        config = ServerConfig.fromJson(j);
      }
      // Credential fallback: SSH / OpenVPN configs without their own login use
      // the account-screen credentials. This makes the Account screen's
      // "reused by configs that need a login" claim actually true.
      final needsCreds =
          config.isSshFamily || config.protocol == ProtocolType.openvpn;
      if (needsCreds &&
          ((config.sshUser ?? '').isEmpty || (config.sshPass ?? '').isEmpty)) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final savedUser = prefs.getString(_kAccountUser) ?? '';
          final savedPass = prefs.getString(_kAccountPass) ?? '';
          if (savedUser.isNotEmpty || savedPass.isNotEmpty) {
            final j = config.toJson();
            if ((config.sshUser ?? '').isEmpty && savedUser.isNotEmpty) {
              j['sshUser'] = savedUser;
            }
            if ((config.sshPass ?? '').isEmpty && savedPass.isNotEmpty) {
              j['sshPass'] = savedPass;
            }
            config = ServerConfig.fromJson(j);
          }
        } catch (_) {
          // Fallback is best-effort; missing prefs just keep the config as-is.
        }
      }
      final xrayConfig = config.protocol == ProtocolType.hysteria
          ? config.toHysteriaConfig(10808, hotspotShare: hotspotShare)
          : config.toXrayConfig(
              10808,
              'tun2socks',
              routeRules: routeRules,
              muxEnabled: muxEnabled,
              tlsFragment: tlsFragment,
              hotspotShare: hotspotShare,
              dnsServers: dnsServers,
            );
      final result = await _channel.invokeMethod<bool>('startVpn', {
        'config': xrayConfig,
        'serverName': config.displayName,
        'mtu': mtu,
        // The whole ordered list, so the TUN can hand Android every resolver and
        // xray the same set. dnsPrimary/dnsSecondary stay on the wire because
        // the OpenVPN engines still take exactly two.
        'dnsServers': dnsServers,
        'dnsPrimary': dnsServers.isNotEmpty ? dnsServers.first : '8.8.8.8',
        'dnsSecondary': dnsServers.length > 1
            ? dnsServers[1]
            : (dnsServers.isNotEmpty ? dnsServers.first : '8.8.8.8'),
        'bypassLan': bypassLan,
        'wakeLock': wakeLock,
        'autoReconnect': autoReconnect,
        'killSwitch': killSwitch,
        'hotspotShare': hotspotShare,
        'keepAliveMode': keepAliveMode.clamp(0, 2),
        // V2Ray wire params (protocol/transport/tls/uuid/path/host/
        // serviceName) are NOT sent: the native engine reads them only from
        // the xray JSON in `config`. These top-level copies were never put as
        // extras nor read by the service — dead weight and a drift trap.
        'address': config.address,
        'port': config.port,
        'sni': config.sni ?? '',
        'isSsh': config.isSshFamily,
        'isOpenvpn': config.protocol == ProtocolType.openvpn,
        'isWireguard': config.protocol == ProtocolType.wireguard,
        'isProxy': config.isProxyFamily,
        'isPsiphon': config.protocol == ProtocolType.psiphon,
        'isHysteria': config.protocol == ProtocolType.hysteria,
        'wireguardConfig': config.wireguardConfig ?? '',
        'proxyMode': config.protocol == ProtocolType.socks ? 'socks' : 'http',
        'psiphonRegion': config.psiphonRegion ?? '',
        'ovpnUseOvpn3': ovpnUseOvpn3,
        'ovpnConfig': config.ovpnConfig ?? '',
        'mode': config.protocol.name,
        'sshUser': config.sshUser ?? '',
        'sshPass': config.sshPass ?? '',
        // A blank address means the config dials through its inject front
        // (SNI/payload/proxy shares). Hand the front over as the SSH host so
        // the engine's direct-connect paths have a real target.
        'sshHost': config.address.trim().isNotEmpty
            ? config.address
            : config.effectiveInjectHost,
        'sshPort': config.port,
        'payload': config.payload ?? '',
        'injectMode': config.injectMode.name,
        'injectHost': config.effectiveInjectHost,
        'injectPort': config.effectiveInjectPort,
        'dnsttServer': config.dnsttServer ?? '',
        'dnsttKey': config.dnsttKey ?? '',
        'dnsttResolver': config.dnsttResolver ?? '',
        'payloadEnhanced': config.payloadEnhanced,
        'sshCompression': config.sshCompression,
        'v2rayInject': config.v2rayInjectActive,
        // Split tunnel: only forward a non-empty selection so the native side
        // keeps default (all-apps) behaviour when nothing is configured.
        'splitMode': splitApps.isEmpty ? 'off' : splitMode,
        'splitApps': splitApps,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      throw Exception('VPN start failed: ${e.message}');
    }
  }

  /// List installed launchable apps for the split-tunnel picker.
  /// Each entry: {package: String, name: String, system: bool}.
  static Future<List<Map<String, dynamic>>> installedApps() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('installedApps');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((m) => {
                'package': (m['package'] ?? '').toString(),
                'name': (m['name'] ?? '').toString(),
                'system': m['system'] == true,
              })
          .toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Live proxy usage: how many active connections are on the SOCKS/HTTP/DNS
  /// proxy ports right now, plus the distinct non-local client IPs (the number
  /// of other devices actively using the tunnel through this phone).
  static Future<Map<String, dynamic>> proxyStats() async {
    try {
      final raw = await _channel.invokeMethod<Map>('getProxyStats');
      return {
        'count': (raw?['count'] ?? 0) as int,
        'devices': (raw?['devices'] ?? const []) as List,
      };
    } on PlatformException {
      return {'count': 0, 'devices': const []};
    } on MissingPluginException {
      return {'count': 0, 'devices': const []};
    }
  }

  /// Stop VPN connection
  static Future<bool> stopVpn() async {
    try {
      final result = await _channel.invokeMethod<bool>('stopVpn');
      return result ?? false;
    } on PlatformException catch (e) {
      throw Exception('VPN stop failed: ${e.message}');
    }
  }

  /// Download the update APK into public Downloads and open Android installer.
  static Future<bool> downloadAndInstallApk(String url) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'downloadAndInstallApk',
        {'url': url},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      throw Exception(e.message ?? 'Update download failed');
    }
  }

  /// Check if VPN is running
  static Future<bool> isVpnRunning() async {
    try {
      final result = await _channel.invokeMethod<bool>('isVpnRunning');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Live session info from the VPN service itself — the source of truth for
  /// restoring the home screen after the app was swiped from recents while
  /// the tunnel kept running. [connectedAt] is the real epoch-ms start of the
  /// session (0 when not connected); [serverName] is the server the service
  /// actually connected to.
  static Future<VpnSessionInfo> sessionInfo() async {
    try {
      final result =
          await _channel.invokeMethod<Map<Object?, Object?>>('sessionInfo');
      return VpnSessionInfo.fromMap(result ?? const {});
    } on PlatformException {
      return const VpnSessionInfo();
    }
  }

  /// Get VPN state stream
  static Stream<String> get vpnStateStream {
    _stateStream ??=
        _stateChannel.receiveBroadcastStream().map((event) => event.toString());
    return _stateStream!;
  }

  /// Get VPN stats stream (speed, traffic)
  static Stream<Map> get vpnStatsStream {
    _statsStream ??= _statsChannel.receiveBroadcastStream().map((event) {
      if (event is Map) return event;
      return {};
    });
    return _statsStream!;
  }

  /// Request VPN permission
  static Future<bool> requestVpnPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestVpnPermission');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Measure delay to current server
  static Future<int> measureDelay() async {
    try {
      final result = await _channel.invokeMethod<int>('measureDelay');
      return result ?? -1;
    } on PlatformException {
      return -1;
    }
  }

  /// Fresh real-time latency probe. Through the tunnel when it's up
  /// (default target: Google connectivity check). Returns -1 on failure.
  static Future<int> pingHost({
    String host = 'connectivitycheck.gstatic.com',
    int port = 80,
    bool throughVpn = true,
  }) async {
    try {
      final result = await _channel.invokeMethod<int>('pingHost', {
        'host': host,
        'port': port,
        'throughVpn': throughVpn,
      });
      return result ?? -1;
    } on PlatformException {
      return -1;
    }
  }

  /// Probes many `host:port` targets in parallel and returns the elapsed ms
  /// per target in the SAME order (-1 = unreachable/timeout).
  ///
  /// Used for the per-card latency badges: one channel call for the whole
  /// server list instead of N, probed on a bounded native pool. [throughVpn]
  /// (default true) routes each probe through the running tunnel (SOCKS on
  /// 10808, or the VPN network's socket factory for OpenVPN) so a badge
  /// measures the latency the user actually gets through the server; with no
  /// session up the probes fall back to a direct connect automatically.
  static Future<List<int>> pingHosts(
    List<String> targets, {
    bool throughVpn = true,
  }) async {
    if (targets.isEmpty) return const [];
    try {
      final res = await _channel.invokeMethod<List<Object?>>(
        'pingHosts',
        {'targets': targets, 'throughVpn': throughVpn},
      );
      if (res == null || res.length != targets.length) {
        return List<int>.filled(targets.length, -1);
      }
      return res.map((e) => (e as int?) ?? -1).toList();
    } on PlatformException {
      return List<int>.filled(targets.length, -1);
    }
  }

  /// HTTP-level probe: sends a real request and times the response status line.
  ///
  /// A TCP connect only proves a socket opened; a captive portal or a stalled
  /// proxy still looks fast. [host] accepts `example.com`, `example.com/path`
  /// or a full `http(s)://host:port/path` URL.
  static Future<HttpPingResult> httpPing({
    String host = 'connectivitycheck.gstatic.com/generate_204',
    int port = 0,
    bool throughVpn = true,
    bool https = false,
  }) async {
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>(
        'httpPing',
        {
          'host': host,
          'port': port,
          'throughVpn': throughVpn,
          'https': https,
        },
      );
      if (res == null) return const HttpPingResult(ms: -1);
      return HttpPingResult(
        ms: (res['ms'] as int?) ?? -1,
        status: (res['status'] as String?) ?? '',
        server: (res['server'] as String?) ?? '',
        target: (res['target'] as String?) ?? '',
        error: (res['error'] as String?) ?? '',
      );
    } on PlatformException catch (e) {
      return HttpPingResult(ms: -1, error: e.message ?? 'channel error');
    }
  }

  /// Route the APP's own traffic through the VPN network (speed-test sheet
  /// only). The app deliberately keeps its own physical network at all other
  /// times, so this must always be paired with `setSelfThroughVpn(false)`
  /// when the sheet closes. Returns false with no session / OEM bind refusal.
  static Future<bool> setSelfThroughVpn(bool on) async {
    try {
      final res = await _channel.invokeMethod<bool>('setSelfThroughVpn', {
        'on': on,
      });
      return res ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<String> getLastError() async {
    try {
      final result = await _channel.invokeMethod<String>('getLastError');
      return result ?? '';
    } on PlatformException {
      return '';
    }
  }

  /// Open a locked config envelope. The native side returns a decoded Map
  /// (`{ok: true, ...fields}` / `{ok: false}`) — request it with the exact
  /// codec type: the old `invokeMethod<Map>` cast blew up with a TypeError
  /// when native handed back the decrypted JSON string, which silently made
  /// EVERY v2/v2p locked import "fail".
  static Future<Map<Object?, Object?>?> parseLockedConfig(
    String config, {
    String? pin,
  }) async {
    try {
      return await _channel.invokeMethod<Map<Object?, Object?>>(
        'parseLockedConfig',
        {'config': config, 'pin': pin},
      );
    } on PlatformException {
      return null;
    }
  }

  /// Tells native the Dart method-call handler is attached, so it may deliver
  /// cold-start intents (deep links / shares / file opens) that arrived while
  /// the engine was still booting. Called once from main().
  static Future<void> notifyNativeReady() async {
    try {
      await _channel.invokeMethod<bool>('flutterReady');
    } on PlatformException {
      // Old native build without the method — cold-start links stay best-effort.
    }
  }

  static Future<String?> encryptLockedConfig(
    Map<String, dynamic> config, {
    String? pin,
  }) async {
    try {
      return await _channel.invokeMethod<String>('encryptLockedConfig', {
        ...config,
        'pin': pin,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Short non-reversible marker of a lock PIN — the importer compares a PIN
  /// guess against this before running the full import. The sharer sends the
  /// envelope and the PIN separately; the check keeps a wrong PIN from
  /// decrypting garbage into a config.
  static Future<String> deriveLockCheck(String pin) async {
    try {
      return await _channel.invokeMethod<String>('deriveLockCheck', {
            'pin': pin,
          }) ??
          '';
    } on PlatformException {
      return '';
    }
  }

  /// Decrypt a config envelope (v3 signature-bound / v2 AES / v1 XOR) natively.
  /// Returns plaintext JSON, or null if native can't handle it (caller falls back).
  static Future<String?> decryptConfig(String body) async {
    try {
      return await _channel
          .invokeMethod<String>('decryptConfig', {'body': body});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Issue a cert-bound native VIP unlock ticket for [configId], valid
  /// [durationMs]. Returns the `sensei:vip:` envelope, or null if native
  /// integrity gates are off. Stored instead of a plain expiry timestamp so a
  /// root-edited preferences line can't mint VIP access.
  static Future<String?> issueVipTicket(
      String configId, Duration duration) async {
    try {
      return await _channel.invokeMethod<String>('vipIssue', {
        'configId': configId,
        'durationMs': duration.inMilliseconds,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Verify a VIP unlock ticket. Returns the expiry (epoch ms) when the ticket
  /// is authentic, bound to [configId] and unexpired, else null.
  static Future<DateTime?> verifyVipTicket(
      String? ticket, String configId) async {
    if (ticket == null || ticket.isEmpty) return null;
    try {
      final ms = await _channel
          .invokeMethod<int>('vipVerify', {'ticket': ticket, 'configId': configId});
      if (ms == null || ms < 0) return null;
      final dt = DateTime.fromMillisecondsSinceEpoch(ms);
      return dt.isAfter(DateTime.now()) ? dt : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// The app's signing certificate SHA-256 (lowercase hex). Paste this into the
  /// Worker so it can encrypt configs (v3) bound to this exact build.
  static Future<String> appCertSha256() async {
    try {
      return await _channel.invokeMethod<String>('appCertSha256') ?? '';
    } on PlatformException {
      return '';
    }
  }

  /// False when the running app's signature does not match the expected release cert.
  static Future<bool> verifyIntegrity() async {
    try {
      return await _channel.invokeMethod<bool>('verifyIntegrity') ?? true;
    } catch (_) {
      // Broad on purpose: MissingPluginException is an Error, NOT an
      // Exception — `on PlatformException` let it escape and abort the whole
      // loadServers() chain (blank config list, no home state) on any device
      // where the channel is momentarily unavailable.
      return true;
    }
  }

  // --- At-rest cache encryption (AndroidKeyStore AES-256-GCM) ---
  // Encrypts the decrypted server JSON before writing to SharedPreferences
  // so a rooted-device file dump yields only ciphertext.  Returns null on
  // failure so callers can fall back to plaintext (extremely rare).

  static Future<String?> encryptCache(String plain) async {
    try {
      return await _channel.invokeMethod<String>('encryptCache', {'plain': plain});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<String?> decryptCache(String blob) async {
    try {
      return await _channel.invokeMethod<String>('decryptCache', {'blob': blob});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  // -----------------------------------------------------------------------

  static Future<void> ignoreBatteryOptimization() async {
    try {
      await _channel.invokeMethod('ignoreBatteryOptimization');
    } on PlatformException {/* */}
  }

  static Future<void> openApnSettings() async {
    try {
      await _channel.invokeMethod('openApnSettings');
    } on PlatformException {/* */}
  }

  // ---- v48 share envelope --------------------------------------------------

  /// Build a protected share string for a config JSON. [options] keys:
  /// lock, hwid, password, expiresAt, blockRoot, blockApps, note.
  static Future<String?> shareEnvelopeBuild(
    String configJson,
    Map<String, dynamic> options,
  ) async {
    try {
      return await _channel.invokeMethod<String>('shareEnvelopeBuild', {
        'config': configJson,
        ...options,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Public share text must stay opaque: `armantunnel://<base64url(json)>`.
  /// The native v48 envelope remains inside that JSON so legacy security logic
  /// (password/HWID/expiry/root/app checks) stays untouched.
  static String wrapShareEnvelope(String envelope) {
    final json = jsonEncode({
      'snapdarkShare': 48,
      'envelope': envelope,
    });
    return 'armantunnel://${base64Url.encode(utf8.encode(json)).replaceAll('=', '')}';
  }

  /// Returns the embedded native v48 envelope when [text] is a new opaque
  /// SnapDark share, or null for normal backup links / malformed text.
  static String? unwrapShareEnvelope(String text) {
    const prefix = 'armantunnel://';
    final t = text.trim();
    if (!t.startsWith(prefix) || t.startsWith('armantunnel://base64/48/')) {
      return null;
    }
    try {
      final payload = t.substring(prefix.length).trim();
      final json = utf8.decode(base64Url.decode(base64Url.normalize(payload)));
      final data = jsonDecode(json);
      if (data is! Map || data['snapdarkShare'] != 48) return null;
      final envelope = data['envelope']?.toString() ?? '';
      return envelope.startsWith('armantunnel://base64/48/') ? envelope : null;
    } catch (_) {
      return null;
    }
  }

  /// Open a v48 share, enforcing its restrictions. Returns
  /// {ok, config, error, needsPassword, flags, note} — [password] is passed
  /// on the retry after the UI asked for it (needsPassword was true).
  static Future<Map<dynamic, dynamic>> shareEnvelopeOpen(
    String text, {
    String? password,
  }) async {
    try {
      final res = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('shareEnvelopeOpen', {
        'text': text,
        'password': password,
      });
      return res ?? {'ok': false, 'error': 'Share open failed'};
    } on PlatformException {
      return {'ok': false, 'error': 'Share open failed'};
    }
  }

  /// Does the share text carry a password gate? (UI asks for it first.)
  static Future<bool> shareEnvelopeNeedsPassword(String text) async {
    try {
      return await _channel.invokeMethod<bool>(
              'shareEnvelopeNeedsPassword', {'text': text}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// This device's HWID hash (for display in the share options dialog).
  static Future<String> deviceHwid() async {
    try {
      return await _channel.invokeMethod<String>('deviceHwid') ?? '';
    } on PlatformException {
      return '';
    }
  }

  /// Open the hidden 4G/5G network-mode switcher (preferred network type):
  /// the phone-info testing menus, falling back to the per-SIM mobile
  /// network page. SIM-aware on dual-SIM devices.
  static Future<void> openNetworkModeSettings() async {
    try {
      await _channel.invokeMethod('openNetworkModeSettings');
    } on PlatformException {/* */}
  }

  static Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod('openAppSettings');
    } on PlatformException {/* */}
  }

  /// Read a config file the user "opened with" SnapDarkTunnel (a content://
  /// URI from a file manager). Returns its text, or null on failure.
  static Future<String?> readConfigFile(String uri) async {
    try {
      return await _channel
          .invokeMethod<String>('readConfigFile', {'uri': uri});
    } on PlatformException {
      return null;
    }
  }

  /// Hand [text] to the Android share sheet (ACTION_SEND chooser) — the
  /// standard "share config" flow. Returns false when the native side is
  /// unavailable (tests / no activity).
  static Future<bool> shareText(String text,
      {String title = 'Share config'}) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'shareText',
        {'text': text, 'title': title},
      );
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }
}

/// Outcome of [VpnService.httpPing].
/// Snapshot of the live VPN session, straight from the service. Used to
/// restore the home screen (elapsed timer, server name) after the app's task
/// was removed from recents while the foreground service kept running.
class VpnSessionInfo {
  final int connectedAt;
  final int elapsedSec;
  final String serverName;
  final String mode;
  final bool running;

  const VpnSessionInfo({
    this.connectedAt = 0,
    this.elapsedSec = 0,
    this.serverName = '',
    this.mode = '',
    this.running = false,
  });

  factory VpnSessionInfo.fromMap(Map<Object?, Object?> map) => VpnSessionInfo(
        connectedAt: (map['connectedAt'] as num?)?.toInt() ?? 0,
        elapsedSec: (map['elapsedSec'] as num?)?.toInt() ?? 0,
        serverName: (map['serverName'] as String?) ?? '',
        mode: (map['mode'] as String?) ?? '',
        running: (map['running'] as bool?) ?? false,
      );

  bool get isConnected => connectedAt > 0;
}

class HttpPingResult {
  const HttpPingResult({
    required this.ms,
    this.status = '',
    this.server = '',
    this.target = '',
    this.error = '',
  });

  /// Round-trip to the response status line, or -1 when the probe failed.
  final int ms;

  /// e.g. `204 No Content`. Empty when nothing answered.
  final String status;

  /// Value of the response's `Server:` header, when present.
  final String server;

  /// The URL that was actually probed, after parsing host/port/scheme.
  final String target;

  /// Failure detail (exception class + message) when [ms] is -1.
  final String error;

  bool get ok => ms > 0;

  /// One-line summary for the log tab.
  String get summary {
    if (!ok) {
      return error.isEmpty ? 'Ping failed ($target)' : 'Ping failed: $error';
    }
    final bits = <String>['$ms ms'];
    if (status.isNotEmpty) bits.add(status);
    if (server.isNotEmpty) bits.add(server);
    return bits.join(' · ');
  }
}
