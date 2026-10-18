import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/server_config.dart';
import 'ad_service.dart';
import 'config_service.dart';
import 'device_trial.dart';
import 'settings_provider.dart';
import 'vpn_service.dart';

/// Per-server latency for the card badges.
///
/// A card badge must show how far the SERVER is, so every probe targets the
/// server's OWN `host:port` (never a bare host). Probes go through the
/// running tunnel when one is up (SOCKS on 10808, or the VPN network's socket
/// factory for OpenVPN) — that is the latency the user actually gets through
/// the server — and fall back to a direct connect when no session is running.
///
/// **Vaulted VIP nodes.** A vaulted proxy publishes a blank address on purpose
/// (the endpoint never leaves the server), so there is nothing to probe from
/// the bundle alone. Once the user has unlocked it, the app already holds the
/// ticket `/api/vip/resolve` demands — so the sweep resolves the endpoint for
/// exactly those nodes first and caches it, then probes it like any other. A
/// node that is still LOCKED gets no badge at all: its latency is part of the
/// endpoint the ad gate is protecting, and probing it early would leak a
/// reachability signal for free.
///
/// The cache is a [ChangeNotifier] singleton: the server list screens call
/// [start] when they appear and [stop] when they go away, so nothing probes
/// in the background while no list is on screen.
class ServerPingCache extends ChangeNotifier {
  ServerPingCache();

  /// Shared instance — cards read this, screens drive it.
  static final ServerPingCache instance = ServerPingCache();

  /// How often the visible list is re-probed. Deliberately unhurried: these
  /// are informational badges, and a 60-server sweep can take a while when a
  /// few endpoints time out.
  static const Duration interval = Duration(seconds: 90);

  /// Upper bound per sweep so a runaway feed cannot queue an unbounded burst of
  /// sockets. The real bound is the native pool (16 threads, whole batch capped
  /// at 6s); this just stops the target list growing without limit.
  static const int maxPerSweep = 80;

  /// How many vaulted endpoints to resolve at once. Each resolve is an HTTPS
  /// round-trip, so this stays modest to be kind to a phone radio.
  static const int resolveConcurrency = 6;

  /// serverId -> elapsed ms. `-1` means "probed and did not answer" — kept
  /// distinct from "not probed yet" (absent) so the card can say so.
  final Map<String, int> _ms = <String, int>{};

  /// serverId -> resolved `host:port` for an unlocked vaulted node. Kept
  /// between sweeps so a long list does not re-resolve every 90s, and dropped
  /// the moment a node stops being unlocked.
  final Map<String, String> _vaulted = <String, String>{};

  Timer? _timer;
  bool _sweeping = false;
  int _generation = 0;

  /// How many card-bearing screens are currently mounted.
  ///
  /// `MainShell` keeps tabs alive in an `IndexedStack`, so a screen's
  /// `dispose` does NOT run on a tab switch — the sweep must therefore be
  /// reference-counted rather than a plain on/off flag, or one screen's
  /// `dispose` would cancel the sweep another screen still needs.
  int _mounted = 0;

  /// The list the periodic timer re-probes — refreshed by [start], since an
  /// `IndexedStack` keeps a screen's original list alive across tab switches.
  List<ServerConfig> _list = const <ServerConfig>[];

  SettingsProvider? _settings;
  ConfigService? _config;

  /// The measured latency for [serverId], or null if it has not been probed.
  int? pingOf(String serverId) => _ms[serverId];

  /// Start sweeping [servers] now and every [interval] after. Calling it again
  /// with a new list just re-points the sweep (the screen rebuilds often).
  ///
  /// [settings] and [config] are needed only to resolve vaulted VIP endpoints;
  /// without them those nodes are skipped and only plaintext ones get a badge.
  void start(
    List<ServerConfig> servers, {
    SettingsProvider? settings,
    ConfigService? config,
  }) {
    if (settings != null) _settings = settings;
    if (config != null) _config = config;
    _mounted++;
    _list = servers;
    _timer ??= Timer.periodic(interval, (_) => sweep(_list));
    unawaited(sweep(servers));
  }

  /// Stop sweeping for one screen; the sweep ends when the last one leaves.
  void stop() {
    if (_mounted > 0) _mounted--;
    if (_mounted > 0) return;
    _timer?.cancel();
    _timer = null;
    // Forget resolved endpoints too — they were resolved under a ticket that
    // may expire while nothing is on screen.
    _vaulted.clear();
  }

  /// Force a re-probe of everything (pull-to-refresh).
  Future<void> refreshNow(List<ServerConfig> servers) => sweep(servers);

  /// Probe [servers] and publish the results.
  ///
  /// Re-entrancy is guarded so a slow sweep cannot be started twice, and a
  /// generation counter drops the result set of a since-replaced list instead
  /// of painting it onto cards that no longer exist.
  Future<void> sweep(List<ServerConfig> servers) async {
    if (_sweeping) return;
    // Claim the sweep BEFORE the resolve round-trips — otherwise two callers
    // (the periodic timer firing while a pull-to-refresh is still resolving)
    // both pass the guard and resolve the whole list twice.
    _sweeping = true;
    final gen = ++_generation;
    try {
      // Resolve the endpoints we are allowed to know before the socket burst,
      // so the sweep itself stays a single native call.
      await resolveVaultedEndpoints(servers);
      if (gen != _generation) return; // a newer sweep superseded this one

      final targets = <ServerConfig>[];
      final hosts = <String>[];
      for (final s in servers) {
        if (targets.length >= maxPerSweep) break;
        final host = _hostFor(s);
        if (host == null) continue;
        targets.add(s);
        hosts.add(host);
      }
      if (targets.isEmpty) return;

      final results = await VpnService.pingHosts(hosts);
      if (gen != _generation) return; // a newer sweep superseded this one
      var changed = false;
      for (var i = 0; i < targets.length && i < results.length; i++) {
        final ms = results[i];
        if (_ms[targets[i].id] != ms) {
          _ms[targets[i].id] = ms;
          changed = true;
        }
      }
      if (changed) notifyListeners();
    } finally {
      _sweeping = false;
    }
  }

  /// `host:port` to probe for [s], or null when there is no address to use
  /// (blank endpoint and not resolved, or no port).
  String? _hostFor(ServerConfig s) {
    final address = s.address.trim();
    if (address.isNotEmpty && s.port > 0) return '$address:${s.port}';
    final resolved = _vaulted[s.id];
    if (resolved != null && resolved.isNotEmpty) return resolved;
    return null;
  }

  bool _isVaulted(ServerConfig s) =>
      (s.vault ?? '').isNotEmpty && s.address.trim().isEmpty;

  /// Resolve every unlocked vaulted node whose endpoint is not cached yet.
  ///
  /// Bounded concurrency; a failure (offline, expired ticket, worker down) is
  /// simply not cached, so the next sweep retries. Endpoints of nodes that are
  /// no longer unlocked are dropped immediately — a resolved address must not
  /// outlive the ticket that justified knowing it.
  Future<void> resolveVaultedEndpoints(List<ServerConfig> servers) async {
    final settings = _settings;
    final config = _config;
    if (settings == null || config == null) return;

    // Forget anything whose gate is no longer open.
    final stale = <String>[];
    for (final entry in _vaulted.entries) {
      ServerConfig? node;
      for (final s in servers) {
        if (s.id == entry.key) {
          node = s;
          break;
        }
      }
      if (node == null || !settings.isVipUnlocked(node.id, vip: node.vip)) {
        stale.add(entry.key);
      }
    }
    for (final id in stale) {
      _vaulted.remove(id);
    }

    final pending = servers
        .where((s) =>
            _isVaulted(s) &&
            !_vaulted.containsKey(s.id) &&
            settings.isVipUnlocked(s.id, vip: s.vip) &&
            // While the ads gate is open (pre-Play-Store) a vaulted endpoint
            // resolves WITHOUT a ticket — the Worker allows it then. With ads
            // on, a node resolves with a real ticket OR as an admin-granted
            // VIP device (resolveVipEndpoint switches to the device param).
            (!AdConfig.adsEnabled ||
                (settings.vipTicket(s.id) ?? '').isNotEmpty ||
                DeviceTrial.instance.isVipDevice))
        .toList();
    if (pending.isEmpty) return;

    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (next >= pending.length) return;
        final s = pending[next++];
        final ticket = settings.vipTicket(s.id);
        try {
          final resolved = await config.resolveVipEndpoint(s, ticket: ticket);
          if (resolved != null && resolved.address.trim().isNotEmpty) {
            _vaulted[s.id] = '${resolved.address.trim()}:${resolved.port}';
          }
        } catch (_) {
          // Offline / worker down / ticket rejected — retry next sweep.
        }
      }
    }

    await Future.wait(List.generate(resolveConcurrency, (_) => worker()));
  }

  /// Drop everything (e.g. the feed was replaced). Keeps the object usable.
  void reset() {
    _ms.clear();
    _vaulted.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}