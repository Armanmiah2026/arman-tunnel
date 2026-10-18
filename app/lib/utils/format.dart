import 'package:flutter/material.dart';

import '../models/server_config.dart';
import '../theme/sensei_tokens.dart';

/// Visual identity for each protocol family.
///
/// The brand forbids red/blue/purple, so protocols are told apart by icon and by
/// *shade* inside the green→lime ramp, never by hue. Centralised here because
/// the tunnel list, the active-server card, the picker and the diagnostics
/// screen all need to agree.
class ProtocolVisual {
  final IconData icon;
  final String label;
  final String blurb;

  const ProtocolVisual({
    required this.icon,
    required this.label,
    required this.blurb,
  });

  static const _map = <ProtocolType, ProtocolVisual>{
    ProtocolType.vless: ProtocolVisual(
      icon: Icons.bolt_rounded,
      label: 'VLESS',
      blurb: 'Low-overhead TLS / Reality transport',
    ),
    ProtocolType.vmess: ProtocolVisual(
      icon: Icons.cloud_rounded,
      label: 'VMess',
      blurb: 'Encrypted WebSocket with dynamic routing',
    ),
    ProtocolType.trojan: ProtocolVisual(
      icon: Icons.shield_rounded,
      label: 'Trojan',
      blurb: 'TLS traffic that mimics plain HTTPS',
    ),
    ProtocolType.shadowsocks: ProtocolVisual(
      icon: Icons.lock_rounded,
      label: 'Shadowsocks',
      blurb: 'Lightweight AEAD stream cipher',
    ),
    ProtocolType.ssh: ProtocolVisual(
      icon: Icons.terminal_rounded,
      label: 'SSH',
      blurb: 'SSH tunnel with payload injection (no UDP)',
    ),
    ProtocolType.sshDnstt: ProtocolVisual(
      icon: Icons.dns_rounded,
      label: 'SSH + DNSTT',
      blurb: 'SSH carried inside DNS (SlowDNS)',
    ),
    ProtocolType.openvpn: ProtocolVisual(
      icon: Icons.vpn_lock_rounded,
      label: 'OpenVPN',
      blurb: 'Standard .ovpn profile engine',
    ),
    ProtocolType.wireguard: ProtocolVisual(
      icon: Icons.shield_moon_rounded,
      label: 'WireGuard',
      blurb: 'Fast modern kernel-style tunnel',
    ),
    ProtocolType.socks: ProtocolVisual(
      icon: Icons.swap_horiz_rounded,
      label: 'SOCKS5',
      blurb: 'Plain SOCKS5 proxy node',
    ),
    ProtocolType.httpProxy: ProtocolVisual(
      icon: Icons.http_rounded,
      label: 'HTTP',
      blurb: 'Plain HTTP proxy node',
    ),
    ProtocolType.psiphon: ProtocolVisual(
      icon: Icons.travel_explore_rounded,
      label: 'Psiphon',
      blurb: 'Psiphon network via CONNECT bridge',
    ),
    ProtocolType.hysteria: ProtocolVisual(
      icon: Icons.wifi_tethering_rounded,
      label: 'Hysteria',
      blurb: 'Fast QUIC/UDP tunnel',
    ),
  };

  /// Null-safe lookups with a generic fallback — a protocol added to the enum
  /// without a map entry used to throw "Null check operator used on a null
  /// value" from every card that rendered it (the BDIX SOCKS servers crashed
  /// the list). The fallback keeps the UI alive and visible instead.
  static const ProtocolVisual _fallback = ProtocolVisual(
    icon: Icons.dns_rounded,
    label: 'Tunnel',
    blurb: 'Tunnel node',
  );

  static ProtocolVisual of(ProtocolType p) => _map[p] ?? _fallback;

  static IconData iconFor(ProtocolType p) => (_map[p] ?? _fallback).icon;

  static String labelFor(ProtocolType p) => (_map[p] ?? _fallback).label;

  static String blurbFor(ProtocolType p) => (_map[p] ?? _fallback).blurb;

  /// Shade inside the brand ramp for [p].
  static Color tint(ProtocolType p, SenseiTokens t) {
    switch (p) {
      case ProtocolType.vless:
        return t.lime;
      case ProtocolType.vmess:
        return t.accent;
      case ProtocolType.trojan:
        return t.accentBright;
      case ProtocolType.shadowsocks:
        return t.accentDeep;
      case ProtocolType.ssh:
        return t.lime;
      case ProtocolType.sshDnstt:
        return t.accentBright;
      case ProtocolType.openvpn:
        return t.accentDeep;
      case ProtocolType.wireguard:
        return t.lime;
      case ProtocolType.socks:
      case ProtocolType.httpProxy:
        return t.accent;
      case ProtocolType.psiphon:
        return t.accentBright;
      case ProtocolType.hysteria:
        return t.lime;
    }
  }
}

/// Human-readable byte counts. Used by stats, diagnostics and the tunnel list.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Per-second throughput from a byte rate.
String formatRate(int bytesPerSecond) {
  if (bytesPerSecond < 1024) return '$bytesPerSecond B/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s';
}

/// `HH:MM:SS` for session timers.
String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:'
      '${two(d.inSeconds.remainder(60))}';
}

/// Best-effort flag emoji from a country hint in the config name/note/address.
/// Resolve a config's display country to an ISO 3166-1 alpha-2 code
/// (e.g. "BD"), or null when nothing usable is set. Prefers the explicit
/// `country` field, then sniffs the note/name/address for known host-country
/// keywords. [flagEmojiFor] converts the result to its regional-indicator
/// emoji for rendering.
String? countryCodeFor(ServerConfig cfg) {
  // Prefer the explicit ISO alpha-2 country field when set.
  if (cfg.country != null && cfg.country!.trim().length == 2) {
    final iso = normalizeCountryCode(cfg.country!.trim());
    if (iso != null) return iso;
  }
  const table = <String, List<String>>{
    'BD': ['BANGLADESH', 'DHAKA', ' BD'],
    'SG': ['SINGAPORE', 'SG1', ' SG'],
    'JP': ['JAPAN', 'TOKYO', ' JP'],
    'US': ['UNITED STATES', 'USA', ' US'],
    'DE': ['GERMANY', 'FRANKFURT', ' DE'],
    'GB': ['UNITED KINGDOM', 'LONDON', ' UK'],
    'IN': ['INDIA', 'MUMBAI', ' IN'],
    'NL': ['NETHERLANDS', 'AMSTERDAM', ' NL'],
    'FR': ['FRANCE', 'PARIS'],
    'MY': ['MALAYSIA', 'KUALA'],
    'AE': ['DUBAI', 'EMIRATES'],
    'TR': ['TURKEY', 'ISTANBUL'],
  };
  final haystack = ' ${cfg.note} ${cfg.name} ${cfg.address} '.toUpperCase();
  for (final entry in table.entries) {
    for (final needle in entry.value) {
      if (haystack.contains(needle)) return entry.key;
    }
  }
  return null;
}

/// ISO 3166-1 alpha-2 code → its regional-indicator flag emoji (e.g. "BD" →
/// 🇧🇩). Null when the code is invalid/blank. User decision: cards show the
/// REAL flag when a config has no logo image — Android's system emoji font
/// renders regional indicators on every BD-market device (Samsung/Xiaomi/
/// Oppo ship them), so the letter-pair worry never materialised in practice.
String? flagEmojiFor(ServerConfig cfg) {
  final code = countryCodeFor(cfg);
  if (code == null || code.length != 2) return null;
  return String.fromCharCodes(
    code.codeUnits.map((u) => 0x1F1E6 + (u - 0x41)),
  );
}

/// Normalize a free-text country value to an ISO 3166-1 alpha-2 code
/// (e.g. "BD", "sg" → "SG"), or null when it isn't a clean 2-letter alpha.
String? normalizeCountryCode(String iso) {
  final code = iso.trim().toUpperCase();
  if (code.length != 2 || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) return null;
  return code;
}

/// Connect-time payload/SNI token resolution (defensive).
///
/// The admin panel already expands named payload tokens ([RYZE] etc.) before
/// publishing, but a config can still arrive carrying the generic markers —
/// hand imports, older feeds or an admin writing `[sni]` directly. At connect
/// time we fill them from the config's own fields so the tunnel starts with a
/// concrete payload/SNI instead of literal bracket text:
///   [payload] → the config's payload (inject payload preferred)
///   [sni]     → the config's SNI
///   [host]    → the server address
///   [port]    → the server port
///   [ua]      → a browser User-Agent
///   [crlf]    → carriage-return + line-feed
/// Unknown [TOKENS] pass through untouched (same rule as the panel).
///
/// [native] marks payloads that the NATIVE PayloadInjector renders on the
/// wire (SSH / OpenVPN injector paths, V2Ray inject). The injector is the
/// authoritative renderer for the wire markers there — in particular its
/// `[host]` means the FRONT (bug/SNI) host, not the real server — so they
/// must stay literal for it; only `[payload]`/`[sni]` (references to the
/// config's own fields, which the injector does not know) are expanded.
/// Pre-baking the real address into `[host]` used to leak the true hostname
/// into the injected request and silently break SSH bug-host payloads.
String resolveConnectTokens(
  String input, {
  String? host,
  String? port,
  String? payload,
  String? sni,
  bool native = false,
}) {
  if (!input.contains('[')) return input;
  var out = input
      .replaceAll('[payload]', (payload ?? '').trim())
      .replaceAll('[sni]', (sni ?? '').trim());
  if (native) return out;
  const ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Mobile Safari/537.36';
  return out
      .replaceAll('[host]', host ?? '')
      .replaceAll('[port]', port ?? '')
      .replaceAll('[ua]', ua)
      .replaceAll('[crlf]', '\r\n');
}
