import 'dart:convert';

import '../utils/darktunnel_codec.dart';

/// Fixed local port the payload injector binds to when fronting a V2Ray
/// (vmess/vless/trojan/ss) outbound. xray is pointed at 127.0.0.1:<this> and
/// the injector relays to the real server (sending the HTTP payload first).
const int kInjectLocalPort = 8089;

enum ProtocolType { vless, vmess, trojan, shadowsocks, ssh, sshDnstt, openvpn, wireguard, socks, httpProxy, psiphon, hysteria }

enum TransportType { tcp, ws, grpc, xhttp, httpUpgrade, mkcp }

/// xray streamSettings `network` wire name — xray expects lowercase
/// 'httpupgrade' and 'kcp' while the enum names differ.
extension TransportTypeX on TransportType {
  String get wireName => switch (this) {
        TransportType.httpUpgrade => 'httpupgrade',
        TransportType.mkcp => 'kcp',
        _ => name,
      };

  String get label => switch (this) {
        TransportType.tcp => 'TCP',
        TransportType.ws => 'WS',
        TransportType.grpc => 'gRPC',
        TransportType.xhttp => 'XHTTP',
        TransportType.httpUpgrade => 'HTTP-Upg',
        TransportType.mkcp => 'mKCP',
      };
}

enum SecurityType { none, tls, reality }

/// HTTP request-header injection mode (the injector-app share modes).
enum InjectMode { none, direct, directSni, proxy, proxySni, dnstt }

/// Wire value for the SquidProxy/SquidPort row that means "dial the SELECTED
/// server's own host as the squid / bug / front host on port 80" — what the
/// admin panel renders as `[Default]`. Blank stays blank: that catches broken
/// imports instead of silently turning every missing proxy host into a relay.
const String kDefaultProxyHost = '[Default]';

/// Default squid port used when `injectPort`/`squidPort` is blank (the panel
/// shows `80` as its placeholder).
const String kDefaultProxyPort = '80';

class ServerConfig {
  final String id;
  final String name;
  final String note;
  final ProtocolType protocol;
  final TransportType transport;
  final SecurityType security;
  final String address;
  final int port;
  final String uuid;
  final String? alterId;
  final String? password;
  final String? encryption;
  final String? sni;
  final String? path;
  final String? host;
  final String? serviceName;
  final String? fingerprint;
  final String? flow;
  final String? publicKey;
  final String? shortId;
  final bool isOfficial;
  final String? logoBase64;

  /// Hosted logo image URL (imgbb upload from the admin panel). Wins over
  /// [logoBase64] — no bundle-size limit and cacheable by the network stack.
  final String? logoUrl;
  final String? payload;
  final String? sshUser;
  final String? sshPass;
  final String? injectHost;
  final String? injectPort;
  final String? injectPayload;
  final InjectMode injectMode;
  // SSH-through-DNSTT (SlowDNS) settings.
  final String? dnsttServer; // dnstt server name
  final String? dnsttKey; // dnstt server public key
  final String? dnsttResolver; // upstream UDP DNS resolver host:port
  final String? ovpnConfig; // raw .ovpn file contents (OpenVPN)
  final String? wireguardConfig; // wg.conf contents (WireGuard)
  final String? psiphonRegion; // Psiphon region hint (US/GB/DE/JP/SG)
  final bool payloadEnhanced; // SSH "enhanced" payload split mode
  final bool sshCompression; // SSH zlib compression (SSH enhance option)
  final String
      category; // global/gaming/streaming/facebook/youtube/telegram/...
  final String? country; // ISO 3166-1 alpha-2 code for flag display (BD/SG…)
  final String? region; // free-form region/city label ("Tokyo", "BDIX")
  final String? server; // logical server grouping label (one host, many payload/SNI)

  /// Capability type marker ([SNI], [PROXY+PAYLOAD]…) — what kind of method
  /// this config is. Compatibility with servers is derived from this.
  final String? capability;

  /// Every capability marker this node supports (mirror of the panel's
  /// `capabilities[]`). A multi-cap server shows up under each of its types
  /// ([SNI] + [DIRECT] + …); empty on legacy feeds that only carry the
  /// singular [capability].
  final List<String> capabilities;

  /// Does this node support capability key [raw]? Checks the full
  /// [capabilities] set first, then the singular [capability] marker.
  bool supportsCapability(String raw) {
    final key = capabilityKey(raw);
    if (key.isEmpty) return false;
    if (capabilityKey(capability ?? '') == key) return true;
    return capabilities.any((c) => capabilityKey(c) == key);
  }

  /// Official anchor server id a tweak rides (the panel's preferred-anchor
  /// rule). Resolution prefers this server, then falls back to the first
  /// compatible one when the panel removed it.
  final String? anchorId;

  /// Riding family declared by the panel tweak (`family` field). 'mixed'/'*'
  /// means the tweak rides compatible servers of EVERY protocol family;
  /// null/empty falls back to the tweak's own protocol family.
  final String? tweakFamily;

  /// Failover pool: alternate compatible servers as ready-to-join endpoint
  /// JSON (subset of ServerConfig.toJson). The app walks it when the anchor
  /// endpoint fails — one dead server never kills the tweak.
  final List<Map<String, dynamic>> serverPool;

  final bool isCustom;
  final String? rawConfig;
  final String? author;
  final String? encryptionKey;
  final bool locked;
  final String? lockMessage;
  final int? expiresAt;

  /// VIP server: the app gate-keeps it behind a rewarded ad. `vipUnlockHours`
  /// controls the duration minted by a rewarded unlock. The `vault` id, when
  /// non-null, means its endpoint is resolved server-side at connect time via
  /// the encrypted bundle (the public admin payload redacts the real
  /// `address`/`port` for vault-only VIP configs). `vipNote` is the admin's
  /// optional line shown on the unlock sheet.
  final bool vip;
  final int? vipUnlockHours;
  final String? vipNote;
  final String? vault;

  const ServerConfig({
    required this.id,
    required this.name,
    this.note = '',
    required this.protocol,
    this.transport = TransportType.tcp,
    this.security = SecurityType.none,
    required this.address,
    required this.port,
    this.uuid = '',
    this.alterId,
    this.password,
    this.encryption,
    this.sni,
    this.path,
    this.host,
    this.serviceName,
    this.fingerprint,
    this.flow,
    this.publicKey,
    this.shortId,
    this.isOfficial = false,
    this.logoBase64,
    this.logoUrl,
    this.payload,
    this.sshUser,
    this.sshPass,
    this.injectHost,
    this.injectPort,
    this.injectPayload,
    this.injectMode = InjectMode.none,
    this.dnsttServer,
    this.dnsttKey,
    this.dnsttResolver,
    this.ovpnConfig,
    this.wireguardConfig,
    this.psiphonRegion,
    this.payloadEnhanced = false,
    this.sshCompression = false,
    this.category = 'global',
this.capability,
    this.capabilities = const [],
    this.anchorId,
    this.tweakFamily,
    this.serverPool = const [],
    this.country,
    this.region,
    this.server,
    this.isCustom = false,
    this.rawConfig,
    this.author,
    this.encryptionKey,
    this.locked = false,
    this.lockMessage,
    this.expiresAt,
    this.vip = false,
    this.vipUnlockHours,
    this.vipNote,
    this.vault,
  });

  String get displayName => name.isNotEmpty ? name : note;

  /// True when an admin-set expiry has passed (or was set in the past).
  bool get isExpired =>
      expiresAt != null && expiresAt! > 0 && expiresAt! < DateTime.now().millisecondsSinceEpoch;

  /// Locked nodes and expired nodes are both un-connectable.
  bool get isBlocked => locked || isExpired;

  /// True when this node is admin-marked VIP (rewarded-ad gate on device).
  bool get isVip => vip;

  /// How long ONE watched ad unlocks a VIP node (default 2 hours).
  Duration get vipUnlockDuration => Duration(hours: vipUnlockHours ?? 2);

  /// Human reason shown when a blocked node is tapped.
  String get blockedReason {
    if (locked) return lockMessage?.isNotEmpty == true ? lockMessage! : 'Locked by admin';
    return 'This tunnel expired on '
        '${DateTime.fromMillisecondsSinceEpoch(expiresAt!).toLocal()}';
  }

  /// Generic copy preserving every field — editing must never silently drop
  /// credentials or keys (the old code rebuilt configs by hand and lost
  /// reality/XTLS/gRPC/inject fields on every "Edit").
  ServerConfig copyWith({
    String? id,
    String? name,
    String? note,
    ProtocolType? protocol,
    TransportType? transport,
    SecurityType? security,
    String? address,
    int? port,
    String? uuid,
    String? alterId,
    String? password,
    String? encryption,
    String? sni,
    String? path,
    String? host,
    String? serviceName,
    String? fingerprint,
    String? flow,
    String? publicKey,
    String? shortId,
    bool? isOfficial,
    String? logoBase64,
    String? logoUrl,
    String? payload,
    String? sshUser,
    String? sshPass,
    String? injectHost,
    String? injectPort,
    String? injectPayload,
    InjectMode? injectMode,
    String? dnsttServer,
    String? dnsttKey,
    String? dnsttResolver,
    String? ovpnConfig,
    bool? payloadEnhanced,
    bool? sshCompression,
    String? wireguardConfig,
    String? psiphonRegion,
    String? category,
    String? capability,
    List<String>? capabilities,
    String? anchorId,
    String? tweakFamily,
    List<Map<String, dynamic>>? serverPool,
    String? country,
    String? region,
    String? server,
    bool? isCustom,
    String? rawConfig,
    String? author,
    String? encryptionKey,
    bool? locked,
    String? lockMessage,
    int? expiresAt,
    bool? vip,
    int? vipUnlockHours,
    String? vipNote,
    String? vault,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      note: note ?? this.note,
      protocol: protocol ?? this.protocol,
      transport: transport ?? this.transport,
      security: security ?? this.security,
      address: address ?? this.address,
      port: port ?? this.port,
      uuid: uuid ?? this.uuid,
      alterId: alterId ?? this.alterId,
      password: password ?? this.password,
      encryption: encryption ?? this.encryption,
      sni: sni ?? this.sni,
      path: path ?? this.path,
      host: host ?? this.host,
      serviceName: serviceName ?? this.serviceName,
      fingerprint: fingerprint ?? this.fingerprint,
      flow: flow ?? this.flow,
      publicKey: publicKey ?? this.publicKey,
      shortId: shortId ?? this.shortId,
      isOfficial: isOfficial ?? this.isOfficial,
      logoBase64: logoBase64 ?? this.logoBase64,
      logoUrl: logoUrl ?? this.logoUrl,
      payload: payload ?? this.payload,
      sshUser: sshUser ?? this.sshUser,
      sshPass: sshPass ?? this.sshPass,
      injectHost: injectHost ?? this.injectHost,
      injectPort: injectPort ?? this.injectPort,
      injectPayload: injectPayload ?? this.injectPayload,
      injectMode: injectMode ?? this.injectMode,
      dnsttServer: dnsttServer ?? this.dnsttServer,
      dnsttKey: dnsttKey ?? this.dnsttKey,
      dnsttResolver: dnsttResolver ?? this.dnsttResolver,
      ovpnConfig: ovpnConfig ?? this.ovpnConfig,
      wireguardConfig: wireguardConfig ?? this.wireguardConfig,
      psiphonRegion: psiphonRegion ?? this.psiphonRegion,
      payloadEnhanced: payloadEnhanced ?? this.payloadEnhanced,
      sshCompression: sshCompression ?? this.sshCompression,
      category: category ?? this.category,
      capability: capability ?? this.capability,
      capabilities: capabilities ?? this.capabilities,
      anchorId: anchorId ?? this.anchorId,
      tweakFamily: tweakFamily ?? this.tweakFamily,
      serverPool: serverPool ?? this.serverPool,
      country: country ?? this.country,
      region: region ?? this.region,
      server: server ?? this.server,
      isCustom: isCustom ?? this.isCustom,
      rawConfig: rawConfig ?? this.rawConfig,
      author: author ?? this.author,
      encryptionKey: encryptionKey ?? this.encryptionKey,
      locked: locked ?? this.locked,
      lockMessage: lockMessage ?? this.lockMessage,
      expiresAt: expiresAt ?? this.expiresAt,
      vip: vip ?? this.vip,
      vipUnlockHours: vipUnlockHours ?? this.vipUnlockHours,
      vipNote: vipNote ?? this.vipNote,
      vault: vault ?? this.vault,
    );
  }

  String get displayAddress {
    if (isOfficial) return '';
    return '$address:$port';
  }

  String get protocolLabel {
    switch (protocol) {
      case ProtocolType.vless:
        return 'VLESS';
      case ProtocolType.vmess:
        return 'VMess';
      case ProtocolType.trojan:
        return 'Trojan';
      case ProtocolType.shadowsocks:
        return 'SS';
      // Both SSH flavours are "SSH" — the DNSTT variant is told apart by its
      // UDP transport + DNSTT method badges.
      case ProtocolType.ssh:
      case ProtocolType.sshDnstt:
        return 'SSH';
      case ProtocolType.openvpn:
        return 'OVPN';
      case ProtocolType.wireguard:
        return 'WG';
      case ProtocolType.socks:
        return 'SOCKS5';
      case ProtocolType.httpProxy:
        return 'HTTP';
      case ProtocolType.psiphon:
        return 'PSIPHON';
      case ProtocolType.hysteria:
        return 'Hysteria';
    }
  }

  /// True for modes handled by the native SSH engine (not xray).
  bool get isSshFamily =>
      protocol == ProtocolType.ssh || protocol == ProtocolType.sshDnstt;

  /// True for the xray-driven V2Ray protocols.
  bool get isV2rayFamily =>
      protocol == ProtocolType.vless ||
      protocol == ProtocolType.vmess ||
      protocol == ProtocolType.trojan ||
      protocol == ProtocolType.shadowsocks;

  /// True for standalone proxy protocols (SOCKS5, HTTP proxy).
  bool get isProxyFamily =>
      protocol == ProtocolType.socks || protocol == ProtocolType.httpProxy;

  /// The failover candidates for this config: every alternate compatible
  /// server from the admin's pool, joined onto THIS config's method fields
  /// (payload/SNI/etc. stay ours; the endpoint comes from the pool entry).
  /// Anchor failures walk this list — one dead server never kills a tweak.
  /// The failover candidates for this config: every alternate compatible
  /// server from the admin's pool, joined onto THIS config's method fields
  /// (payload/SNI/etc. stay ours; endpoint + credentials + engine shape
  /// come from the pool entry — a full join, not just the address).
  /// Anchor failures walk this list — one dead server never kills a tweak.
  List<ServerConfig> get failoverCandidates => serverPool
      .map((e) => copyWith(
            id: e['id']?.toString() ?? id,
            address: e['address']?.toString() ?? address,
            port: parsePort(e['port'], port),
            server: e['name']?.toString() ?? server,
            protocol: parseProtocol(e['protocol'] ?? protocol.name),
            transport: parseTransport(e['transport'] ?? transport.name),
            security: parseSecurity(e['security'] ?? security.name),
            uuid: e['uuid']?.toString() ?? uuid,
            password: e['password']?.toString() ?? password,
            encryption: e['encryption']?.toString() ?? encryption,
            alterId: e['alterId']?.toString() ?? alterId,
            host: e['host']?.toString() ?? host,
            path: e['path']?.toString() ?? path,
            serviceName: e['serviceName']?.toString() ?? serviceName,
            fingerprint: e['fingerprint']?.toString() ?? fingerprint,
            flow: e['flow']?.toString() ?? flow,
            publicKey: e['publicKey']?.toString() ?? publicKey,
            shortId: e['shortId']?.toString() ?? shortId,
            sshUser: e['sshUser']?.toString() ?? sshUser,
            sshPass: e['sshPass']?.toString() ?? sshPass,
            dnsttServer: e['dnsttServer']?.toString() ?? dnsttServer,
            dnsttKey: e['dnsttKey']?.toString() ?? dnsttKey,
            dnsttResolver: e['dnsttResolver']?.toString() ?? dnsttResolver,
            ovpnConfig: e['ovpnConfig']?.toString() ?? ovpnConfig,
          ))
      .toList();

  /// Parse the admin feed's serverPool entries (list of endpoint maps).
  static List<Map<String, dynamic>> _parseServerPool(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
        .toList();
  }

  /// Whether the selected inject-mode fronts the SELECTED server's OWN host
  /// as the squid / bug / front host (port 80) instead of a separate bug host.
  /// True when a proxy/proxySni inject mode is on and `injectHost`/`squidProxy`
  /// is the literal `[Default]` marker (see [kDefaultProxyHost]). Blank is not
  /// accepted here; importers that mean default must store the marker.
  bool get injectProxyIsDefault {
    if (injectMode != InjectMode.proxy && injectMode != InjectMode.proxySni) {
      return false;
    }
    final String h = (injectHost ?? '').trim();
    return h.toLowerCase() == kDefaultProxyHost.toLowerCase();
  }

  /// Dial-through bug / squid / front host actually used at runtime. When
  /// [injectProxyIsDefault], this is the SELECTED (runtime) server host
  /// ([address], falling back to [injectHost]) — otherwise the configured
  /// [injectHost]. The native engine reads this value, so a config that
  /// carries the `[Default]` marker still gets a real dial host.
  String get effectiveInjectHost {
    if (injectProxyIsDefault) {
      final String server = address.trim();
      if (server.isNotEmpty) return server;
    }
    return (injectHost ?? '').trim();
  }

  /// Dial-through bug / squid / front PORT used at runtime. When
  /// [injectProxyIsDefault] (or `injectPort` is blank) this is port 80 —
  /// see [kDefaultProxyPort].
  String get effectiveInjectPort {
    final String p = (injectPort ?? '').trim();
    if (injectProxyIsDefault) return kDefaultProxyPort;
    if (p.isEmpty &&
        (injectMode == InjectMode.proxy || injectMode == InjectMode.proxySni)) {
      return kDefaultProxyPort;
    }
    return p;
  }

  /// Whether this V2Ray config should be fronted by the local payload injector
  /// (HTTP payload / bug-host proxy for DPI bypass). TLS/SNI is still handled by
  /// xray itself, so the injector only relays — it does not wrap TLS here.
  ///
  /// An explicit `direct`/`directSni` mode is always honoured: with a blank
  /// payload the injector sends a fake-response opener (`HTTP/1.1 200 OK`),
  /// which is exactly what v2rayinject.py-style servers expect. The proxy modes
  /// additionally need a bug host to dial through; and any non-empty payload
  /// enables injection on its own.
  ///
  /// WS works too (verified on the wire against v2rayinject.py): the front
  /// answers the payload with a FAKE 101, then xray's real WS handshake —
  /// carrying the backend's actual path — passes through and gets the real
  /// 101 from the backend. The path is therefore critical: an empty/ wrong
  /// path makes the backend answer 404 after the payload's fake 101.
  bool get v2rayInjectActive {
    if (!isV2rayFamily) return false;
    final bool hasPayload = (payload ?? '').trim().isNotEmpty;
    final bool explicitDirect =
        injectMode == InjectMode.direct || injectMode == InjectMode.directSni;
    final bool isProxyMode =
        injectMode == InjectMode.proxy || injectMode == InjectMode.proxySni;
    if (isProxyMode && effectiveInjectHost.isNotEmpty) return true;
    if (hasPayload) return true;
    return explicitDirect;
  }

  /// Whether the native PayloadInjector renders this config's payload on the
  /// wire at connect time. Mirrors the Kotlin `useInject` conditions:
  ///   - SSH family: injector fronts the stream whenever an inject mode is
  ///     selected (only `none`/`dnstt` skip it — and dnstt still composes
  ///     with the injector fronting the local dnstt endpoint).
  ///   - V2Ray: exactly [v2rayInjectActive] (xray dials the local relay).
  ///   - OpenVPN: the injector fronts the profile for any inject mode; when
  ///     the engine ends up skipping it (UDP profile, own http-proxy) the
  ///     payload is unused anyway, so the answer stays safe.
  ///
  /// When true, wire markers in the payload ([host]/[port]/[ua]/[crlf]…)
  /// must be left for the injector — its `[host]` is the FRONT (bug/SNI)
  /// host, not the real server address.
  bool get nativeInjectsPayload {
    switch (protocol) {
      case ProtocolType.ssh:
      case ProtocolType.sshDnstt:
      case ProtocolType.openvpn:
        return injectMode != InjectMode.none && injectMode != InjectMode.dnstt;
      case ProtocolType.vless:
      case ProtocolType.vmess:
      case ProtocolType.trojan:
      case ProtocolType.shadowsocks:
        return v2rayInjectActive;
      case ProtocolType.wireguard:
      case ProtocolType.socks:
      case ProtocolType.httpProxy:
      case ProtocolType.psiphon:
      case ProtocolType.hysteria:
        return false;
    }
  }

  /// Transport badge: the wire the tunnel rides.
  ///   SSH → TCP (DNSTT variant → UDP, it travels inside DNS queries)
  ///   OVPN → the profile's own `proto tcp|udp` (default udp, as OpenVPN does)
  ///   V2ray → TCP / WS / gRPC
  String get transportLabel {
    switch (protocol) {
      case ProtocolType.ssh:
        return 'TCP';
      case ProtocolType.sshDnstt:
        return 'UDP';
      case ProtocolType.openvpn:
        final m = RegExp(
          r'^\s*proto\s+(tcp|udp)',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(ovpnConfig ?? '');
        return ((m?.group(1) ?? 'udp').toLowerCase() == 'tcp') ? 'TCP' : 'UDP';
      case ProtocolType.vless:
      case ProtocolType.vmess:
      case ProtocolType.trojan:
      case ProtocolType.shadowsocks:
        return transport.label;
      case ProtocolType.wireguard:
        return 'UDP';
      case ProtocolType.socks:
      case ProtocolType.httpProxy:
      case ProtocolType.psiphon:
        return 'TCP';
      case ProtocolType.hysteria:
        return 'UDP';
    }
  }

  /// Method badge — the tweak's DPI-bypass ticks, compound:
  ///   SNI / Payload / Proxy / SNI+Payload / Proxy+Payload /
  ///   SNI+Proxy+Payload / DNSTT
  /// Driven by what the admin actually ticked (injectMode + payload), so it
  /// mirrors the panel's Tweaks form 1:1. Empty = plain connection.
  String get methodLabel {
    if (protocol == ProtocolType.sshDnstt || injectMode == InjectMode.dnstt) {
      return 'DNSTT';
    }
    final bool hasSni =
        injectMode == InjectMode.directSni || injectMode == InjectMode.proxySni;
    final bool isProxy =
        injectMode == InjectMode.proxy || injectMode == InjectMode.proxySni;
    final bool hasPayload = (payload ?? '').trim().isNotEmpty;
    final parts = <String>[
      if (hasSni) 'SNI',
      if (isProxy) 'Proxy',
      if (hasPayload) 'Payload',
    ];
    return parts.join('+');
  }

  /// Hysteria 2 client config (native exec, SOCKS5 mode on [socksPort] —
  /// tun2socks routes the TUN through it exactly like xray). Field names match
  /// the app/v2 clientConfig mapstructure tags.
  String toHysteriaConfig(int socksPort, {bool hotspotShare = true}) {
    final listen =
        hotspotShare ? '0.0.0.0:$socksPort' : '127.0.0.1:$socksPort';
    final serverAddr = address.trim().isNotEmpty
        ? address
        : effectiveInjectHost; // blank address = dial through the front
    final server = '$serverAddr:$port';
    final insecure = (sni ?? '').trim().isEmpty;
    return jsonEncode(<String, dynamic>{
      'server': server,
      if ((password ?? '').isNotEmpty) 'auth': password,
      'tls': {
        if (!insecure) 'sni': sni,
        'insecure': insecure,
      },
      'socks5': {'listen': listen, 'disableUDP': false},
      'lazy': true,
    });
  }

  /// Generate xray-core JSON config for this server
  String toXrayConfig(int socksPort, String tunMode,
      {List<Map<String, String>> routeRules = const [],
      bool muxEnabled = false,
      bool tlsFragment = false,
      bool hotspotShare = true,
      List<String> dnsServers = const <String>['8.8.8.8', '8.8.4.4', '1.1.1.1']}) {
    final Map<String, dynamic> config = {
      'log': {
        'loglevel': 'warning',
      },
      'dns': {
        // The SAME ordered resolver list the TUN hands Android — the two
        // layers must agree, or xray resolves through a resolver the TUN
        // never offers (and vice versa). Google-first default; the user's
        // list (Settings → DNS) rides in from vpn_service.
        'servers': [
          for (final dns in dnsServers)
            {'address': dns, 'skipFallback': true},
        ],
        // IPv4-only resolution: an AAAA answer made the exit dial IPv6, so the
        // public-IP check showed an IPv6 address (injector apps resolve v4 —
        // match that behaviour).
        'queryStrategy': 'UseIPv4',
      },
      'inbounds': [
        {
          // 0.0.0.0 (hotspot share) so hotspot clients can use the proxy at
          // <phone-ip>:port; 127.0.0.1 when sharing is off (app-only).
          'port': socksPort,
          'listen': hotspotShare ? '0.0.0.0' : '127.0.0.1',
          'protocol': 'socks',
          'settings': {
            'udp': true,
            'auth': 'noauth',
          },
          'tag': 'socks-in',
        },
        {
          'port': socksPort + 1,
          'listen': hotspotShare ? '0.0.0.0' : '127.0.0.1',
          'protocol': 'http',
          'settings': {},
          'tag': 'http-in',
        },
      ],
      'outbounds': _buildOutbounds(routeRules,
          muxEnabled: muxEnabled, tlsFragment: tlsFragment),
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        // User rules are evaluated first (first match wins in xray), then the
        // catch-all that sends everything else through the proxy.
        'rules': [
          ..._buildRouteRules(routeRules),
          {
            'type': 'field',
            'inboundTag': ['socks-in', 'http-in'],
            'outboundTag': 'proxy',
          },
        ],
      },
    };

    return jsonEncode(config);
  }

  /// Proxy outbound, plus `direct`/`block` outbounds when route rules need them.
  List<Map<String, dynamic>> _buildOutbounds(
    List<Map<String, String>> routeRules, {
    bool muxEnabled = false,
    bool tlsFragment = false,
  }) {
    final outbounds = <Map<String, dynamic>>[
      _buildOutbound(muxEnabled: muxEnabled, tlsFragment: tlsFragment)
    ];
    if (_useTlsFragment(tlsFragment)) {
      outbounds.add(fragmentOutbound());
    }
    final actions = routeRules.map((r) => _normalizeRouteAction(r['action']));
    if (actions.contains('direct')) {
      outbounds.add({'protocol': 'freedom', 'tag': 'direct'});
    }
    if (actions.contains('block')) {
      outbounds.add({'protocol': 'blackhole', 'tag': 'block'});
    }
    return outbounds;
  }

  /// Translate user route rules into xray routing rules. A value that parses as
  /// an IP / CIDR becomes an `ip` rule; anything else is treated as a domain.
  List<Map<String, dynamic>> _buildRouteRules(
      List<Map<String, String>> routeRules) {
    // Group by (action, kind) so we emit one compact rule per bucket.
    final domains = <String, List<String>>{'direct': [], 'block': []};
    final ips = <String, List<String>>{'direct': [], 'block': []};
    for (final r in routeRules) {
      final action = _normalizeRouteAction(r['action']);
      final value = (r['value'] ?? '').trim();
      if (value.isEmpty) continue;
      if (_looksLikeIp(value)) {
        ips[action]!.add(value);
      } else {
        domains[action]!.add(value);
      }
    }
    final rules = <Map<String, dynamic>>[];
    for (final action in ['direct', 'block']) {
      if (domains[action]!.isNotEmpty) {
        rules.add({
          'type': 'field',
          'domain': domains[action],
          'outboundTag': action,
        });
      }
      if (ips[action]!.isNotEmpty) {
        rules.add({
          'type': 'field',
          'ip': ips[action],
          'outboundTag': action,
        });
      }
    }
    return rules;
  }

  static String _normalizeRouteAction(String? action) =>
      action == 'block' ? 'block' : 'direct';

  /// True for a bare IPv4/IPv6 address, a CIDR, or an xray `geoip:` selector.
  static bool _looksLikeIp(String v) {
    if (v.startsWith('geoip:')) return true;
    if (v.startsWith('geosite:')) return false;
    final host = v.contains('/') ? v.substring(0, v.indexOf('/')) : v;
    if (host.contains(':')) {
      final parts = host.split(':');
      return parts.length >= 3 &&
          parts.every((p) => p.isEmpty || int.tryParse(p, radix: 16) != null);
    }
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }

  Map<String, dynamic> _buildOutbound(
      {bool muxEnabled = false, bool tlsFragment = false}) {
    final Map<String, dynamic> outbound = {
      'tag': 'proxy',
    };

    // When the injector fronts this V2Ray outbound, xray dials the local relay
    // instead of the server. Stream settings (TLS/SNI/WS host) stay pointed at
    // the real server so the handshake/SNI is unchanged.
    final String dialAddress = v2rayInjectActive ? '127.0.0.1' : address;
    final int dialPort = v2rayInjectActive ? kInjectLocalPort : port;

    // TCP multiplexing (real xray feature): many streams share one connection
    // to the server. Off by default — some servers dislike it.
    if (muxEnabled && isV2rayFamily) {
      outbound['mux'] = {'enabled': true, 'concurrency': 8};
    }

    // TLS hello fragmentation routes the proxy's own dial through a freedom
    // outbound that splits the ClientHello into small chunks (real xray
    // `sockopt.dialerProxy` + `fragment`, not a cosmetic toggle).
    if (_useTlsFragment(tlsFragment)) {
      final stream =
          (outbound['streamSettings'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final sockopt = (stream['sockopt'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      sockopt['dialerProxy'] = kFragmentOutboundTag;
      stream['sockopt'] = sockopt;
      outbound['streamSettings'] = stream;
    }

    switch (protocol) {
      case ProtocolType.hysteria:
        throw UnsupportedError('hysteria does not use an xray config');
      case ProtocolType.vless:
        outbound['protocol'] = 'vless';
        outbound['settings'] = {
          'vnext': [
            {
              'address': dialAddress,
              'port': dialPort,
              'users': [
                {
                  'id': uuid,
                  'encryption': encryption ?? 'none',
                  if (flow != null) 'flow': flow,
                },
              ],
            },
          ],
        };
        outbound['streamSettings'] = _buildStreamSettings();
        break;

      case ProtocolType.vmess:
        outbound['protocol'] = 'vmess';
        outbound['settings'] = {
          'vnext': [
            {
              'address': dialAddress,
              'port': dialPort,
              'users': [
                {
                  'id': uuid,
                  'alterId': alterId != null ? int.tryParse(alterId!) ?? 0 : 0,
                  'security': encryption ?? 'auto',
                },
              ],
            },
          ],
        };
        outbound['streamSettings'] = _buildStreamSettings();
        break;

      case ProtocolType.trojan:
        outbound['protocol'] = 'trojan';
        outbound['settings'] = {
          'servers': [
            {
              'address': dialAddress,
              'port': dialPort,
              'password': password ?? uuid,
            },
          ],
        };
        outbound['streamSettings'] = _buildStreamSettings();
        break;

      case ProtocolType.shadowsocks:
        outbound['protocol'] = 'shadowsocks';
        outbound['settings'] = {
          'servers': [
            {
              'address': dialAddress,
              'port': dialPort,
              'method': encryption ?? 'aes-256-gcm',
              'password': password ?? uuid,
            },
          ],
        };
        break;

      case ProtocolType.ssh:
      case ProtocolType.sshDnstt:
      case ProtocolType.openvpn:
      case ProtocolType.wireguard:
      case ProtocolType.socks:
      case ProtocolType.httpProxy:
      case ProtocolType.psiphon:
        // These modes do not use xray. The native engine drives the local
        // SOCKS/TUN directly; this placeholder keeps the JSON valid and
        // routable (the routing rules reference the `proxy` tag, so the tag
        // must stay `proxy` — a `ssh-proxy` tag made the config invalid).
        outbound['protocol'] = 'freedom';
        outbound['settings'] = {};
        break;
    }

    return outbound;
  }

  /// Tag of the helper freedom outbound used for TLS fragmentation.
  static const String kFragmentOutboundTag = 'sensei-fragment';

  /// Fragmentation only makes sense for xray TLS/REALITY outbounds that dial
  /// the real server directly — never when the local payload injector fronts
  /// the connection (that dial is plain HTTP to 127.0.0.1).
  bool _useTlsFragment(bool enabled) =>
      enabled && isV2rayFamily && security != SecurityType.none && !v2rayInjectActive;

  /// The freedom outbound that actually performs the ClientHello splitting.
  Map<String, dynamic> fragmentOutbound() => {
        'tag': kFragmentOutboundTag,
        'protocol': 'freedom',
        'settings': {
          'domainStrategy': 'AsIs',
          'fragment': {
            'packets': 'tlshello',
            'length': '100-200',
            'interval': '10-20',
          },
        },
      };

  Map<String, dynamic> _buildStreamSettings() {
    final Map<String, dynamic> stream = {
      'network': transport.wireName,
    };

    // With the injector fronting the outbound, xray dials 127.0.0.1 — so the
    // TLS SNI and the WS Host header must be pinned explicitly, otherwise xray
    // derives them from the dial address and sends "127.0.0.1".
    final String effectiveSni =
        (sni != null && sni!.isNotEmpty) ? sni! : (host ?? address);
    final String effectiveHost =
        (host != null && host!.isNotEmpty) ? host! : (sni ?? address);

    switch (security) {
      case SecurityType.tls:
        stream['security'] = 'tls';
        stream['tlsSettings'] = {
          'allowInsecure': true,
          if (sni != null || v2rayInjectActive) 'serverName': effectiveSni,
          'fingerprint': fingerprint ?? 'chrome',
        };
        break;
      case SecurityType.reality:
        stream['security'] = 'reality';
        stream['realitySettings'] = {
          'serverName': sni ?? (v2rayInjectActive ? effectiveSni : ''),
          if (publicKey != null) 'publicKey': publicKey,
          if (shortId != null) 'shortId': shortId,
          'fingerprint': fingerprint ?? 'chrome',
        };
        break;
      case SecurityType.none:
        stream['security'] = 'none';
        break;
    }

    switch (transport) {
      case TransportType.ws:
        stream['wsSettings'] = {
          if (path != null) 'path': path,
          if (host != null || v2rayInjectActive)
            'headers': {'Host': effectiveHost},
        };
        break;
      case TransportType.grpc:
        stream['grpcSettings'] = {
          if (serviceName != null) 'serviceName': serviceName,
        };
        break;
      case TransportType.xhttp:
      case TransportType.httpUpgrade:
        // Same path/host shape, different network key: xhttp = split-packet
        // HTTP (XHTTP), httpupgrade = plain upgrade request.
        stream[transport == TransportType.xhttp
            ? 'xhttpSettings'
            : 'httpupgradeSettings'] = {
          if (path != null) 'path': path,
          if (host != null || v2rayInjectActive) 'host': effectiveHost,
        };
        break;
      case TransportType.mkcp:
        // UDP-encapsulated fake-TCP. Bare kcpSettings (header none) uses
        // xray's own defaults for mtu/tti/capacity.
        stream['kcpSettings'] = {
          'header': {'type': 'none'},
        };
        break;
      case TransportType.tcp:
        // TCP fake-HTTP header. Skipped when the local injector is active: the
        // injector already writes the user's payload, and stacking xray's own
        // GET on top of it sends two requests down one stream.
        if (payload != null && payload!.isNotEmpty && !v2rayInjectActive) {
          stream['tcpSettings'] = {
            'header': {
              'type': 'http',
              'request': {
                'version': '1.1',
                'method': 'GET',
                'path': [path ?? '/'],
                // Every value here must be a JSON array — xray unmarshals
                // `headers` as map[string][]string and refuses to start on a
                // bare string.
                'headers': {
                  'Host': [host ?? address],
                  'User-Agent': [
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                  ],
                  'Accept-Encoding': ['gzip, deflate'],
                  'Connection': ['keep-alive'],
                  'Pragma': ['no-cache'],
                },
              },
            },
          };
        }
        break;
    }

    return stream;
  }

  /// Parse from darktunnel:// URI. Locked configs (the `encryptedLockedConfig`
  /// envelope of the DarkTunnel ecosystem) are decrypted here — with
  /// [lockPin] when the seller set a lock password.
  static ServerConfig? fromDarkTunnelUri(String uri, {String? lockPin}) {
    try {
      if (!uri.startsWith('darktunnel://')) return null;
      // Bulk shares glue commas/newlines/emoji onto the link — cut the
      // payload first, otherwise the base64 decode throws and EVERY type
      // reports as "not supported".
      final encoded = DarkTunnelCodec.b64Trim(
        uri.substring('darktunnel://'.length),
      );
      String decoded;
      try {
        decoded = Uri.decodeComponent(encoded);
      } catch (_) {
        decoded = encoded;
      }
      final jsonStr =
          utf8.decode(base64Url.decode(base64Url.normalize(decoded)));
      final Map<String, dynamic> data = jsonDecode(jsonStr);

      final dtype = (data['type'] ?? '').toString().toUpperCase();

      // ── Locked envelope: decrypt and merge the REAL fields over the
      // decoy tunnel config the format carries in the clear.
      DarkTunnelLock? lock;
      final hasLock = data['encryptedLockedConfig'] is String &&
          (data['encryptedLockedConfig'] as String).isNotEmpty;
      if (hasLock) {
        lock = DarkTunnelCodec.decode(uri);
        if (lock == null) return null; // undecryptable — refuse, don't guess
        if (lock.passwordRequired) {
          final pin = lockPin?.trim() ?? '';
          if (pin.isEmpty || !lock.checkPin(pin)) return null; // wrong PIN
        }
        if (!_applyDarkTunnelLock(data, lock)) return null;
        // Lock metadata travels with the config (display-only here).
        if (lock.message.isNotEmpty) data['lockMessage'] = lock.message;
        if (lock.expiresAtMs > 0) data['expiresAt'] = lock.expiresAtMs;
      }

      // Flatten nested structures for tunnel-share formats
      final sshTunnel = _tunnelSection(data, sshOnly: true);
      if (!hasLock &&
          (dtype == 'SSH' || dtype == 'SSH_DNSTT') &&
          sshTunnel != null) {
        data['protocol'] = dtype == 'SSH_DNSTT' ? 'ssh_dnstt' : 'ssh';
        final sshConfig = sshTunnel['sshConfig'] ?? {};
        final injectConfig = sshTunnel['injectConfig'] ?? {};
        final dnsttConfig = sshTunnel['dnsttConfig'] ?? {};
        data['host'] ??= sshConfig['host'];
        data['port'] ??= sshConfig['port'];
        data['sshUser'] ??= sshConfig['username'];
        data['sshPass'] ??= sshConfig['password'];
        data['injectMode'] ??= injectConfig['mode'];
        data['sni'] ??= injectConfig['serverNameIndication'];
        data['payload'] ??= injectConfig['payload'];
        data['injectHost'] ??= injectConfig['host'] ??
            injectConfig['proxyHost'] ??
            injectConfig['SquidProxy'] ??
            injectConfig['squidProxy'];
        data['injectPort'] ??=
            injectConfig['port'] ??
            injectConfig['proxyPort'] ??
            injectConfig['SquidPort'] ??
            injectConfig['squidPort'];
        // SSH_DNSTT (SlowDNS) fields.
        data['dnsttResolver'] ??= dnsttConfig['udpDnsHost'];
        data['dnsttServer'] ??= dnsttConfig['serverName'];
        data['dnsttKey'] ??= dnsttConfig['publicKey'];

        if (data["injectMode"] == null) {
          final hasSni =
              data["sni"] != null && data["sni"].toString().isNotEmpty;
          final hasProxy = data["injectHost"] != null &&
              data["injectHost"].toString().isNotEmpty;
          final hasPayload =
              data["payload"] != null && data["payload"].toString().isNotEmpty;
          final isPort80 = data["port"]?.toString() == "80";

          // Text shares often carry an SNI/bug-host string only for the
          // rendered HTTP payload header. Do not force TLS-wrapping modes unless
          // the share explicitly requested one, otherwise payload-only configs on
          // non-TLS SSH ports (143/22/8080/...) break.
          if (hasProxy && hasPayload) {
            data["injectMode"] = "proxy";
          } else if (hasProxy && hasSni && !isPort80) {
            data["injectMode"] = "proxysni";
          } else if (hasProxy) {
            data["injectMode"] = "proxy";
          } else if (hasPayload) {
            data["injectMode"] = "direct";
          } else if (hasSni && !isPort80) {
            data["injectMode"] = "directsni";
          }
        }
      } else if (!hasLock &&
          (dtype == 'VLESS' || dtype == 'VMESS' || dtype == 'TROJAN')) {
        final tunnel = _tunnelSection(data);
        if (tunnel != null) {
          data['protocol'] = dtype.toLowerCase();
          final v2ray = tunnel['v2rayConfig'] ?? {};
          final v2inject = tunnel['injectConfig'] ?? {};
          if (v2ray['host'] != null) data['address'] = v2ray['host'];
          data['host'] ??= v2ray['wsHeaderHost'] ?? v2ray['host'];
          data['wsHost'] ??= v2ray['wsHeaderHost'];
          data['port'] ??= v2ray['port'];
          data['uuid'] ??= v2ray['uuid'];

          // Transport comes from transportNetwork ONLY. Treating the share's
          // stray `wsPath` (meaningless on TCP) as WebSocket broke every
          // SSL-TCP import; it is now ignored outside ws/grpc.
          final netRaw = (v2ray['transportNetwork'] ??
                  v2ray['net'] ??
                  v2ray['network'] ??
                  '')
              .toString()
              .trim()
              .toLowerCase();
          final net = netRaw.isEmpty ? 'tcp' : netRaw;
          // Shared configs often OMIT transportNetwork and just carry
          // wsPath/wsHeaderHost — presence of a wsPath means WebSocket. Only
          // treat it as TCP when transportNetwork explicitly says so.
          final hasWsPath = (v2ray['wsPath']?.toString().isNotEmpty ?? false);
          final isWs = net == 'ws' || net == 'websocket' ||
              (netRaw.isEmpty && hasWsPath);
          final isGrpc = net == 'grpc';
          data['transport'] ??= isWs ? 'ws' : (isGrpc ? 'grpc' : 'tcp');
          final bool isTcp = !isWs && !isGrpc;

          // The share's `wsPath` is the WebSocket URL path (e.g. /@armantunnel).
          // It MUST map to `path` when the transport is ws/grpc — dropping it
          // made xray handshake with `GET /` and the backend answered 400.
          if (!isTcp) data['path'] ??= v2ray['wsPath'];

          data['sni'] ??= v2ray['serverNameIndication'];
          final bool hasSni =
              data['sni'] != null && data['sni'].toString().isNotEmpty;

          final bool? tlsFlag = v2ray['tls'];
          if (tlsFlag == true || (tlsFlag == null && hasSni)) {
            data['security'] ??= 'tls';
          }

          final bool injectEnabled = v2inject.isNotEmpty &&
              v2inject['enabled'] != false;
          final String? pl = v2inject['payload']?.toString();

          if (injectEnabled) {
            if (pl != null && pl.isNotEmpty) {
              data['payload'] ??= pl;
            }
            data['injectHost'] ??= v2inject['host'] ??
                v2inject['proxyHost'] ??
                v2inject['SquidProxy'] ??
                v2inject['squidProxy'];
            data['injectPort'] ??= v2inject['port'] ??
                v2inject['proxyPort'] ??
                v2inject['SquidPort'] ??
                v2inject['squidPort'];
            if (isTcp) {
              // SSL(TCP) = TLS + SNI wrap only. `wsPath` is meaningless on TCP
              // — a path there is NOT an opener and must never reach the
              // config (a TCP config with a path is an invalid config).
              data['injectMode'] ??= hasSni ? 'directsni' : 'direct';
            } else {
              // ws/grpc: honour the share's own mode (PROXY on a bug host
              // dials the front and sends the payload before the real WS
              // handshake — dropping it made every PROXY-mode import lose
              // its front).
              final mode = (v2inject['mode'] ?? '').toString();
              if (mode.isNotEmpty) data['injectMode'] ??= mode;
            }
          }
        }
      }

      return ServerConfig(
        id: data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: data['name'] ?? data['note'] ?? 'Imported',
        note: data['note'] ?? data['name'] ?? '',
        protocol: _parseProtocol(data['protocol'] ?? 'vless'),
        transport: _parseTransport(data['transport'] ?? 'tcp'),
        security: _parseSecurity(data['security'] ?? 'none'),
        address: data['address'] ?? data['host'] ?? '',
        port: _parsePort(data['port'], 443),
        uuid: data['uuid'] ?? data['id'] ?? data['password'] ?? '',
        alterId: data['alterId']?.toString() ?? data['aid']?.toString(),
        password: data['password'] ?? data['pass'],
        encryption: data['encryption'],
        sni: data['sni'],
        path: data['path'],
        host: data['host'] ??
            data['wsHost'] ??
            data['serverName'] ??
            data['serverNameIndication'],
        serviceName: data['serviceName'],
        fingerprint: data['fingerprint'],
        flow: data['flow'],
        publicKey: data['publicKey'],
        shortId: data['shortId'],
        isOfficial: data['isOfficial'] ?? false,
        logoBase64: data['logoBase64'],
        logoUrl: data['logoUrl'],
        payload: data['payload'] ?? data['ndkPayload'],
        sshUser: data['sshUser'] ?? data['user'] ?? data['username'],
        sshPass: data['sshPass'] ?? data['pass'] ?? data['password'],
        injectHost:
            data['injectHost'] ??
            data['proxyHost'] ??
            data['SquidProxy'] ??
            data['squidProxy'],
        injectPort:
            data['injectPort']?.toString() ??
            data['proxyPort']?.toString() ??
            data['SquidPort']?.toString() ??
            data['squidPort']?.toString(),
        injectPayload: data['injectPayload'],
        injectMode: _parseInjectMode(data['injectMode'] ?? data['mode']),
        dnsttServer: data['dnsttServer'] ?? data['dnsttServerName'],
        dnsttKey:
            data['dnsttKey'] ?? data['dnsttPublicKey'] ?? data['publicKey'],
        dnsttResolver: data['dnsttResolver'] ?? data['dnsttUdpDnsHost'],
        ovpnConfig: data['ovpnConfig'] ?? data['ovpn'],
        payloadEnhanced: data['payloadEnhanced'] == true,
        sshCompression: data['sshCompression'] == true,
        category: data['category'] ?? 'global',
        isCustom: true,
        // Locked imports keep the ORIGINAL share text: re-sharing the config
        // (via .st or .dark) re-exports the exact bytes the seller made.
        rawConfig: lock != null ? uri : jsonStr,
        author: data['author'],
        encryptionKey: data['encryptionKey'],
        locked: data['locked'] == true,
        lockMessage: data['lockMessage'],
        expiresAt: _parseNullableInt(data['expiresAt']),
      );
    } catch (e) {
      return null;
    }
  }

/// Find the `<type>TunnelConfig` section by STRUCTURE, not by key name.
  ///
  /// Sellers mutate the key before distributing a share — a live one from a
  /// user's Telegram batch decoded to `vlessAunnelConfig` (one letter swapped
  /// out of "Tunnel"), and an exact-name lookup silently returned null, so
  /// every field was dropped and the config imported blank (no address, no
  /// uuid) and could never connect. Matching on the *contents* means a
  /// renamed key imports exactly like the canonical spelling does.
  static Map<String, dynamic>? _tunnelSection(
    Map<String, dynamic> data, {
    bool sshOnly = false,
  }) {
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      // A tunnel section is a wrapper holding at least one inner section map.
      // `v2rayConfig` is VLESS/VMESS/TROJAN; the ssh trio is SSH/SSH_DNSTT.
      final hasV2ray = value['v2rayConfig'] is Map;
      final hasSsh = value['sshConfig'] is Map ||
          value['injectConfig'] is Map ||
          value['dnsttConfig'] is Map;
      if (sshOnly ? hasSsh : (hasV2ray || hasSsh)) {
        return Map<String, dynamic>.from(value);
      }
    }
    return null;
  }

  /// Merge a decrypted DarkTunnel lock envelope into the share's `data`
  /// map, overwriting the decoy fields. Returns false when the payload
  /// doesn't yield a usable endpoint.
  static bool _applyDarkTunnelLock(
      Map<String, dynamic> data, DarkTunnelLock lock) {
    final type = lock.tunnelType;
    if (type == 'SSH' || type == 'SSH_DNSTT') {
      final ssh = lock.sshConfig;
      final inj = lock.injectConfig;
      data['protocol'] = type == 'SSH_DNSTT' ? 'ssh_dnstt' : 'ssh';
      data['address'] = ssh['Host']?.toString() ?? '';
      data['port'] = ssh['Port'];
      data['sshUser'] = ssh['Username'];
      data['sshPass'] = ssh['Password'];
      final mode = inj['Mode']?.toString() ?? '';
      if (mode.isNotEmpty) data['injectMode'] = mode;
      final sni = inj['ServerNameIndication']?.toString() ?? '';
      if (sni.isNotEmpty) data['sni'] = sni;
      final payload = inj['Payload']?.toString() ?? '';
      if (payload.isNotEmpty) data['payload'] = payload;
      final proxyHost = inj['ProxyHost']?.toString() ?? '';
      if (proxyHost.isNotEmpty && proxyHost != 'localhost') {
        data['injectHost'] = proxyHost;
      } else {
        final squid = (inj['SquidProxy'] ?? inj['squidProxy'] ?? '').toString();
        if (squid.isNotEmpty) data['injectHost'] = squid;
      }
      final proxyPort = inj['ProxyPort']?.toString() ?? '';
      if (proxyPort.isNotEmpty && proxyPort != '8080') {
        data['injectPort'] = proxyPort;
      } else {
        final squidPort = (inj['SquidPort'] ?? inj['squidPort'] ?? '').toString();
        if (squidPort.isNotEmpty) data['injectPort'] = squidPort;
      }
      // DNStT (SlowDNS) fields — skip the format's stock defaults.
      final dnsHost = inj['DnsttDnsHost']?.toString() ?? '';
      final dnsPort = inj['DnsttDnsPort']?.toString() ?? '';
      if (dnsHost.isNotEmpty && dnsHost != '1.1.1.1') {
        data['dnsttResolver'] =
            dnsPort.isNotEmpty && dnsPort != '53' ? '$dnsHost:$dnsPort' : dnsHost;
      }
      final dnsttServer = inj['DnsttServerName']?.toString() ?? '';
      if (dnsttServer.isNotEmpty) data['dnsttServer'] = dnsttServer;
      final dnsttPubkey = inj['DnsttPubkey']?.toString() ?? '';
      if (dnsttPubkey.isNotEmpty) data['dnsttKey'] = dnsttPubkey;
      data['transport'] = 'tcp';
      data['security'] = 'none';
      if ((data['address'] as String?)?.isEmpty ?? true) return false;
      return true;
    }

    // VLESS / VMESS / TROJAN / V2RAY_CUSTOM_CONFIG — the whole xray
    // config rides as one JSON string inside the envelope.
    final cfgStr = lock.v2rayConfigJson;
    if (cfgStr == null || cfgStr.isEmpty) return false;
    Map<String, dynamic> xray;
    try {
      xray = jsonDecode(DarkTunnelCodec.sanitizeV2RayTemplate(cfgStr))
          as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    final outbounds = xray['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) return false;
    final ob = outbounds.first as Map;
    data['protocol'] = (ob['protocol'] ?? '').toString().toLowerCase();
    final settings = ob['settings'] as Map? ?? {};
    // vless/vmess carry `vnext`, trojan carries `servers`.
    final vnext = (settings['vnext'] as List?)?.firstOrNull as Map?;
    final servers = (settings['servers'] as List?)?.firstOrNull as Map?;
    final endpoint = vnext ?? servers;
    if (endpoint == null) return false;
    data['address'] = endpoint['address']?.toString() ?? '';
    data['port'] = endpoint['port'];
    final users = (endpoint['users'] as List?)?.firstOrNull as Map?;
    if (users != null) {
      data['uuid'] = users['id']?.toString() ?? '';
      final flow = users['flow']?.toString() ?? '';
      if (flow.isNotEmpty) data['flow'] = flow;
      final enc = users['encryption']?.toString() ?? '';
      if (enc.isNotEmpty) data['encryption'] = enc;
      final aid = users['alterId'];
      if (aid != null) data['alterId'] = aid.toString();
    } else {
      final pw = endpoint['password']?.toString() ?? '';
      if (pw.isEmpty) return false;
      data['uuid'] = pw; // trojan: password is the credential
      data['password'] = pw;
    }
    final ss = ob['streamSettings'] as Map? ?? {};
    data['transport'] = ss['network'] ?? 'tcp';
    final security = ss['security']?.toString() ?? 'none';
    data['security'] = security;
    if (security == 'tls' || security == 'reality') {
      final sni = ss['tlsSettings']?['serverName']?.toString() ??
          ss['realitySettings']?['serverName']?.toString() ??
          '';
      if (sni.isNotEmpty) data['sni'] = sni;
    }
    final path = ss['wsSettings']?['path']?.toString() ?? '';
    if (path.isNotEmpty) data['path'] = path;
    final wsHost =
        ss['wsSettings']?['headers']?['Host']?.toString() ?? '';
    if (wsHost.isNotEmpty) data['wsHost'] = wsHost;
    final svc = ss['grpcSettings']?['serviceName']?.toString() ?? '';
    if (svc.isNotEmpty) data['serviceName'] = svc;

    // The envelope's InjectConfig carries the REAL DPI front (mode/bug host/
    // payload) — the decoy only shows `{"mux":true}`. Without this merge every
    // locked VLESS/VMess/Trojan import lost its payload and front host.
    if (lock.v2rayConfig['IsInjectModeEnabled'] != false) {
      final inj = lock.injectConfig;
      final mode = (inj['Mode'] ?? '').toString();
      final payload = (inj['Payload'] ?? '').toString();
      final injSni = (inj['ServerNameIndication'] ?? '').toString();
      final proxyHost = (inj['ProxyHost'] ?? '').toString();
      final proxyPort = (inj['ProxyPort'] ?? '').toString();
      final transport = (data['transport'] ?? 'tcp').toString();
      if (transport == 'tcp') {
        // SSL(TCP) = TLS + SNI wrap only — no payload, no path (AGENTS rule,
        // mirrored in admin-panel/src/config-schema.js).
        data['injectMode'] =
            ((data['sni'] ?? '').toString().isNotEmpty) ? 'directsni' : 'direct';
        data.remove('payload');
      } else {
        if (payload.isNotEmpty) data['payload'] = payload;
        if (injSni.isNotEmpty && (data['sni'] ?? '').toString().isEmpty) {
          data['sni'] = injSni;
        }
        if (proxyHost.isNotEmpty && proxyHost != 'localhost') {
          data['injectHost'] = proxyHost;
        }
        if (proxyPort.isNotEmpty && proxyPort != '8080') {
          data['injectPort'] = proxyPort;
        }
        if (mode.isNotEmpty) data['injectMode'] = mode;
      }
    }

    if ((data['address'] as String?)?.isEmpty ?? true) return false;
    final uuid = data['uuid']?.toString() ?? '';
    final pass = data['password']?.toString() ?? '';
    if (uuid.isEmpty && pass.isEmpty) return false;
    return true;
  }

  /// Export as a DarkTunnel-compatible LOCKED `.dark` share
  /// (`darktunnel://…` with the `encryptedLockedConfig` envelope). Supports
  /// VLESS, VMESS and SSH (+DNStT) — the protocols the DarkTunnel format
  /// itself defines. Returns null for anything else (trojan/ss/openvpn).
  ///
  /// [password] becomes the config's lock password (asked on import in both
  /// DarkTunnel and here), [expiresAtMs] the expiry (epoch ms), [message] /
  /// [connectedMessage] the banners DarkTunnel shows before/after connect.
  String? toDarkTunnelLockedUri({
    String password = '',
    int? expiresAtMs,
    String message = '',
    String connectedMessage = '',
  }) {
    final expSec =
        expiresAtMs == null || expiresAtMs <= 0 ? 0 : expiresAtMs ~/ 1000;
    switch (protocol) {
      case ProtocolType.vless:
      case ProtocolType.vmess:
        final cfg = DarkTunnelCodec.buildV2RayTemplateJson(
          protocol: protocol.name,
          address: address,
          port: port,
          uuidStr: uuid,
          network: transport.name,
          security: security == SecurityType.tls ? 'tls' : 'none',
          wsPath: path ?? '',
          wsHost: host ?? '',
          tlsSni: sni ?? '',
          grpcService: serviceName ?? '',
          flow: flow ?? '',
        );
        return DarkTunnelCodec.encodeLocked(
          tunnelType: protocol.name.toUpperCase(),
          name: name,
          v2rayConfigJson: cfg,
          password: password,
          expiresAtSec: expSec,
          message: message,
          connectedMessage: connectedMessage,
        );
      case ProtocolType.ssh:
      case ProtocolType.sshDnstt:
        return DarkTunnelCodec.encodeLocked(
          tunnelType:
              protocol == ProtocolType.sshDnstt ? 'SSH_DNSTT' : 'SSH',
          name: name,
          sshHost: address,
          sshPort: port.toString(),
          sshUsername: sshUser ?? '',
          sshPassword: sshPass ?? '',
          injectMode: switch (injectMode) {
            InjectMode.directSni => 'DIRECT_SNI',
            InjectMode.proxy || InjectMode.proxySni => 'PROXY',
            _ => 'DIRECT',
          },
          proxyHost: injectHost ?? '',
          proxyPort: injectPort ?? '',
          sni: sni ?? '',
          payload: payload ?? '',
          dnsttDnsHost: _dnsttResolverHost(),
          dnsttDnsPort: _dnsttResolverPort(),
          dnsttServerName: dnsttServer ?? '',
          dnsttPubkey: dnsttKey ?? '',
          password: password,
          expiresAtSec: expSec,
          message: message,
          connectedMessage: connectedMessage,
        );
      default:
        return null;
    }
  }

  /// `dnsttResolver` may be `host` or `host:port` — the DarkTunnel fields
  /// are separate (host + port, default 53).
  String _dnsttResolverHost() {
    final r = dnsttResolver ?? '';
    final idx = r.indexOf(':');
    return idx > 0 ? r.substring(0, idx) : r;
  }

  String _dnsttResolverPort() {
    final r = dnsttResolver ?? '';
    final idx = r.indexOf(':');
    return idx > 0 && idx + 1 < r.length ? r.substring(idx + 1) : '53';
  }

  /// Parse the injector-style plain-text `key=value` share format (the text
  /// tunnel apps export to file / clipboard). Defensive: returns null unless it
  /// finds at least a host and a protocol we understand. Maps the share's
  /// DPI-bypass fields (payload / sni / bug / proxy) onto our existing inject
  /// model so a pasted share drops straight into My Configs.
  static ServerConfig? fromHttpCustomConfig(String text) {
    try {
      final map = <String, String>{};
      for (final raw in text.split('\n')) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final idx = line.indexOf('=');
        if (idx <= 0) continue;
        final k = line.substring(0, idx).trim().toLowerCase();
        final v = line.substring(idx + 1).trim();
        if (v.isNotEmpty) map[k] = v;
      }
      if (map.isEmpty) return null;

      // Only claim configs that carry share-format markers (payload / sni /
      // bug / type / auth / enhance) AND a target host. Official-backed tweak
      // shares deliberately carry no host; they are joined with the live
      // official feed by capability at connect time.
      final bool officialTweak = map['official'] == '1' &&
          (map['capability'] ?? map['type'] ?? '').isNotEmpty;
      final bool looksHc = map.containsKey('payload') ||
          map.containsKey('sni') ||
          map.containsKey('bug') ||
          map.containsKey('bugv') ||
          map.containsKey('tlsprem') ||
          map.containsKey('transport') ||
          map.containsKey('proxy') ||
          map.containsKey('proxyhost') ||
          map.containsKey('proxyip') ||
          map.containsKey('type') ||
          map.containsKey('capability') ||
          map.containsKey('enhance') ||
          map.containsKey('auth');
      final host = map['host'] ?? map['remote'] ?? map['server'];
      if (!officialTweak && (host == null || host.isEmpty || !looksHc)) {
        return null;
      }

      final port = _parsePort(map['port'], 443);
      final protocolRaw = (map['protocol'] ?? map['type'] ?? '').toLowerCase();
      final ProtocolType protocol;
      switch (protocolRaw) {
        case 'ssh':
        case 'sshssl':
        case 'ssl':
          protocol = ProtocolType.ssh;
          break;
        case 'v2ray':
        case 'vmess':
          protocol = ProtocolType.vmess;
          break;
        case 'vless':
          protocol = ProtocolType.vless;
          break;
        case 'trojan':
          protocol = ProtocolType.trojan;
          break;
        case 'vpn':
        case 'openvpn':
        case 'ovpn':
          protocol = ProtocolType.openvpn;
          break;
        case 'slowdns':
        case 'dnstt':
          protocol = ProtocolType.sshDnstt;
          break;
        case 'wireguard':
        case 'wg':
          protocol = ProtocolType.wireguard;
          break;
        case 'socks':
        case 'socks5':
          protocol = ProtocolType.socks;
          break;
        case 'http':
        case 'httpproxy':
        case 'http_proxy':
          protocol = ProtocolType.httpProxy;
          break;
        case 'psiphon':
          protocol = ProtocolType.psiphon;
          break;
        default:
          // No explicit protocol: if there's an ssh auth block treat as SSH,
          // else fall back to OpenVPN only when an ovpn payload is present.
          if (map['auth'] != null || map['ssh'] != null) {
            protocol = ProtocolType.ssh;
          } else if (map['uuid'] != null) {
            protocol = ProtocolType.vless;
          } else {
            protocol = ProtocolType.openvpn;
          }
      }

      String? sshUser;
      String? sshPass;
      final auth = map['auth'];
      if (auth != null && auth.contains(':')) {
        final parts = auth.split(':');
        sshUser = parts.first;
        sshPass = parts.skip(1).join(':');
      }
      sshUser ??= map['sshuser'] ?? map['user'] ?? map['username'];
      sshPass ??= map['sshpass'] ?? map['pass'] ?? map['password'];

      // The share's bug-host / proxy-host become our injector front.
      final injectHost = map['bug'] ??
          map['bugv'] ??
          map['proxyhost'] ??
          map['proxyip'] ??
          map['proxy'] ??
          map['squidproxy'];
      final injectPort = map['bugport'] ??
          map['proxyport'] ??
          map['squidport'];
      final sni = map['sni'] ?? map['servername'] ?? map['server_name'];
      final payload = map['payload'] ?? map['payloadbug'] ?? map['ndkpayload'];

      InjectMode injectMode = InjectMode.direct;
      final hasProxy = injectHost != null && injectHost.isNotEmpty;
      final hasSni = sni != null && sni.isNotEmpty;
      final hasPayload = payload != null && payload.isNotEmpty;
      if (hasProxy && hasSni) {
        injectMode = InjectMode.proxySni;
      } else if (hasProxy) {
        injectMode = InjectMode.proxy;
      } else if (hasSni) {
        injectMode = InjectMode.directSni;
      } else if (hasPayload) {
        injectMode = InjectMode.direct;
      }
      // An explicit mode key (our own exports / advanced text shares) wins over
      // the inference above.
      final explicitMode = map['injectmode'] ?? map['mode'];
      if (explicitMode != null && explicitMode.isNotEmpty) {
        injectMode = _parseInjectMode(explicitMode);
      }

      if (officialTweak) {
        return ServerConfig(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: (map['name'] ?? map['remark'] ?? 'Official tweak').trim(),
          note: map['name'] ?? map['remark'] ?? '',
          protocol: (map['ridewith'] ?? '').toString().isNotEmpty
              ? _parseProtocol(map['ridewith'].toString())
              : ProtocolType.vless,
          transport: _parseTransport((map['ridetransport'] ?? 'tcp').toString()),
          security: _parseSecurity((map['ridesecurity'] ?? 'none').toString()),
          address: '',
          port: 443,
          uuid: '',
          capability: (map['capability'] ?? map['type'] ?? '').toUpperCase(),
          anchorId: (map['anchor'] ?? '').toString().trim().isEmpty
              ? null
              : map['anchor'].toString().trim(),
          tweakFamily: (map['ridefamily'] ?? '').toString().trim().isEmpty
              ? null
              : map['ridefamily'].toString().trim().toLowerCase(),
          sni: sni,
          payload: payload,
          injectHost: injectHost,
          injectPort: injectPort,
          injectMode: injectMode,
          payloadEnhanced:
              map['enhance'] == '1' || map['payloadenhanced'] == 'true',
          isCustom: true,
          rawConfig: 'official:tweak',
          category: 'global',
        );
      }

      return ServerConfig(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: (map['name'] ?? map['remark'] ?? 'Text $host').trim(),
        note: map['name'] ?? map['remark'] ?? '',
        protocol: protocol,
        transport: _parseTransport(map['transport'] ?? 'tcp'),
        security: _parseSecurity(map['security'] ?? 'none'),
        address: host ?? '',
        port: port,
        uuid: map['uuid'] ?? map['id'] ?? '',
        password: map['password'],
        sni: sni,
        path: map['path'],
        host: map['wsHost'] ?? map['wshost'],
        serviceName: map['servicename'],
        payload: payload,
        sshUser: sshUser,
        sshPass: sshPass,
        injectHost: injectHost,
        injectPort: injectPort,
        injectMode: injectMode,
        dnsttServer: map['dnsttdomain'] ?? map['dnsttserver'],
        dnsttKey: map['dnsttpubkey'] ?? map['dnsttkey'],
        dnsttResolver: map['dnsttresolver'],
        payloadEnhanced: map['enhance'] == '1' || map['payloadenhanced'] == 'true',
        isCustom: true,
        category: 'global',
      );
    } catch (_) {
      return null;
    }
  }

  static ProtocolType _parseProtocol(String p) {
    switch (p.toLowerCase()) {
      case 'vless':
        return ProtocolType.vless;
      case 'vmess':
        return ProtocolType.vmess;
      case 'trojan':
        return ProtocolType.trojan;
      case 'shadowsocks':
      case 'ss':
        return ProtocolType.shadowsocks;
      case 'ssh':
        return ProtocolType.ssh;
      case 'ssh_dnstt':
      case 'sshdnstt':
      case 'dnstt':
      case 'slowdns':
        return ProtocolType.sshDnstt;
      case 'openvpn':
      case 'ovpn':
        return ProtocolType.openvpn;
      case 'wireguard':
      case 'wg':
        return ProtocolType.wireguard;
      case 'socks':
      case 'socks5':
        return ProtocolType.socks;
      case 'http':
      case 'http_proxy':
      case 'httpproxy':
        return ProtocolType.httpProxy;
      case 'psiphon':
        return ProtocolType.psiphon;
      case 'hysteria':
      case 'hysteria2':
      case 'hy2':
        return ProtocolType.hysteria;
      default:
        return ProtocolType.vless;
    }
  }

  static ProtocolType parseProtocol(String p) => _parseProtocol(p);

  /// Canonical capability marker — mirror of the panel's
  /// `toUpperCase().replace(/\s+/g,'_')` normalisation in config-schema.js,
  /// so [SNI]/[sni]/[ sni ] all compare equal on both sides.
  static String capabilityKey(String raw) =>
      raw.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '_');

  /// Protocol families of the Server↔Tweak rule (mirrors familyOfProtocol in
  /// admin-panel/src/config-schema.js): an SSH payload can never ride a
  /// vless host and vice versa.
  static String familyOf(ProtocolType p) {
    switch (p) {
      case ProtocolType.ssh:
      case ProtocolType.sshDnstt:
        return 'ssh';
      case ProtocolType.openvpn:
        return 'openvpn';
      case ProtocolType.wireguard:
        return 'wireguard';
      case ProtocolType.socks:
      case ProtocolType.httpProxy:
        return 'proxy';
      case ProtocolType.psiphon:
        return 'psiphon';
      case ProtocolType.hysteria:
        return 'hysteria';
      default:
        return 'v2ray';
    }
  }
  static TransportType parseTransport(String t) => _parseTransport(t);
  static SecurityType parseSecurity(String s) => _parseSecurity(s);
  static int parsePort(dynamic value, int fallback) =>
      _parsePort(value, fallback);
  static int? parseNullableInt(dynamic value) => _parseNullableInt(value);
  static InjectMode parseInjectMode(dynamic v) => _parseInjectMode(v);

  static InjectMode _parseInjectMode(dynamic v) {
    switch (v?.toString().toLowerCase().replaceAll(RegExp(r'[ _>-]+'), '')) {
      case 'direct':
      case 'directtarget':
        return InjectMode.direct;
      case 'directsni':
      case 'directwithsni':
      case 'directwithsnitarget':
        return InjectMode.directSni;
      case 'proxy':
      case 'proxytarget':
        return InjectMode.proxy;
      case 'proxysni':
      case 'proxywithsni':
      case 'proxywithsnitarget':
        return InjectMode.proxySni;
      case 'dnstt':
        return InjectMode.dnstt;
      default:
        return InjectMode.none;
    }
  }

  static TransportType _parseTransport(String t) {
    switch (t.toLowerCase()) {
      case 'ws':
      case 'websocket':
        return TransportType.ws;
      case 'grpc':
        return TransportType.grpc;
      case 'xhttp':
      case 'splithttp':
        return TransportType.xhttp;
      case 'httpupgrade':
      case 'http-upgrade':
        return TransportType.httpUpgrade;
      case 'kcp':
      case 'mkcp':
        return TransportType.mkcp;
      default:
        return TransportType.tcp;
    }
  }

  static SecurityType _parseSecurity(String s) {
    switch (s.toLowerCase()) {
      case 'tls':
      case 'ssl':
        return SecurityType.tls;
      case 'reality':
        return SecurityType.reality;
      default:
        return SecurityType.none;
    }
  }

  static int _parsePort(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  static int? _parseNullableInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// True when there is note content worth a popup: a real note (not just the
  /// name echoed), a lock message from the sharer, an author, or an expiry.
  bool get hasNoteInfo {
    final n = note.trim();
    return (n.isNotEmpty && n != name) ||
        (lockMessage ?? '').trim().isNotEmpty ||
        (author ?? '').trim().isNotEmpty ||
        expiresAt != null;
  }

  /// The protocol label the `key=value` share format expects: uppercase
  /// `type=SSH`-style headers that round-trip through [fromHttpCustomConfig].
  String get _hcProtocolLabel {
    switch (protocol) {
      case ProtocolType.ssh:
        return 'SSH';
      case ProtocolType.sshDnstt:
        return 'SLOWDNS';
      case ProtocolType.vmess:
        return 'V2RAY';
      case ProtocolType.vless:
        return 'VLESS';
      case ProtocolType.trojan:
        return 'TROJAN';
      case ProtocolType.shadowsocks:
        return 'SS';
      case ProtocolType.openvpn:
        return 'OPENVPN';
      case ProtocolType.wireguard:
        return 'WIREGUARD';
      case ProtocolType.socks:
        return 'SOCKS';
      case ProtocolType.httpProxy:
        return 'HTTP';
      case ProtocolType.psiphon:
        return 'PSIPHON';
      case ProtocolType.hysteria:
        return 'HYSTERIA';
    }
  }

  /// Serialize to the plain-text `key=value` share format used by tunnel
  /// injector apps for file / clipboard sharing. Only non-empty fields are
  /// written so the output stays readable, and every key we write is one
  /// [fromHttpCustomConfig] reads back (verified round-trip in tests).
  ///
  /// `payload` keeps its literal `\r\n` escape text: the payload engine
  /// expands those escapes at connect time, and externally authored payloads
  /// arrive in exactly this form.
  String toHttpCustomText() {
    esc(String s) =>
        s.replaceAll('\r\n', r'\r\n').replaceAll('\r', r'\r').replaceAll('\n', r'\n');
    if (rawConfig == 'official:tweak' && (capability ?? '').isNotEmpty) {
      final lines = <String>[
        '### ArmanTunnel official tweak (key=value)',
        'name=$name',
        'official=1',
        'capability=${capability!.toUpperCase()}',
        if ((anchorId ?? '').isNotEmpty) 'anchor=$anchorId',
        // The riding family travels too — a tweak shared from an SSH server
        // must not re-import as a VLESS tweak (family join would then lie).
        'ridewith=${protocol.name}',
        'ridetransport=${transport.name}',
        'ridesecurity=${security.name}',
        if ((tweakFamily ?? '').isNotEmpty) 'ridefamily=$tweakFamily',
      ];
      void add(String key, String? value) {
        final v = value ?? '';
        if (v.isEmpty) return;
        lines.add('$key=${esc(v)}');
      }

      add('sni', sni);
      add('bug', injectHost);
      add('bugport', injectPort);
      add('payload', payload);
      add('injectMode', injectMode == InjectMode.none ? null : injectMode.name);
      add('enhance', payloadEnhanced ? '1' : '');
      return lines.join('\n');
    }
    final lines = <String>[
      '### ArmanTunnel share config (key=value)',
      'name=$name',
      'type=${_hcProtocolLabel.toUpperCase()}',
      'host=$address',
      'port=$port',
    ];
    void add(String key, String? value) {
      final v = value ?? '';
      // No trim(): a payload's trailing CRLFs are meaningful (end of the
      // request block) and must survive the round-trip verbatim.
      if (v.isEmpty) return;
      lines.add('$key=${esc(v)}');
    }

    if (protocol == ProtocolType.ssh || protocol == ProtocolType.sshDnstt) {
      add('auth', [sshUser, sshPass].where((s) => (s ?? '').isNotEmpty).join(':'));
    }
    if (protocol == ProtocolType.vmess || protocol == ProtocolType.vless ||
        protocol == ProtocolType.trojan || protocol == ProtocolType.shadowsocks) {
      add('uuid', uuid.isNotEmpty ? uuid : password);
    }
    add('transport', transport.name);
    add('security', security.name);
    add('sni', sni);
    add('bug', injectHost);
    add('bugport', injectPort);
    add('payload', payload);
    add('path', path);
    add('wsHost', host);
    add('serviceName', serviceName);
    add('enhance', payloadEnhanced ? '1' : '');
    add('dnsttDomain', dnsttServer);
    add('dnsttPubKey', dnsttKey);
    add('dnsttResolver', dnsttResolver);
    return lines.join('\n');
  }

  /// The native share format: `armantunnel://<base64url(json)>`. Round-trips
  /// through [ConfigService.importFromText] with every field intact (full JSON,
  /// including .ovpn bodies the text format cannot carry).
  String toShareLink() =>
      'armantunnel://${base64Url.encode(utf8.encode(jsonEncode(toJson())))}';

  /// Share link for a whole backup: the inner JSON is an ARRAY of configs and
  /// the import path accepts arrays.
  static String shareLinkForAll(List<ServerConfig> configs) =>
      'armantunnel://${base64Url.encode(utf8.encode(jsonEncode(configs.map((c) => c.toJson()).toList())))}';

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'note': note,
        'protocol': protocol.name,
        'transport': transport.name,
        'security': security.name,
        'address': address,
        'port': port,
        'uuid': uuid,
        'alterId': alterId,
        'password': password,
        'encryption': encryption,
        'sni': sni,
        'path': path,
        'host': host,
        'serviceName': serviceName,
        'fingerprint': fingerprint,
        'flow': flow,
        'publicKey': publicKey,
        'shortId': shortId,
        'isOfficial': isOfficial,
        'logoBase64': logoBase64,
        'logoUrl': logoUrl,
        'payload': payload,
        'sshUser': sshUser,
        'sshPass': sshPass,
        'injectHost': injectHost,
        'injectPort': injectPort,
        'injectPayload': injectPayload,
        'injectMode': injectMode.name,
        'dnsttServer': dnsttServer,
        'dnsttKey': dnsttKey,
        'dnsttResolver': dnsttResolver,
        'ovpnConfig': ovpnConfig,
        'wireguardConfig': wireguardConfig,
        'psiphonRegion': psiphonRegion,
        'payloadEnhanced': payloadEnhanced,
        'sshCompression': sshCompression,
        'category': category,
        'capability': capability,
        'capabilities': capabilities,
        'anchorId': anchorId,
        'tweakFamily': tweakFamily,
        'serverPool': serverPool,
        'country': country,
        'region': region,
        'server': server,
        'isCustom': isCustom,
        'rawConfig': rawConfig,
        'author': author,
        'encryptionKey': encryptionKey,
        'locked': locked,
        'lockMessage': lockMessage,
        'expiresAt': expiresAt,
        'vip': vip,
        'vipUnlockHours': vipUnlockHours,
        'vipNote': vipNote,
        'vault': vault,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        id: json['id'] ?? '',
        name: json['name'] ?? '',
        note: json['note'] ?? '',
        protocol: _parseProtocol(json['protocol'] ?? 'vless'),
        transport: _parseTransport(json['transport'] ?? 'tcp'),
        security: _parseSecurity(json['security'] ?? 'none'),
        address: json['address'] ?? '',
        port: _parsePort(json['port'], 443),
        uuid: json['uuid'] ?? '',
        alterId: json['alterId'],
        password: json['password'],
        encryption: json['encryption'],
        sni: json['sni'],
        path: json['path'],
        host: json['host'],
        serviceName: json['serviceName'],
        fingerprint: json['fingerprint'],
        flow: json['flow'],
        publicKey: json['publicKey'],
        shortId: json['shortId'],
        isOfficial: json['isOfficial'] ?? false,
        logoBase64: json['logoBase64'],
        logoUrl: json['logoUrl'],
        payload: json['payload'],
        sshUser: json['sshUser'],
        sshPass: json['sshPass'],
        injectHost: json['injectHost'],
        injectPort: json['injectPort'],
        injectPayload: json['injectPayload'],
        injectMode: _parseInjectMode(json['injectMode']),
        dnsttServer: json['dnsttServer'],
        dnsttKey: json['dnsttKey'],
        dnsttResolver: json['dnsttResolver'],
        ovpnConfig: json['ovpnConfig'],
        wireguardConfig: json['wireguardConfig'],
        psiphonRegion: json['psiphonRegion'],
        payloadEnhanced: json['payloadEnhanced'] == true,
        sshCompression: json['sshCompression'] == true,
        category: json['category'] ?? 'global',
        capability: json['capability'],
        capabilities: (json['capabilities'] is List
            ? (json['capabilities'] as List)
                .map((e) => e.toString().trim().toUpperCase())
                .where((e) => e.isNotEmpty)
                .toSet()
                .toList()
            : const []),
        anchorId: json['anchorId']?.toString(),
        tweakFamily: json['tweakFamily']?.toString(),
        serverPool: _parseServerPool(json['serverPool']),
        country: json['country'],
        region: json['region'],
        server: json['server'],
        isCustom: json['isCustom'] ?? false,
        rawConfig: json['rawConfig'],
        author: json['author'],
        encryptionKey: json['encryptionKey'],
        locked: json['locked'] == true,
        lockMessage: json['lockMessage'],
        expiresAt: _parseNullableInt(json['expiresAt']),
        vip: json['vip'] == true,
        vipUnlockHours: _parseNullableInt(json['vipUnlockHours']),
        vipNote: json['vipNote'] is String ? (json['vipNote'] as String).trim() : null,
        vault: json['vault'] is String ? (json['vault'] as String).trim() : null,
      );
}
