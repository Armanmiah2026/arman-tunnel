import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/server_config.dart';
import '../models/vpn_state.dart';
import '../services/ad_service.dart';
import '../services/config_service.dart';
import '../services/device_trial.dart';
import '../services/location_service.dart';
import '../services/log_service.dart';
import '../services/session_history.dart';
import '../services/tunnel_http_client.dart';
import '../services/settings_provider.dart';
import '../services/vpn_service.dart';
import '../theme/snapdark_theme.dart';
import '../utils/format.dart';
import '../utils/lion_roar.dart';
import '../utils/user_error.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_update_sheet.dart';
import '../widgets/snapdark/connection_area.dart';
import '../widgets/snapdark/dashboard_cards.dart';
import '../widgets/snapdark/golden_lion_background.dart';
import '../widgets/snapdark/theme_toggle.dart';
import '../widgets/snapdark/ad_banner.dart';
import '../widgets/ui/snapdark_controls.dart';
import '../widgets/ui/snapdark_modal.dart';
import '../widgets/vip_unlock_sheet.dart';
import '../utils/banner_renderer.dart';
import '../widgets/ui/snapdark_page.dart';
import 'split_tunnel_screen.dart';

/// Dashboard: brand header, connect dial, active tunnel, live traffic and the
/// split-tunnel shortcut.
///
/// The layout is a fixed Column — it does not scroll (a dashboard should fit,
/// not scroll like a web page). Only on unusually short screens does it fall
/// back to scrolling so nothing gets cut off.
///
/// The drawer and the back-button behaviour belong to `MainShell`: this screen
/// is one page of an IndexedStack, so it cannot own either.
class SnapDarkHomeScreen extends StatefulWidget {
  /// Opens the shell's navigation drawer.
  final VoidCallback onMenuClick;

  /// Switches the shell to the Configs tab.
  final VoidCallback onOpenConfigs;

  /// Opens the shell's speed-test dialog.
  final VoidCallback onOpenSpeedTest;

  const SnapDarkHomeScreen({
    super.key,
    required this.onMenuClick,
    required this.onOpenConfigs,
    required this.onOpenSpeedTest,
  });

  @override
  State<SnapDarkHomeScreen> createState() => _SnapDarkHomeScreenState();
}

class _SnapDarkHomeScreenState extends State<SnapDarkHomeScreen> {
  static const _broadcastSeenKey = 'snapdark_broadcast_seen';
  static const _kConnectedAtKey = 'snapdark_connected_at';

  StreamSubscription<String>? _stateSub;
  StreamSubscription<Map<dynamic, dynamic>>? _statsSub;
  Timer? _durationTimer;
  Timer? _pingTimer;
  DateTime? _connectedTime;
  int _ping = -1;
  int _pingLogCounter = 0;
  int _pingFailLogged = 0;
  String? _broadcastPromptedKey;
  final List<double> _pingHistory = [];

  /// Captured in initState — `context.read` in `dispose()` looks up an
  /// ancestor on a DEACTIVATED element ("Looking up a deactivated widget's
  /// ancestor is unsafe"), which threw on every real unmount of the home tab
  /// and can kill the route-pop that triggered it.
  late final ConfigService _cfg;

  @override
  void initState() {
    super.initState();
    _setupVpnListeners();
    _restoreIfAlreadyConnected();
    // Latency probing starts ONLY when the tunnel is fully connected (see the
    // 'connected' case below) — per spec, ping/speed are tunnel features.
    // The broadcast dialog depends on the settings bundle arriving over the
    // network, so react to ConfigService changes instead of a blind timer —
    // the fixed 900 ms delay used to fire BEFORE the fetch finished, which is
    // why admin pop-ups never appeared.
    _cfg = context.read<ConfigService>();
    _cfg.addListener(_onConfigChanged);
  }

  void _onConfigChanged() {
    if (!mounted) return;
    final cfg = context.read<ConfigService>();
    if (cfg.broadcastShowDialog && cfg.broadcastKey != _broadcastPromptedKey) {
      _broadcastPromptedKey = cfg.broadcastKey;
      _maybeShowBroadcast();
    }
  }

  /// If the VPN service is already running (app reopened mid-session),
  /// resume the connected UI + live timers without waiting for an event.
  /// The service itself is the source of truth: it knows the real session
  /// start (so the timer does NOT reset after the app was swiped from
  /// recents and the service auto-reconnected) and the server it actually
  /// connected to.
  Future<void> _restoreIfAlreadyConnected() async {
    try {
      final info = await VpnService.sessionInfo();
      if (!info.running && !info.isConnected) return;
      if (!mounted) return;
      final vpn = context.read<VpnState>();
      if (!vpn.isConnected) {
        final cfg = context.read<ConfigService>();
        // Prefer the config whose name matches the service's session, so the
        // selected tunnel is what the service is actually using — even when
        // the stored selection was lost or the list refreshed underneath.
        ServerConfig? live;
        if (info.serverName.isNotEmpty) {
          for (final s in cfg.servers) {
            if (s.displayName == info.serverName || s.name == info.serverName) {
              live = s;
              break;
            }
          }
        }
        final saved = cfg.selectedServer;
        final chosen = live ?? saved;
        if (chosen != null && chosen.id != saved?.id) {
          cfg.selectServer(chosen);
        }
        vpn.setConnecting(info.serverName.isNotEmpty
            ? info.serverName
            : chosen?.displayName ?? '');

        if (info.isConnected) {
          vpn.setConnected();
          // REAL session start from the service — survives process kills
          // (the service continues the session across a redelivered
          // restart). Only fall back to the persisted timestamp, then now().
          final persisted = await _loadConnectedAt();
          _connectedTime = info.connectedAt > 0
              ? DateTime.fromMillisecondsSinceEpoch(info.connectedAt)
              : (persisted ?? DateTime.now());
          _startDurationTimer();
        }
        // running-but-not-yet-connected (redelivered restart still probing):
        // stay in the connecting state — the 'connected' event does the rest,
        // with the true session start (_adoptServiceSessionStart).
      }
      _startPingLoop();
      _refreshPing();
      // App reopened mid-session: this app process is fresh, so its own HTTP
      // traffic must be pointed back at the live tunnel. The service knows
      // the protocol of the LIVE tunnel — that is the source of truth.
      TunnelHttpClient.setTunnelActive(
        true,
        useLocalProxy: info.mode != 'openvpn',
      );
    } catch (_) {}
  }

  /// Adopt the SERVICE's session start for the running timer. Used on the
  /// 'connected' event: `DateTime.now()` is right for a fresh connect, but
  /// after a kill-from-recents the redelivered service restart CONTINUES the
  /// previous session — its connectedAt is the original start, and the timer
  /// must not restart from zero.
  Future<void> _adoptServiceSessionStart() async {
    try {
      final info = await VpnService.sessionInfo();
      if (!mounted || info.connectedAt <= 0) return;
      final svc = DateTime.fromMillisecondsSinceEpoch(info.connectedAt);
      if (_connectedTime == null || !_connectedTime!.isAtSameMomentAs(svc)) {
        _connectedTime = svc;
        _saveConnectedAt();
      }
    } catch (_) {}
  }

  Future<DateTime?> _loadConnectedAt() async {
    final ms = (await SharedPreferences.getInstance()).getInt(_kConnectedAtKey);
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  void _saveConnectedAt() {
    final now = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.getInstance()
        .then((p) => p.setInt(_kConnectedAtKey, now));
  }

  void _clearConnectedAt() {
    SharedPreferences.getInstance().then((p) => p.remove(_kConnectedAtKey));
  }

  /// Route the app's own HTTP traffic through the live tunnel.
  ///
  /// V2Ray and SSH-family tunnels expose a local HTTP proxy on 10809 (xray's
  /// inbound / the native HTTP<->SOCKS bridge), so requests are pointed at
  /// it. OpenVPN has no local proxy — there the service binds the process to
  /// the VPN network and plain connections already flow through the TUN.
  Future<void> _syncTunnelRouting() async {
    var proto =
        context.read<ConfigService>().selectedServer?.protocol.name ?? '';
    if (proto.isEmpty) {
      // Restore race: the config list may not be loaded yet — ask the
      // service, which knows the protocol of the LIVE tunnel.
      try {
        proto = (await VpnService.sessionInfo()).mode;
      } catch (_) {}
    }
    if (!mounted) return;
    TunnelHttpClient.setTunnelActive(true, useLocalProxy: proto != 'openvpn');
  }

  void _setupVpnListeners() {
    _stateSub = VpnService.vpnStateStream.listen((state) {
      if (!mounted) return;
      final vpn = context.read<VpnState>();
      if (state.startsWith('motd:')) {
        final msg = state.substring(5);
        context.read<LogService>().add('Server Message:\n$msg');
        return;
      }
      if (state.startsWith('log:')) {
        final msg = state.substring(4);
        context.read<LogService>().add(msg);
        return;
      }
      if (kDebugMode ||
          state == 'connected' ||
          state == 'disconnected' ||
          state.startsWith('error') ||
          state.startsWith('waiting')) {
        context.read<LogService>().add('VPN state: $state');
      }
      switch (state) {
        case 'connected':
          unawaited(_syncTunnelRouting());
          final alreadyConnected = vpn.isConnected;
          vpn.setConnected();
          if (alreadyConnected) {
            // Duplicate 'connected' event (service re-emit / restore race):
            // keep the running timer, do not reset it to zero.
            break;
          }
          _connectedTime = DateTime.now();
          _saveConnectedAt();
          // Fresh connect → now() is already right; redelivered restart
          // continues the old session → replace with the service's true
          // start so the timer never restarts from zero.
          unawaited(_adoptServiceSessionStart());
          _startDurationTimer();
          _startPingLoop();
          _refreshPing();
          context.read<LocationService>().scheduleRedetect();
          // Real session record for the Connection History tab.
          final server = context.read<ConfigService>().selectedServer;
          unawaited(SessionHistory.instance.begin(
            server?.displayName ?? vpn.connectedServerName,
            protocol: server?.protocolLabel ?? '',
          ));
          break;
        case 'disconnected':
          TunnelHttpClient.setTunnelActive(false);
          // Close the session record with the last known session totals.
          unawaited(SessionHistory.instance.end(
            bytesDown: vpn.totalDownload,
            bytesUp: vpn.totalUpload,
          ));
          vpn.setDisconnected();
          _durationTimer?.cancel();
          _clearConnectedAt();
          // Ping is a tunnel feature: stop probing until the next connect.
          _pingTimer?.cancel();
          setState(() {
            _ping = -1;
            _pingHistory.clear();
          });
          context.read<LocationService>().scheduleRedetect();
          AdService.loadInterstitial();
          AdService.showInterstitial();
          break;
        case 'connecting':
        case 'probe:checking':
        case 'waiting:network':
          vpn.setConnecting(vpn.connectedServerName);
          if (state == 'probe:checking') {
            context
                .read<LogService>()
                .add('Verifying real connectivity through the tunnel…');
          }
          if (state == 'waiting:network') {
            AppToast.warning(context,
                'No network interface. Turn on WiFi / mobile data / Ethernet / BT tether…');
          }
          break;
        default:
          if (state.startsWith('error')) {
            var msg = state.contains(':')
                ? state.substring(state.indexOf(':') + 1)
                : 'Connection failed';
            if (msg == 'reconnect-exhausted') {
              _tryNextFailover(vpn, context.read<ConfigService>());
              return;
            }
            // Machine codes shown to humans: the offline gate never dialed
            // the server, so say THAT instead of a cryptic slug.
            if (msg == 'no-internet') {
              msg = 'No internet connection — check your data/Wi-Fi and try again.';
            }
            final category = _categorizeError(msg);
            // Release users see only the category sentence; the raw engine
            // text stays in Logs (debug shows both).
            final shown = UserError.forCategory(category, raw: msg);
            vpn.setError(shown, category: category);
            AppToast.error(context, shown);
          }
      }
    });
    _statsSub = VpnService.vpnStatsStream.listen((stats) {
      if (!mounted) return;
      context.read<VpnState>().updateSpeed(
            stats['downloadSpeed'] ?? 0,
            stats['uploadSpeed'] ?? 0,
            stats['totalDownload'] ?? 0,
            stats['totalUpload'] ?? 0,
          );
    });
  }

  Future<void> _refreshPing() async {
    final settings = context.read<SettingsProvider>();
    if (!settings.pingEnabled) {
      if (!mounted) return;
      setState(() {
        _ping = -1;
        _pingHistory.clear();
      });
      return;
    }
    // HTTP-level probe (a real request, timed to the response status line),
    // NOT a TCP connect — a bare connect succeeds against captive portals and
    // stalled proxies, so it could report healthy latency on a tunnel carrying
    // nothing. When a tunnel is up the native dial goes through the SOCKS
    // proxy on 10808 (or the VPN network's socket factory for OpenVPN) and
    // measures the session the user is actually running; with no session it
    // falls back to a direct dial. Per-server reachability stays on the
    // Servers tab's TCP badges (pingHosts).
    final res = await VpnService.httpPing(
      host: settings.effectivePingHost,
      https: settings.pingHttps,
    );
    if (!mounted) return;
    final p = res.ms;
    final logging = settings.pingLogging;
    setState(() {
      _ping = p;
      if (p > 0) {
        _pingHistory.add(p.toDouble());
        if (_pingHistory.length > 40) _pingHistory.removeAt(0);
        // Ping history in the Logs tab — one line every ~10 s, not spam.
        _pingLogCounter++;
        if (logging &&
            _pingLogCounter % 5 == 0 &&
            context.read<VpnState>().isConnected) {
          final avg = _pingHistory.isEmpty
              ? p
              : (_pingHistory.reduce((a, b) => a + b) / _pingHistory.length);
          final status = res.status.isEmpty ? '' : ' · ${res.status}';
          context
              .read<LogService>()
              .add('Ping $p ms (avg ${avg.round()} ms)$status');
        }
      }
    });
    // A failed probe is worth one line regardless of the every-5th throttle:
    // it is the difference between "slow" and "nothing is getting through".
    if (logging && p <= 0 && context.read<VpnState>().isConnected) {
      _pingFailLogged++;
      if (_pingFailLogged == 1 || _pingFailLogged % 10 == 0) {
        context.read<LogService>().add(res.summary);
      }
    } else if (p > 0) {
      _pingFailLogged = 0;
    }
  }

  void _startPingLoop() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _refreshPing();
    });
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_connectedTime != null && mounted) {
        context
            .read<VpnState>()
            .updateDuration(DateTime.now().difference(_connectedTime!));
      }
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _statsSub?.cancel();
    _durationTimer?.cancel();
    _pingTimer?.cancel();
    _cfg.removeListener(_onConfigChanged);
    super.dispose();
  }

  Future<void> _onConnectPressed() async {
    final vpn = context.read<VpnState>();
    final cfg = context.read<ConfigService>();
    if (vpn.isConnected || vpn.isConnecting) {
      vpn.setDisconnecting();
      try {
        await VpnService.stopVpn();
      } catch (e) {
        vpn.setError(UserError.forException(e,
            friendly: 'App error — could not stop the tunnel.'));
      }
      return;
    }
    if (cfg.appLocked || cfg.maintenanceMode) {
      AppToast.error(
          context,
          cfg.maintenanceMode && !cfg.appLocked
              ? (cfg.maintenanceMessage.isNotEmpty
                  ? cfg.maintenanceMessage
                  : 'Maintenance in progress')
              : cfg.lockedMessage);
      return;
    }
    if (cfg.updateRequiredByCode) {
      await _showForceUpdate(cfg);
      return;
    }
    var server = cfg.selectedServer;
    if (server == null) {
      // No tunnel selected: go straight to the Tunnels page — the user picks
      // there (no popup, per the new flow).
      AppToast.warning(context, 'Pick a tunnel first');
      widget.onOpenConfigs();
      return;
    }
    if (server.isBlocked) {
      AppToast.error(context, server.blockedReason);
      return;
    }
    server = cfg.resolveOfficialTweak(server);
    final s = context.read<SettingsProvider>();
    // VIP: rewarded-ad gate (the Configs list also gates on tap, but the
    // selected config can be (a) VIP already and (b) re-served on relaunch —
    // the gate here is the final enforcement before dialing).
    final unlocked = await ensureVipUnlocked(context, server);
    if (!mounted || !unlocked) return;
    // BDIX trial gate: a standalone proxy node (socks/http_proxy/psiphon) is a
    // BDIX server — it needs an active trial (auto 1-day on first registration)
    // or an admin-extended grant. Official tweaks are NOT gated here.
    if (_isBdixProxy(server)) {
      final ok = await _ensureBdixTrial(context);
      if (!mounted || !ok) return;
      // No per-connect Worker request — the strict Worker→GitHub→app flow
      // keeps the admin's free Cloudflare limits (100k requests, 1000 KV
      // writes a day) safe; connect counts stay whatever registration saw.
    }
    // Server-side vault: a vaulted VIP config publishes without its endpoint;
    // resolve it now (needs the unlock ticket) so the empty-address check below
    // sees the real address.
    if (server.vault != null && server.vault!.isNotEmpty) {
      final resolved =
          await cfg.resolveVipEndpoint(server, ticket: s.vipTicket(server.id));
      if (!mounted) return;
      if (resolved == null) {
        AppToast.error(
          context,
          'Could not reach this VIP tunnel — check your internet and try again',
        );
        return;
      }
      server = resolved;
    }
    if (server.address.trim().isEmpty &&
        (server.injectHost ?? '').trim().isEmpty) {
      // Custom configs may omit the address (SNI/payload-only shares) — but
      // without an inject front there is nothing to dial either.
      AppToast.error(
        context,
        'This tunnel has no server address — edit the config first',
      );
      return;
    }
    if (s.splitMode != 'off' && s.splitApps.isEmpty) {
      AppToast.warning(context, 'Select at least one app for split tunnel');
      return;
    }
    await _connectSelected(vpn, cfg, server, s);
  }

  /// True when [s] is a standalone BDIX proxy node (the trial gate applies only
  /// to these — official tweaks ride the normal VIP/ad flow instead).
  bool _isBdixProxy(ServerConfig s) {
    final p = s.protocol;
    return p == ProtocolType.socks ||
        p == ProtocolType.httpProxy ||
        p == ProtocolType.psiphon;
  }

  /// BDIX trial gate. Registers the device on first sight (auto-starts the
  /// 1-day trial) and refreshes the status; returns true when the device may
  /// connect. When the trial is expired the user is shown the admin contact
  /// (Telegram/WhatsApp) — no key input; the admin extends the device from
  /// the panel.
  Future<bool> _ensureBdixTrial(BuildContext context) async {
    final trial = DeviceTrial.instance;
    // Flow: Worker → GitHub → app. The free CDN read first; the Worker is
    // hit ONLY when the id is not on the git repo yet (first-ever launch —
    // register creates the record + publishes the file). An expired/banned
    // device's file exists, so its gate makes NO Worker request at all.
    var status = await trial.refreshStatus();
    if (status != null && status['active'] == true) return true;
    if (status == null) {
      status = await trial.register() ?? status;
      if (status != null && status['active'] == true) return true;
    }

    if (!context.mounted) return false;
    final msg = status == null
        ? 'Could not reach the server to check your BDIX trial — check your internet and try again'
        : 'Your BDIX trial has expired. Contact the admin to extend your access.';
    await showDialog<bool>(
      context: context,
      builder: (ctx) => const _TrialContactDialog(),
    );
    if (!context.mounted) return false;
    AppToast.error(context, msg);
    return false;
  }

  /// Note popup for the currently selected config, same HTML rendering as
  /// the Configs list so sharer colours/styles read as intended.
  void _showServerNote(ServerConfig s) {
    final t = context.tokens;
    final parts = <String>[
      if ((s.lockMessage ?? '').trim().isNotEmpty) s.lockMessage!.trim(),
      if (s.note.trim().isNotEmpty && s.note.trim() != s.name) s.note.trim(),
    ];
    final body = parts.isEmpty ? 'No note on this config.' : parts.join('\n\n');
    final meta = <String>[
      if ((s.author ?? '').trim().isNotEmpty) 'By ${s.author!.trim()}',
      if (s.expiresAt != null)
        'Expires: ${DateTime.fromMillisecondsSinceEpoch(s.expiresAt!).toLocal()}'
            .split('.')
            .first,
      if (s.locked) 'This config is locked — fields are hidden.',
    ];
    SnapDarkModal.popup<void>(
      context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.sticky_note_2_outlined, color: t.accent, size: 26),
        title: Text(s.displayName, textAlign: TextAlign.center),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  children: buildHtmlSpans(
                    ctx,
                    body,
                    TextStyle(color: t.text, fontSize: 13.5, height: 1.45),
                  ),
                ),
              ),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: SnapDarkTokens.gapMd),
                Text(meta.join('\n'),
                    style: TextStyle(color: t.textMuted, fontSize: 11.5)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _tryNextFailover(VpnState vpn, ConfigService cfg) async {
    final current = cfg.selectedServer;
    if (current == null) return;
    final pool = current.failoverCandidates;
    if (pool.isEmpty) {
      vpn.setError('All servers failed', category: ErrorCategory.server);
      if (mounted) AppToast.error(context, 'All servers in this group failed');
      return;
    }
    final next = pool.first;
    final remaining = pool.skip(1).toList();
    final nextConfig = next.copyWith(
      serverPool: remaining.map((e) => e.toJson()).toList(),
    );
    cfg.selectServer(nextConfig);
    if (!mounted) return;
    vpn.setConnecting('Failover → ${next.displayName}');
    context.read<LogService>().add('Trying failover server: ${next.displayName}');
    await _connectSelected(vpn, cfg, nextConfig, context.read<SettingsProvider>());
  }

  ErrorCategory _categorizeError(String msg) {
    final m = msg.toLowerCase();
    if (m.contains('network') ||
        m.contains('internet') ||
        m.contains('no interface') ||
        m.contains('unreachable') ||
        m.contains('timeout') ||
        m.contains('refused')) {
      return ErrorCategory.network;
    }
    if (m.contains('auth') ||
        m.contains('credential') ||
        m.contains('password') ||
        m.contains('login')) {
      return ErrorCategory.auth;
    }
    if (m.contains('config') ||
        m.contains('parse') ||
        m.contains('invalid') ||
        m.contains('missing')) {
      return ErrorCategory.config;
    }
    if (m.contains('server') ||
        m.contains('host') ||
        m.contains('dns') ||
        m.contains('resolve')) {
      return ErrorCategory.server;
    }
    return ErrorCategory.unknown;
  }

  /// Tunnel page picker: Officials first, then the user's own custom configs.
  /// Returns the chosen config (and selects it) or null when dismissed.

  /// Connect to the SELECTED server only — no automatic fallback. A failure
  /// surfaces its real error; switching servers is the user's call (Configs
  /// tab). The pool logic stays available for tests/API, it just no longer
  /// decides which server you end up on.
  Future<void> _connectSelected(
    VpnState vpn,
    ConfigService cfg,
    ServerConfig server,
    SettingsProvider s,
  ) async {
    final candidate = _resolveConnectTokens(server);
    final safe = await _ensureOvpnCreds(candidate, cfg);
    if (safe == null) return; // user cancelled the credentials prompt
    vpn.setConnecting(safe.displayName);
    // THE roar: the dial has been tapped and the tunnel is genuinely going
    // up. Fire-and-forget; audio failures must never stall the dial.
    unawaited(LionRoar.instance.play());

    // The anchor first, then the failover pool: every OTHER compatible
    // server the admin published for this tweak's capability. One dead
    // server must not kill the tweak — the pool entries carry their own
    // endpoint, the method fields stay ours.
    final attempts = <ServerConfig>[safe, ...safe.failoverCandidates];
    String lastError = '';
    for (var i = 0; i < attempts.length; i++) {
      final attempt = attempts[i];
      if (i > 0) {
        if (!mounted) return;
        vpn.setConnecting(
            '${safe.displayName} · failover ${attempt.server ?? attempt.address}');
        context
            .read<LogService>()
            .add('Anchor failed — trying compatible server '
                '${attempt.server ?? attempt.address}');
      }
      try {
        await VpnService.startVpn(
          attempt,
          mtu: s.mtu,
          dnsServers: s.dnsServers,
          bypassLan: s.bypassLan,
          wakeLock: s.wakeLock,
          autoReconnect: s.autoReconnect,
          killSwitch: s.killSwitch,
          hotspotShare: s.hotspotShare,
          sniOverride: s.customSni,
          splitMode: s.splitMode,
          splitApps: s.splitApps.toList(),
          routeRules: s.routeRules,
          muxEnabled: s.muxEnabled,
          tlsFragment: s.tlsFragment,
          keepAliveMode: s.keepAliveMode,
          ovpnUseOvpn3: s.ovpnUseOvpn3,
        );
        await Future.delayed(const Duration(seconds: 2));
        final running = await VpnService.isVpnRunning();
        if (running) return;
        lastError = await VpnService.getLastError();
      } catch (e) {
        lastError = e.toString();
      }
      // This attempt did not come up — tear down any half-started state so
      // the next one (or the next tap) starts clean.
      try {
        await VpnService.stopVpn();
      } catch (_) {}
      if (!mounted) return;
    }
    final msg = (lastError.isNotEmpty)
        ? lastError
        : 'connection failed — no engine came up';
    final shownErr =
        UserError.forCategory(_categorizeError(msg), raw: msg);
    vpn.setError(shownErr);
    if (mounted) AppToast.error(context, shownErr);
  }

  /// Fill the generic payload/SNI markers ([payload]/[sni]) from the config's
  /// own fields before handing it to the engine. Named tokens ([RYZE]…) are
  /// already expanded by the panel; this covers hand imports and the generic
  /// markers. When the NATIVE injector renders the payload
  /// ([ServerConfig.nativeInjectsPayload]), the wire markers
  /// ([host]/[port]/[ua]/[crlf]) are deliberately left literal: the
  /// injector's [host] is the FRONT (bug/SNI) host, and pre-baking the real
  /// server address here used to leak the true hostname into the injected
  /// request — SSH bug-host payloads silently failed DPI bypass.
  ServerConfig _resolveConnectTokens(ServerConfig c) {
    final native = c.nativeInjectsPayload;
    String? fix(String? v) {
      if (v == null || v.isEmpty || !v.contains('[')) return v;
      final resolved = resolveConnectTokens(
        v,
        host: native ? null : c.address,
        port: native ? null : '${c.port}',
        payload: (c.injectPayload?.isNotEmpty ?? false)
            ? c.injectPayload
            : c.payload,
        sni: c.sni,
        native: native,
      );
      return resolved;
    }

    final payload = fix(c.payload);
    final injectPayload = fix(c.injectPayload);
    final sni = fix(c.sni);
    if (identical(payload, c.payload) &&
        identical(injectPayload, c.injectPayload) &&
        identical(sni, c.sni)) {
      return c;
    }
    return c.copyWith(
      payload: payload,
      injectPayload: injectPayload,
      sni: sni,
    );
  }

  /// OpenVPN profiles carrying a bare `auth-user-pass` need credentials the
  /// import flow cannot know. Prompt for them (once — they are persisted on
  /// the config) when neither the config nor the saved account has any.
  Future<ServerConfig?> _ensureOvpnCreds(
    ServerConfig server,
    ConfigService cfg,
  ) async {
    final profile = server.ovpnConfig ?? '';
    if (server.protocol != ProtocolType.openvpn ||
        (server.sshUser ?? '').isNotEmpty ||
        !RegExp(r'^\s*auth-user-pass\s*$', multiLine: true).hasMatch(profile)) {
      return server;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString('snapdark_acc_user') ?? '').isNotEmpty) {
        return server; // connect-time fallback fills them from the account
      }
    } catch (_) {}
    final creds = await _promptOvpnCreds(server.displayName);
    if (creds == null) return null;
    final updated = server.copyWith(
      sshUser: creds.user,
      sshPass: creds.pass,
    );
    try {
      await cfg.updateCustomServer(updated);
    } catch (_) {}
    return updated;
  }

  Future<({String user, String pass})?> _promptOvpnCreds(String name) async {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final t = context.tokens;
    final result = await SnapDarkModal.popup<({String user, String pass})>(
      context,
      dismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.vpn_key_rounded, color: t.accent, size: 26),
        title: const Text('Login Required', textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$name needs a username and password.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: userCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
          ),
          FilledButton(
            onPressed: () {
              if (userCtrl.text.trim().isEmpty) return;
              Navigator.pop(
                ctx,
                (user: userCtrl.text.trim(), pass: passCtrl.text),
              );
            },
            child: const Text('Save & Connect'),
          ),
        ],
      ),
    );
    userCtrl.dispose();
    passCtrl.dispose();
    return result;
  }

  Future<void> _showForceUpdate(ConfigService cfg) async {
    await showAppUpdate(context, cfg, forced: true);
  }

  /// Admin broadcast dialog — shown once per unique payload (keyed by its
  /// updatedAt stamp), never re-shown after dismissal.
  Future<void> _maybeShowBroadcast() async {
    if (!mounted) return;
    final cfg = context.read<ConfigService>();
    if (!cfg.broadcastShowDialog) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_broadcastSeenKey) == cfg.broadcastKey) return;
    if (!mounted) return;
    await SnapDarkModal.popup<void>(
      context,
      builder: (ctx) {
        final t = ctx.tokens;
        return AlertDialog(
          icon: Icon(Icons.campaign_rounded, color: t.accent, size: 26),
          title: Text(
            cfg.broadcastTitle.isNotEmpty ? cfg.broadcastTitle : 'Notice',
            textAlign: TextAlign.center,
          ),
          content: Text(
            cfg.broadcastMessage,
            textAlign: TextAlign.center,
          ),
          actions: [
            if (cfg.broadcastHasAction)
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final uri = Uri.tryParse(cfg.broadcastActionUrl);
                  if (uri != null) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                child: Text(cfg.broadcastActionText),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    await prefs.setString(_broadcastSeenKey, cfg.broadcastKey);
  }

  /// Keep admin notices to three lines — a long remote message must never
  /// blow up the fixed dashboard layout.
  String _clamp(String msg) {
    final lines = msg.split('\n');
    var m = (lines.length > 3 ? lines.take(3).join(' ') : msg);
    if (m.length > 220) m = '${m.substring(0, 217)}…';
    return m;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final vpn = context.watch<VpnState>();
    final cfg = context.watch<ConfigService>();
    final settings = context.watch<SettingsProvider>();
    final server = cfg.selectedServer;
    final busy = vpn.isConnecting ||
        vpn.connectionState == VpnConnectionState.disconnecting;
    // One responsive factor for the WHOLE dashboard (dial, cards, spacing,
    // typography, icons) — see snapdarkScale. Everything shrinks/grows
    // together, so the connect button keeps its relative prominence on
    // low-DPI / small screens instead of being squeezed by fixed-size cards.
    final scale = snapdarkScale(context);
    final size = MediaQuery.sizeOf(context);
    final compact = size.height < 700;
    // Cards use the shared scale but NEVER above 1.0 (the old 1.15 scale-up
    // ballooned the option cards/buttons on tablets) and shrink harder on
    // tall screens so the dial keeps its share. The Flexible + FittedBox
    // below is the real guarantee on tiny screens — this only tunes the
    // "natural" size before that fit kicks in.
    final lowerScale = (size.height >= 790 ? scale * 0.72 : scale)
        .clamp(0.62, 1.0);
    final gap = SnapDarkTokens.gapMd * lowerScale;
    // Banner only where the dashboard can spare its ~57dp: a portrait phone
    // with ≥640dp of height, or a big landscape display. On shorter screens
    // (320-wide low-DPI devices, small landscape phones) the dial + cards
    // need every row — the ad yields to the layout, never the other way.
    final showBanner = size.width <= size.height
        ? size.height >= 640
        : size.height >= 700;

    // Full-screen golden-lion backdrop stack (video + scrim, see
    // GoldenLionBackground). The dashboard renders INSIDE GoldenLionScope,
    // which flips the shared cards to their glass treatment — a faint white
    // wash with a golden hairline — so the 3D background shines through
    // every panel. The old opaque page gradient no longer paints here: the
    // backdrop owns that plane (video/painterly fallback + dark-golden scrim
    // + theme veil), keeping text readable in BOTH themes without hiding
    // the lion.
    Widget withLionBackdrop(Widget dashboard, {bool shockwave = false}) =>
        Stack(
          fit: StackFit.expand,
          children: [
            // The idle lion sprints (fast loop); it eases to natural tempo
            // once the tunnel is up — see GoldenLionBackground.idleSpeed.
            GoldenLionBackground(
              isConnected: vpn.isConnected,
              soundVolume: settings.bgVolume,
            ),
            GoldenLionScope(enabled: true, child: dashboard),
            if (shockwave)
              // ABOVE the dashboard (pointer-transparent): when the tunnel
              // comes up, golden flash + shock rings sweep across the whole
              // screen — the roar moment the dial scene can't reach from
              // inside its own circle. Idle: no ticker runs.
              GoldenLionShockwaveOverlay(isConnected: vpn.isConnected),
          ],
        );

    if (vpn.hasError) {
      Widget errorBody = Column(
        children: [
          SnapDarkBrandHeader(
            onMenuTap: widget.onMenuClick,
            status: vpn.errorCategoryLabel.isEmpty
                ? 'Error'
                : vpn.errorCategoryLabel,
            statusColor: t.statusColor(connected: false, busy: false),
            trailing: [SnapDarkThemeToggle(settings: settings)],
          ),
          const SizedBox(height: SnapDarkTokens.gapMd),
          // The notice gets its OWN shrinkable slot (flex 2 vs the dial's 5)
          // and scrolls inside it: a long error line on a high-density
          // (260/320/400 dpi) phone used to push the whole dial below the
          // screen — "BOTTOM overflowed by 241 pixels" at 240x400, with the
          // connect button off-screen. The message is clamped first; the
          // scroll is the belt-and-braces for extreme scales.
          Flexible(
            flex: 2,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: SnapDarkTokens.pageInset * scale),
              child: SingleChildScrollView(
                child: SnapDarkNotice(
                  kind: SnapDarkNoticeKind.alert,
                  icon: vpn.errorCategoryIcon,
                  message: _clamp(vpn.errorMessage),
                ),
              ),
            ),
          ),
          // Top of the content area — right under the header/notice block.
          if (showBanner) const SnapDarkAdBanner(),
          Flexible(
            flex: 5,
            child: SnapDarkConnectionDial(
              isConnected: vpn.isConnected,
              isConnecting: busy,
              durationText: formatDuration(vpn.connectionDuration),
              caption: vpn.isConnected
                  ? (vpn.connectedServerName.isNotEmpty
                      ? vpn.connectedServerName
                      : server?.displayName ?? '')
                  : server == null
                      ? 'No tunnel selected'
                      : server.displayName,
              onToggleConnect: _onConnectPressed,
            ),
          ),
        ],
      );
      return Scaffold(
        backgroundColor: t.scaffoldBg,
        body: withLionBackdrop(
          SafeArea(
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: SnapDarkTokens.maxContentWidth,
                ),
                child: errorBody,
              ),
            ),
          ),
        ),
      );
    }

    Widget body = Column(
      children: [
        SnapDarkBrandHeader(
          onMenuTap: widget.onMenuClick,
          status: vpn.isConnected
              ? 'Secured • ${server?.protocolLabel ?? 'tunnel'}'
              : busy
                  ? vpn.connectionStateText
                  : 'Not protected',
          statusColor: t.statusColor(
            connected: vpn.isConnected,
            busy: busy,
          ),
          // Quick Dark/Light toggle with the sun↔moon spin animation.
          // Wallpaper Mode is dark-only, so this is also how the user flips
          // between the glass look and the clean light palette.
          trailing: [SnapDarkThemeToggle(settings: settings)],
        ),
        // Scrolling admin banner (marquee-style, single line).
        if (cfg.broadcastMarquee)
          _MarqueeBanner(text: cfg.broadcastMarqueeText),
        if (cfg.appLocked || cfg.maintenanceMode)
          Padding(
            padding: EdgeInsets.fromLTRB(
              SnapDarkTokens.pageInset * scale,
              SnapDarkTokens.gapSm * scale,
              SnapDarkTokens.pageInset * scale,
              0,
            ),
            child: SnapDarkNotice(
              kind: SnapDarkNoticeKind.alert,
              icon: Icons.lock_rounded,
              message: _clamp(cfg.appLocked
                  ? (cfg.lockedMessage.isNotEmpty
                      ? cfg.lockedMessage
                      : 'The admin has locked this app.')
                  : (cfg.maintenanceMessage.isNotEmpty
                      ? cfg.maintenanceMessage
                      : 'Maintenance in progress.')),
            ),
          ),
        // Soft update notice: a newer build exists but is NOT forced — a
        // tappable courtesy strip. The forced path never reaches here (the
        // connect gate owns it), so the same update never renders twice.
        if (cfg.updateAvailableSoft)
          Padding(
            padding: EdgeInsets.fromLTRB(
              SnapDarkTokens.pageInset * scale,
              SnapDarkTokens.gapSm * scale,
              SnapDarkTokens.pageInset * scale,
              0,
            ),
            child: GestureDetector(
              onTap: () => showAppUpdate(context, cfg, forced: false),
              child: SnapDarkNotice(
                kind: SnapDarkNoticeKind.info,
                icon: Icons.system_update_rounded,
                message:
                    'Update available${cfg.latestVersion.isNotEmpty ? ' — v${cfg.latestVersion}' : ''}. Tap to install.',
              ),
            ),
          ),
        // AD — top of the content area, directly below the status/header
        // block. In-flow (never an overlay): it reserves EXACTLY its own
        // fixed banner height (0 before load → no empty gap), and the dial's
        // Flexible below gives that space back / absorbs the rest, so the
        // whole dashboard stays on screen at any size.
        if (showBanner) const SnapDarkAdBanner(),
        // DIAL HAS PRIORITY: it keeps ~1/3 of the SCREEN height (see
        // connection_area). On tight screens the cards below compress —
        // stats drops its totals strip, actions shrink — never the button.
        Flexible(
          flex: 5,
          child: SnapDarkConnectionDial(
            isConnected: vpn.isConnected,
            isConnecting: busy,
            durationText: formatDuration(vpn.connectionDuration),
            caption: vpn.isConnected
                ? (vpn.connectedServerName.isNotEmpty
                    ? vpn.connectedServerName
                    : server?.displayName ?? '')
                : server == null
                    ? 'No tunnel selected'
                    : server.displayName,
            onToggleConnect: _onConnectPressed,
          ),
        ),
        // Lower option cards/buttons: PROPORTIONAL SPACE (flex 3 vs the
        // dial's 5), and a FittedBox that only ever SHRINKS the block when
        // the remaining height is not enough — the server/stats/action cards
        // take the hit, the connect button never does. Their own scale is
        // capped at 1.0 above, so they also never balloon on tablets.
        Flexible(
          flex: 3,
          child: LayoutBuilder(
            builder: (context, box) => FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: box.maxWidth.isFinite
                    ? box.maxWidth
                    : MediaQuery.sizeOf(context).width,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: SnapDarkTokens.pageInset * scale),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SnapDarkServerCard(
                        server: server,
                        // Only meaningful through the tunnel; loop starts on connect.
                        // Tapping opens the Configs tab — the category sections there
                        // are the single place to pick / change a tweak now.
                        pingMs: _ping,
                        onTap: widget.onOpenConfigs,
                        scale: lowerScale,
                        onNote: (server != null &&
                                server.isCustom &&
                                server.hasNoteInfo)
                            ? () => _showServerNote(server)
                            : null,
                      ),
                      SizedBox(height: gap),
                      SnapDarkStatisticsCard(
                        downloadBytesPerSecond: vpn.downloadSpeed,
                        uploadBytesPerSecond: vpn.uploadSpeed,
                        totalDownloadBytes: vpn.totalDownload,
                        totalUploadBytes: vpn.totalUpload,
                        pingMs: _ping < 0 ? 0 : _ping,
                        pingHistory: _pingHistory,
                        active: vpn.isConnected,
                        compact: compact,
                        scale: lowerScale,
                      ),
                      SizedBox(height: gap),
                      SnapDarkQuickActions(
                        dense: compact,
                        scale: lowerScale,
                        actions: [
                          SnapDarkQuickAction(
                            icon: Icons.call_split_rounded,
                            label: 'SPLIT TUNNEL',
                            value: settings.splitTunnelActive
                                ? '${settings.splitApps.length} app'
                                    '${settings.splitApps.length == 1 ? '' : 's'}'
                                : 'Off',
                            active: settings.splitTunnelActive,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const SplitTunnelScreen(),
                              ),
                            ),
                          ),
                          SnapDarkQuickAction(
                            icon: Icons.speed_rounded,
                            label: 'SPEED TEST',
                            value: vpn.isConnected ? 'Live' : 'Idle',
                            onTap: widget.onOpenSpeedTest,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    body = SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: SnapDarkTokens.maxContentWidth,
          ),
          child: body,
        ),
      ),
    );

    return Scaffold(
      backgroundColor: t.scaffoldBg,
      // Fixed dashboard — apps don't scroll. The dial sits in an Expanded
      // and absorbs whatever space is left, so every screen size fits
      // without a scrollbar. The golden-lion backdrop (video + scrim) sits
      // behind everything; the shockwave overlay rides on top for the
      // connect-success moment.
      body: withLionBackdrop(body, shockwave: true),
    );
  }
}

/// One-line scrolling notice used for admin broadcasts.
class _MarqueeBanner extends StatefulWidget {
  final String text;
  const _MarqueeBanner({required this.text});

  @override
  State<_MarqueeBanner> createState() => _MarqueeBannerState();
}

class _MarqueeBannerState extends State<_MarqueeBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = snapdarkScale(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: 5 * s),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.10),
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final slide = MediaQuery.sizeOf(context).width + 320;
          final offset = Offset(slide - (slide * 2 * _controller.value), 0);
          return Transform.translate(
            offset: offset,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.text,
                maxLines: 1,
                style: TextStyle(
                  color: t.accent,
                  fontSize: 12 * s,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3 * s,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Contact-admin dialog shown when a BDIX trial is expired. The user never
/// inputs a key — they contact the admin (Telegram/WhatsApp) and the admin
/// extends the device from the panel.
class _TrialContactDialog extends StatelessWidget {
  const _TrialContactDialog();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final cfg = context.read<ConfigService>();
    final contact = cfg.providerContact.isNotEmpty
        ? cfg.providerContact
        : 'https://t.me/armantunnel';
    final whatsapp = cfg.providerWhatsapp;
    return AlertDialog(
      icon: Icon(Icons.contact_support_rounded, color: t.accent, size: 26),
      title: const Text('BDIX trial expired', textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Your 1-day BDIX trial has ended. Contact the admin to extend your access — '
            'no key needed, they will unlock your device.',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textSecondary, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          SnapDarkPrimaryButton(
            label: 'Telegram',
            icon: Icons.send_rounded,
            onPressed: () => launchUrl(
              Uri.parse(contact),
              mode: LaunchMode.externalApplication,
            ),
          ),
          if (whatsapp.isNotEmpty) ...[
            const SizedBox(height: 10),
            SnapDarkPrimaryButton(
              label: 'WhatsApp',
              icon: Icons.chat_rounded,
              onPressed: () => launchUrl(
                Uri.parse(
                  whatsapp.startsWith('http')
                      ? whatsapp
                      : 'https://wa.me/${whatsapp.replaceAll(RegExp(r'[^0-9]'), '')}',
                ),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Close', style: TextStyle(color: t.textMuted)),
        ),
      ],
    );
  }
}
