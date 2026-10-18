// Arman Tunnel — canonical config schema (single source of truth).
//
// This file defines the EXACT wire format the Flutter app consumes. Every field
// here has a matching field in `lib/models/server_config.dart` (ServerConfig)
// and is read back by `ConfigService._serverFromAdminJson`. If you add a field,
// add it in BOTH places or it silently disappears on the device.
//
// Nothing in here touches KV, crypto or GitHub — it is pure data shaping so it
// can be unit-tested with plain node.

export const PROTOCOLS = [
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'ssh',
  'ssh_dnstt',
  'openvpn',
  'wireguard',
  'socks',
  'http_proxy',
  'psiphon',
  'hysteria',
];

export const TRANSPORTS = ['tcp', 'ws', 'grpc', 'xhttp', 'httpupgrade', 'kcp'];
export const SECURITIES = ['none', 'tls', 'reality'];
export const INJECT_MODES = ['none', 'direct', 'directSni', 'proxy', 'proxySni', 'dnstt'];

/// Traffic class used by the app to group tunnels on the Tunnels tab.
/// NOTE: this is NOT a country. Country lives in its own `country` field.
export const CATEGORIES = [
  'global',
  'gaming',
  'streaming',
  'facebook',
  'messenger',
  'youtube',
  'tiktok',
  'instagram',
  'telegram',
  'whatsapp',
];

/// Clamp a free-form category NAME (Tweaks categories are admin-defined
/// strings like "Normal Internet" — no longer just the enum above).
export function normalizeCategoryName(v) {
  return str(v)
    .replace(/[\u0000-\u001f\u007f]+/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 48);
}

/// Canonical `category` value for a config/server: legacy enum ids stay
/// lowercase; new admin-defined names keep their case.
export function normalizeCategoryValue(v) {
  const s = normalizeCategoryName(v);
  if (!s) return 'global';
  const lower = s.toLowerCase();
  if (CATEGORIES.includes(lower)) return lower;
  return s;
}

export function newCategoryId() {
  return 'cat_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

// ---------------------------------------------------------------------------
// Capability types — the Server ↔ Tweak compatibility system.
//
// A Server declares which capability types it supports (capabilities[]); a
// Tweak declares the one capability it IS. Compatibility is dynamic:
//   tweak.capability ∈ server.capabilities (AND same protocol family)
// so one server going down never kills a tweak — the app fails over to the
// next compatible server in the joined pool. Types are admin-managed
// (create/edit/enable) and flow to the app inside the settings bundle, so
// new types do not need an app update.
// ---------------------------------------------------------------------------

/** Seed list — the panel creates these on first run; admins add more. */
export const DEFAULT_CAPABILITY_TYPES = [
  'INJECTED',
  'SNI',
  'PROXY+PAYLOAD',
  'HTTP',
  'SSL',
  'PROXY',
  'CLOUDFRONT-PROXY-PAYLOAD',
  'CLOUDFLARE-PROXY-PAYLOAD',
  'DNSTT',
  'DIRECT',
];

export const DEFAULT_CAPABILITY_DESCRIPTIONS = {
  INJECTED: 'Normal injected payload method',
  SNI: 'SNI only',
  'PROXY+PAYLOAD': 'Proxy/front host plus custom payload',
  HTTP: 'Plain HTTP payload injection',
  SSL: 'TLS/SSL wrapper with optional SNI',
  PROXY: 'Proxy/front host only',
  'CLOUDFRONT-PROXY-PAYLOAD': 'CloudFront proxy plus payload',
  'CLOUDFLARE-PROXY-PAYLOAD': 'Cloudflare proxy plus payload',
  DNSTT: 'SlowDNS / DNSTT tunnel',
  DIRECT: 'Plain direct connection',
};

const DEFAULT_PROXY_HOST = '[Default]';
const DEFAULT_PROXY_PORT = '80';

export function newTypeId() {
  return 'typ_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

/** Canonical CapabilityType entity — {name, enabled, description}. */
export function normalizeCapabilityType(input, { keepId = true } = {}) {
  const d = input && typeof input === 'object' ? input : {};
  const m = stripEmpty(d);
  return {
    id: keepId && str(m.id) ? str(m.id) : newTypeId(),
    // Capability names are SHOUTING markers ([SNI]) — uppercase, no spaces
    // beyond the '+'/'-' inside them.
    name: str(m.name).toUpperCase().replace(/\s+/g, '_').slice(0, 40),
    description: str(m.description).slice(0, 160),
    enabled: m.enabled === undefined ? true : bool(m.enabled),
    createdAt: str(m.createdAt) || new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };
}

export function validateCapabilityType(t) {
  const errors = [];
  if (!t.name || t.name.length < 2) errors.push({ field: 'name', message: 'Type name is required (min 2 chars)' });
  return { ok: errors.length === 0, errors, warnings: [] };
}

/** Normalize a capabilities array on a server: dedup + drop blanks/unknown
 *  casing. Values are kept as typed (uppercase markers). */
function normalizeCapabilities(v) {
  const raw = Array.isArray(v) ? v : (v ? [v] : []);
  const out = [];
  for (const item of raw) {
    const s = str(item).toUpperCase().replace(/\s+/g, '_').trim();
    if (s && !out.includes(s)) out.push(s);
  }
  return out;
}

function normalizeServerIds(v) {
  const raw = Array.isArray(v) ? v : (v ? [v] : []);
  const out = [];
  for (const item of raw) {
    const s = str(item).trim();
    if (s && !out.includes(s)) out.push(s);
  }
  return out;
}

/**
 * Infer a tweak's capability from its method fields — used for migration of
 * legacy tweaks (which had a hard serverId) and as a fallback when a tweak
 * somehow carries no capability.
 */
export function inferCapability(c) {
  const mode = str(c.injectMode).toLowerCase();
  const hasPayload = str(c.payload).trim() !== '' || str(c.injectPayload).trim() !== '';
  if (str(c.dnsttServer) || mode === 'dnstt') return 'DNSTT';
  if (mode === 'proxy' || mode === 'proxysni') return hasPayload ? 'PROXY+PAYLOAD' : 'PROXY';
  if (mode === 'directsni') return hasPayload ? 'INJECTED' : 'SNI';
  if (mode === 'direct') return hasPayload ? 'INJECTED' : 'SSL';
  return 'DIRECT';
}

/** Canonical Category entity — {name, country}. The country code is the
 *  flag the app renders next to the category (earth emoji when blank).
 *  An invalid non-empty country is kept uppercase so validateCategoryEntity
 *  can reject it with a proper message instead of silently dropping it. */
export function normalizeCategoryEntity(input, { keepId = true } = {}) {
  const d = input && typeof input === 'object' ? input : {};
  const m = stripEmpty(d);
  return {
    id: keepId && str(m.id) ? str(m.id) : newCategoryId(),
    name: normalizeCategoryName(m.name),
    country: str(m.country ?? m.countryCode).toUpperCase(),
    createdAt: str(m.createdAt) || new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };
}

export function validateCategoryEntity(c) {
  const errors = [];
  const warnings = [];
  if (!c.name) errors.push({ field: 'name', message: 'Category name is required' });
  if (c.country && !/^[A-Z]{2}$/.test(c.country)) {
    errors.push({ field: 'country', message: 'Country must be a 2-letter ISO code (or empty)' });
  }
  return { ok: errors.length === 0, errors, warnings };
}

export const SS_METHODS = [
  'aes-128-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'chacha20-poly1305',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
];

const V2RAY_PROTOCOLS = ['vless', 'vmess', 'trojan', 'shadowsocks'];

// Country auto-detection: match the ccTLD / common geo labels in a hostname.
// Order matters — more specific patterns first.
const COUNTRY_HINTS = [
  [/\.(bd)(\.|$)/i, 'BD'], [/bangla|dhaka|bdix/i, 'BD'],
  [/\.(in)(\.|$)/i, 'IN'], [/jio|airtel|mumbai|delhi/i, 'IN'],
  [/\.(sg)(\.|$)/i, 'SG'], [/singapore/i, 'SG'],
  [/\.(jp)(\.|$)/i, 'JP'], [/tokyo|osaka|japan/i, 'JP'],
  [/\.(us)(\.|$)/i, 'US'], [/america|dallas|virginia/i, 'US'],
  [/\.(uk)(\.|$)/i, 'GB'], [/london|britain/i, 'GB'],
  [/\.(de)(\.|$)/i, 'DE'], [/frankfurt|germany/i, 'DE'],
  [/\.(nl)(\.|$)/i, 'NL'], [/amsterdam/i, 'NL'],
  [/\.(my)(\.|$)/i, 'MY'], [/malaysia/i, 'MY'],
  [/\.(kr)(\.|$)/i, 'KR'], [/korea|seoul/i, 'KR'],
  [/\.(hk)(\.|$)/i, 'HK'], [/hong ?kong/i, 'HK'],
  [/\.(ae)(\.|$)/i, 'AE'], [/dubai/i, 'AE'],
  [/\.(tr)(\.|$)/i, 'TR'], [/turkey|istanbul/i, 'TR'],
  [/\.(br)(\.|$)/i, 'BR'], [/brazil|sao ?paulo/i, 'BR'],
  [/\.(ca)(\.|$)/i, 'CA'], [/canada|toronto/i, 'CA'],
  [/\.(au)(\.|$)/i, 'AU'], [/australia|sydney/i, 'AU'],
  [/\.(fr)(\.|$)/i, 'FR'], [/paris|france/i, 'FR'],
];

/** Guess an ISO-2 country from a hostname/name; '' when nothing matches. */
export function guessCountry(...parts) {
  const text = parts.filter(Boolean).join(' ').toLowerCase();
  for (const [re, code] of COUNTRY_HINTS) {
    if (re.test(text)) return code;
  }
  // Hostname labels like "sgx", "sg1", "jp02" — geo-prefixed node names.
  const host = parts.find((p) => typeof p === 'string' && p.includes('.')) || '';
  for (const label of host.toLowerCase().split('.')) {
    const m = /^([a-z]{2})[a-z]?\d*[a-z]*$/.exec(label);
    if (!m) continue;
    const hit = COUNTRY_HINTS.find(([, code]) => code.toLowerCase() === m[1]);
    if (hit) return hit[1];
  }
  return '';
}

export function isV2ray(protocol) {
  return V2RAY_PROTOCOLS.includes(protocol);
}

export function isSshFamily(protocol) {
  return protocol === 'ssh' || protocol === 'ssh_dnstt';
}

// ---------------------------------------------------------------------------
// Coercion helpers
// ---------------------------------------------------------------------------

function str(v) {
  if (v === null || v === undefined) return '';
  return String(v).trim();
}

function bool(v) {
  if (v === true) return true;
  if (v === false || v === null || v === undefined) return false;
  const s = String(v).toLowerCase();
  return s === 'true' || s === '1' || s === 'yes' || s === 'on';
}

function int(v, fallback = 0) {
  if (typeof v === 'number' && Number.isFinite(v)) return Math.trunc(v);
  const n = parseInt(String(v ?? '').trim(), 10);
  return Number.isFinite(n) ? n : fallback;
}

/// Clamp an integer to [min, max]; non-numeric → fallback.
function clampInt(v, min, max, fallback) {
  const n = int(v, fallback);
  return Math.min(max, Math.max(min, n));
}

/// Accepts every spelling the app's `ServerConfig.parseProtocol` accepts and
/// normalises to the canonical id.
export function normalizeProtocol(v) {
  const s = str(v).toLowerCase().replace(/[\s-]+/g, '_');
  switch (s) {
    case 'vless':
      return 'vless';
    case 'vmess':
      return 'vmess';
    case 'trojan':
      return 'trojan';
    case 'ss':
    case 'shadowsocks':
      return 'shadowsocks';
    case 'ssh':
      return 'ssh';
    case 'ssh_dnstt':
    case 'sshdnstt':
    case 'dnstt':
    case 'slowdns':
    case 'ssh_slowdns':
      return 'ssh_dnstt';
    case 'openvpn':
    case 'ovpn':
      return 'openvpn';
    case 'wireguard':
    case 'wg':
      return 'wireguard';
    case 'socks':
    case 'socks5':
      return 'socks';
    case 'http':
    case 'http_proxy':
    case 'httpproxy':
      return 'http_proxy';
    case 'psiphon':
      return 'psiphon';
    case 'hysteria':
    case 'hysteria2':
    case 'hy2':
      return 'hysteria';
    default:
      return '';
  }
}

export function normalizeTransport(v) {
  const s = str(v).toLowerCase();
  if (s === 'ws' || s === 'websocket') return 'ws';
  if (s === 'grpc' || s === 'gun') return 'grpc';
  if (s === 'xhttp' || s === 'splithttp') return 'xhttp';
  if (s === 'httpupgrade' || s === 'http-upgrade') return 'httpupgrade';
  if (s === 'kcp' || s === 'mkcp') return 'kcp';
  return 'tcp';
}

export function normalizeSecurity(v) {
  const s = str(v).toLowerCase();
  if (s === 'tls' || s === 'ssl' || s === 'xtls') return 'tls';
  if (s === 'reality') return 'reality';
  return 'none';
}

/// Mirrors `ServerConfig.parseInjectMode` (which strips spaces/underscores/dashes).
export function normalizeInjectMode(v) {
  const s = str(v).toLowerCase().replace(/[ _>-]+/g, '');
  switch (s) {
    case 'direct':
    case 'directtarget':
      return 'direct';
    case 'directsni':
    case 'directwithsni':
    case 'directwithsnitarget':
      return 'directSni';
    case 'proxy':
    case 'proxytarget':
      return 'proxy';
    case 'proxysni':
    case 'proxywithsni':
    case 'proxywithsnitarget':
      return 'proxySni';
    case 'dnstt':
      return 'dnstt';
    default:
      return 'none';
  }
}

export function newConfigId() {
  return 'cfg_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

/// Short human label per protocol (used for auto-generated names and badges).
export function protocolLabel(protocol) {
  switch (protocol) {
    case 'vless':
      return 'VLESS';
    case 'vmess':
      return 'VMess';
    case 'trojan':
      return 'Trojan';
    case 'shadowsocks':
      return 'SS';
    case 'ssh':
      return 'SSH';
    case 'ssh_dnstt':
      return 'SSH-DNS';
    case 'openvpn':
      return 'OpenVPN';
    case 'wireguard':
      return 'WireGuard';
    case 'socks':
      return 'SOCKS5';
    case 'http_proxy':
      return 'HTTP Proxy';
    case 'psiphon':
      return 'Psiphon';
    case 'hysteria':
      return 'Hysteria';
    default:
      return 'Config';
  }
}

// ---------------------------------------------------------------------------
// normalizeConfig — the canonical shape
// ---------------------------------------------------------------------------

/**
 * Build the canonical config object. Accepts loose input (share-link parser
 * output, panel form, an old stored config, a DarkTunnel-ish payload) and
 * always returns every field the app knows about, so a round trip through the
 * panel can never drop data.
 */
export function normalizeConfig(input, { keepId = true } = {}) {
  const d = input && typeof input === 'object' ? input : {};

  // A pasted share link / .ovpn body can carry more truth than the form did:
  // merge the parsed result UNDER the explicit fields so the form always wins.
  const raw = str(d.rawContent || d.rawConfig || d.shareLink);
  let parsed = {};
  if (raw) {
    const p = parseAnyConfigText(raw);
    if (p) parsed = p;
  }
  const m = { ...parsed, ...stripEmpty(d) };

  const protocol = normalizeProtocol(m.protocol) || (m.ovpnConfig ? 'openvpn' : 'vless');
  const transport = normalizeTransport(m.transport ?? m.net ?? m.type);
  const security = normalizeSecurity(m.security ?? m.tls);
  const ovpnConfig = str(m.ovpnConfig ?? m.ovpn);

  // OpenVPN profiles carry their own endpoint; trust the profile when the form
  // left the address blank (this is what actually broke .ovpn uploads before).
  let address = str(m.address ?? m.host ?? m.add ?? m.serverHost);
  let port = int(m.port ?? m.serverPort, 0);
  if (protocol === 'openvpn' && ovpnConfig) {
    const remote = parseOvpnRemote(ovpnConfig);
    if (!address && remote.host) address = remote.host;
    if (!port && remote.port) port = remote.port;
  }
  if (!port) port = defaultPortFor(protocol, security);

  const injectMode = normalizeInjectMode(m.injectMode ?? m.mode);
  const proxyMode = injectMode === 'proxy' || injectMode === 'proxySni';
  const rawInjectHost = str(m.injectHost ?? m.proxyHost ?? m.SquidProxy ?? m.squidProxy);
  const rawInjectPort = str(int(m.injectPort ?? m.proxyPort ?? m.SquidPort ?? m.squidPort, 0) || '');

  // `host` is ambiguous in the wild: in share links and DarkTunnel payloads it
  // is the WS/TLS host header, but plenty of hand-written JSON uses it for the
  // endpoint. Treat it as the header only when an explicit address exists —
  // otherwise it already got consumed as the address above.
  const explicitAddress = str(m.address ?? m.add ?? m.serverHost) !== '';
  const hostHeader = str(m.wsHost ?? m.hostHeader ?? m.wsHeaderHost ?? m.hostOverride) ||
    (explicitAddress ? str(m.host) : '');

  const out = {
    // identity
    id: keepId && str(m.id) ? str(m.id) : newConfigId(),
    // No silent "Config" placeholder: a nameless config is a validation error,
    // but a parsed link/profile can always name itself from its endpoint.
    name: str(m.name ?? m.ps ?? m.note) || (address ? `${protocolLabel(protocol)} ${address}` : ''),
    note: str(m.note ?? m.description ?? m.name),
    protocol,
    // endpoint
    address,
    port,
    // v2ray transport
    transport,
    security,
    uuid: str(m.uuid ?? m.userId ?? (protocol === 'vless' || protocol === 'vmess' ? m.id2 : '')),
    alterId: str(m.alterId ?? m.aid),
    password: str(m.password ?? m.pass),
    encryption: str(m.encryption ?? m.method ?? m.scy ?? m.cipher),
    sni: str(m.sni ?? m.serverName ?? m.serverNameIndication),
    path: str(m.path ?? m.wsPath),
    host: hostHeader,
    serviceName: str(m.serviceName),
    fingerprint: str(m.fingerprint ?? m.fp),
    flow: str(m.flow),
    publicKey: str(m.publicKey ?? m.pbk),
    shortId: str(m.shortId ?? m.sid),
    // ssh
    sshUser: str(m.sshUser ?? m.username ?? m.user),
    sshPass: str(m.sshPass),
    sshCompression: bool(m.sshCompression),
    // payload injection
    payload: str(m.payload ?? m.ndkPayload),
    payloadEnhanced: bool(m.payloadEnhanced),
    injectMode,
    injectHost: proxyMode && !rawInjectHost ? DEFAULT_PROXY_HOST : rawInjectHost,
    injectPort: proxyMode && !rawInjectPort ? DEFAULT_PROXY_PORT : rawInjectPort,
    injectPayload: str(m.injectPayload),
    // dnstt / slowdns
    dnsttServer: str(m.dnsttServer ?? m.dnsttServerName),
    dnsttKey: str(m.dnsttKey ?? m.dnsttPublicKey),
    dnsttResolver: str(m.dnsttResolver ?? m.dnsttUdpDnsHost),
    // openvpn
    ovpnConfig,
    // wireguard / psiphon full setup bodies. These MUST survive normalize or
    // a WireGuard/Psiphon node created in the panel lands on the app with no
    // body/region (validateConfig used to demand keys the normalizer dropped).
    wireguardConfig: str(m.wireguardConfig ?? m.wireguard ?? m.wireguardConf),
    psiphonRegion: str(m.psiphonRegion ?? m.psiphon ?? m.psiphonServerRegion),
    // presentation / grouping. Older bundles abused `category` as a country
    // code ("bd", "sg") — detect that here and move it where it belongs so the
    // app's tunnel grouping stops showing phantom categories. When nothing
    // declares a country, guess it from the hostname (ccTLD / geo labels).
    ...(() => {
      const catRaw = normalizeCategoryName(m.category);
      const looksLikeCountry =
        catRaw.length === 2 && /^[a-z]{2}$/i.test(catRaw) && !CATEGORIES.includes(catRaw.toLowerCase());
      const country = str(m.country ?? m.countryCode).toUpperCase() ||
        (looksLikeCountry ? catRaw.toUpperCase() : '') ||
        guessCountry(address, m.name, m.region);
      return {
        category: looksLikeCountry ? 'global' : normalizeCategoryValue(catRaw),
        country,
      };
    })(),
    region: str(m.region ?? m.location),
    // Logical server grouping: one host may carry several payload/SNI configs.
    // This is a purely presentational label the admin panel groups by (and the
    // app uses as the display name when set); it does not change the endpoint.
    server: str(m.server ?? m.serverName2),
    // Reference to a ServerEntity (LEGACY: the admin's old "pick a server"
    // flow). Kept only as the preferred/anchor server — the tweak joins with
    // EVERY server whose capabilities include its type. New tweaks carry no
    // serverId at all.
    serverId: str(m.serverId),
    // Optional explicit server allow-list for the tweak. Blank means every
    // compatible server, preserving the auto-pool behavior.
    serverIds: normalizeServerIds(m.serverIds ?? m.selectedServerIds),
    // The tweak's capability type ([SNI], [PROXY+PAYLOAD], …) — what kind of
    // method it is. Servers supporting this type are its compatible pool.
    capability: str(m.capability).toUpperCase().replace(/\s+/g, '_'),
    // Protocol family the method targets (ssh | vless | openvpn family).
    // Compatibility requires the same family — an SSH payload can't ride a
    // vless endpoint. Legacy tweaks inherit the joined server's protocol.
    family: str(m.family).toLowerCase(),

    logoBase64: str(m.logoBase64),
    // Hosted logo image (imgbb URL from the panel's upload button). Wins over
    // logoBase64 in the app: no size limit on the bundle and cacheable.
    logoUrl: str(m.logoUrl),
    author: str(m.author),
    // access control
    isOfficial: m.isOfficial === undefined ? true : bool(m.isOfficial),
    locked: bool(m.locked),
    lockMessage: str(m.lockMessage),
    expiresAt: Math.max(0, int(m.expiresAt, 0)),
    encryptionKey: str(m.encryptionKey),
    // VIP server: the app gate-keeps it behind a rewarded ad (default 2h per
    // unlock). vipUnlockHours is how long one rewarded unlock lasts; vipNote is
    // an optional pitch shown in the app's unlock sheet. ownsVip records that
    // the tweak explicitly decided its vip value, so a join can let it opt out
    // of an otherwise-VIP server (admin-only metadata, never published).
    vip: bool(m.vip),
    vipUnlockHours: int(m.vipUnlockHours, 0) > 0 ? clampInt(m.vipUnlockHours, 1, 24, 2) : 2,
    vipNote: str(m.vipNote),
    ownsVip: m.ownsVip === undefined ? 'vip' in m : bool(m.ownsVip),
    // Server-side endpoint vault: set vault === id to keep this VIP config's
    // real address/port out of the published app bundle. The app then resolves
    // the endpoint from /api/vip/resolve after a verified rewarded-ad unlock.
    vault: str(m.vault),
    // admin-only metadata (the app ignores these)
    active: m.active === undefined ? true : bool(m.active),
    priority: int(m.priority, 0),
    maxConnections: Math.max(0, int(m.maxConnections, 0)),
    createdAt: str(m.createdAt) || new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  // Derived defaults that the engine needs and users always forget.
  if (protocol === 'vless' && !out.encryption) out.encryption = 'none';
  if (protocol === 'vmess' && !out.encryption) out.encryption = 'auto';
  if (protocol === 'vmess' && !out.alterId) out.alterId = '0';
  if (protocol === 'shadowsocks' && !out.encryption) out.encryption = 'aes-256-gcm';
  if (protocol === 'trojan' && !out.password) out.password = out.uuid;
  if (protocol === 'trojan' && !out.uuid) out.uuid = out.password;
  // xray needs a uTLS fingerprint for fake-SNI to survive DPI (see HANDOFF).
  if (isV2ray(protocol) && security !== 'none' && !out.fingerprint) {
    out.fingerprint = 'chrome';
  }
  if (transport === 'grpc' && !out.serviceName && out.path) {
    out.serviceName = out.path.replace(/^\//, '');
  }
  // Note is a CUSTOMIZABLE, clearable field now (the admin sets it per
  // tweak/server; the app shows it under the name). Never sync it to the
  // name again — the old `out.note = out.name` put the server name under
  // every tweak card, and an edited name left the stale name behind.
  out.note = str(m.note ?? '');

  return out;
}

/// Drop keys whose value is empty/undefined so `{...parsed, ...form}` merges
/// sensibly (an untouched form field must not erase a parsed value). `note`
/// is exempt — an EMPTY note in the form payload is a deliberate CLEAR (the
/// app hides the line when blank), so it must survive the strip.
function stripEmpty(o) {
  const out = {};
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined || v === null) continue;
    if (k !== 'note' && typeof v === 'string' && v.trim() === '') continue;
    out[k] = v;
  }
  return out;
}

function defaultPortFor(protocol, security) {
  if (protocol === 'ssh' || protocol === 'ssh_dnstt') return 22;
  if (protocol === 'openvpn') return 1194;
  if (protocol === 'wireguard') return 51820;
  if (protocol === 'socks' || protocol === 'http_proxy') return 1080;
  if (protocol === 'psiphon') return 443;
  if (protocol === 'hysteria') return 443;
  return security === 'none' ? 80 : 443;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/**
 * Validate a normalized config. Returns { ok, errors: [{field, message}],
 * warnings: [...] }. Errors block the save; warnings are advisory.
 */
export function validateConfig(c) {
  const errors = [];
  const warnings = [];
  const err = (field, message) => errors.push({ field, message });
  const warn = (field, message) => warnings.push({ field, message });

  if (!c.name) err('name', 'Name is required');
  if (!PROTOCOLS.includes(c.protocol)) err('protocol', 'Unknown protocol');

  if (!c.address) err('address', 'Server address is required');
  else if (/\s/.test(c.address)) err('address', 'Address must not contain spaces');
  if (!(c.port >= 1 && c.port <= 65535)) err('port', 'Port must be 1–65535');

  switch (c.protocol) {
    case 'vless':
    case 'vmess':
      if (!c.uuid) err('uuid', 'UUID is required');
      else if (!looksLikeUuid(c.uuid)) warn('uuid', 'Does not look like a UUID');
      break;
    case 'trojan':
      if (!c.password) err('password', 'Trojan password is required');
      break;
    case 'shadowsocks':
      if (!c.password) err('password', 'Shadowsocks password is required');
      if (!c.encryption) err('encryption', 'Shadowsocks method is required');
      else if (!SS_METHODS.includes(c.encryption)) {
        warn('encryption', 'Unusual Shadowsocks method: ' + c.encryption);
      }
      break;
    case 'ssh':
    case 'ssh_dnstt':
      if (!c.sshUser) err('sshUser', 'SSH username is required');
      if (!c.sshPass) err('sshPass', 'SSH password is required');
      if (c.protocol === 'ssh_dnstt') {
        if (!c.dnsttServer) err('dnsttServer', 'DNSTT nameserver is required');
        if (!c.dnsttKey) err('dnsttKey', 'DNSTT public key is required');
        if (!c.dnsttResolver) warn('dnsttResolver', 'No resolver set — 1.1.1.1:53 will be used');
      }
      break;
    case 'openvpn':
      if (!c.ovpnConfig) err('ovpnConfig', 'The .ovpn profile body is required');
      else if (!/(^|\n)\s*remote\s+\S+/i.test(c.ovpnConfig)) {
        err('ovpnConfig', 'Profile has no `remote` line');
      } else if (/^\s*auth-user-pass\s*$/im.test(c.ovpnConfig) && !c.sshUser) {
        err('sshUser', 'This profile has a bare `auth-user-pass` — username/password required');
      }
      break;
    case 'wireguard':
      if (!c.wireguardConfig) err('wireguardConfig', 'WireGuard config body is required');
      else if (!/^\[Interface\]/m.test(c.wireguardConfig)) {
        err('wireguardConfig', 'WireGuard config must start with an [Interface] section');
      }
      break;
    case 'socks':
      if (!c.sshUser) err('sshUser', 'SOCKS username is required');
      if (!c.sshPass) err('sshPass', 'SOCKS password is required');
      break;
    case 'http_proxy':
      if (!c.sshUser) err('sshUser', 'HTTP proxy username is required');
      if (!c.sshPass) err('sshPass', 'HTTP proxy password is required');
      break;
    case 'psiphon':
      if (!c.psiphonRegion) warn('psiphonRegion', 'No region set — US will be used');
      break;
    default:
      break;
  }

  if (isV2ray(c.protocol)) {
    if (c.transport === 'grpc' && !c.serviceName) {
      err('serviceName', 'gRPC needs a service name');
    }
    // WS + payload is a legitimate v2rayinject-style setup: the front answers
    // the payload with a fake 101, then xray's real handshake must carry the
    // backend's actual path. Without a path the backend refuses (404) — that
    // is the one thing worth warning about.
    if (c.transport === 'ws' && !c.path) {
      warn('path', 'WebSocket without a path — the backend usually only accepts its real path (404 otherwise)');
    }
    if (c.security === 'reality') {
      if (!c.publicKey) err('publicKey', 'REALITY needs the server public key');
      if (!c.sni) err('sni', 'REALITY needs a serverName (SNI)');
    }
    if (c.security === 'none' && c.sni) {
      warn('sni', 'SNI is ignored when security is "none"');
    }
  } else if (c.transport !== 'tcp') {
    warn('transport', `${c.protocol} ignores the transport setting`);
  }

  if ((c.injectMode === 'proxy' || c.injectMode === 'proxySni') && !c.injectHost) {
    err('injectHost', 'Proxy inject modes need a bug/proxy host or [Default]');
  }
  if (c.injectMode === 'dnstt' && c.protocol !== 'ssh_dnstt') {
    warn('injectMode', 'DNSTT inject mode only applies to SSH+DNSTT');
  }
  if (c.payload && !isV2ray(c.protocol) && c.injectMode === 'none') {
    warn('injectMode', 'A payload is set but inject mode is None — it will not be sent');
  }
  if (c.expiresAt > 0 && c.expiresAt < Date.now()) {
    warn('expiresAt', 'Expiry is already in the past');
  }
  if (c.expiresAt > 0 && c.expiresAt < 1e12) {
    err('expiresAt', 'Expiry must be a millisecond epoch');
  }
  if (c.locked && !c.lockMessage) {
    warn('lockMessage', 'Locked without a message — the app shows a generic one');
  }
  if (c.country && !/^[A-Z]{2}$/.test(c.country) && c.country !== 'GLOBAL') {
    warn('country', 'Country should be a 2-letter ISO code');
  }

  return { ok: errors.length === 0, errors, warnings };
}

function looksLikeUuid(v) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
}

// ---------------------------------------------------------------------------
// Share-link / profile parsing
// ---------------------------------------------------------------------------

function b64decode(s) {
  let t = String(s || '').trim().replace(/-/g, '+').replace(/_/g, '/');
  while (t.length % 4) t += '=';
  try {
    const bin = atob(t);
    // Recover UTF-8 (names are often non-ASCII).
    const bytes = Uint8Array.from(bin, (ch) => ch.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  } catch {
    try {
      return atob(t);
    } catch {
      return '';
    }
  }
}

function splitFirst(s, sep) {
  const i = s.indexOf(sep);
  return i < 0 ? [s, ''] : [s.slice(0, i), s.slice(i + 1)];
}

export function parseOvpnRemote(text) {
  const m = /^\s*remote\s+(\S+)(?:\s+(\d+))?(?:\s+(tcp|udp))?/im.exec(text || '');
  if (!m) return { host: '', port: 0, proto: '' };
  const protoLine = /^\s*proto\s+(tcp|udp)/im.exec(text || '');
  const proto = (m[3] || (protoLine && protoLine[1]) || 'udp').toLowerCase();
  return {
    host: m[1] || '',
    port: parseInt(m[2] || '', 10) || (proto === 'tcp' ? 443 : 1194),
    proto,
  };
}

/**
 * Parse any supported config text into partial canonical fields.
 * Supports vless:// vmess:// trojan:// ss:// hy2:// darktunnel:// , a raw
 * .ovpn body, a raw WireGuard .conf body and a bare JSON object.
 * Returns null when nothing matched.
 */
export function parseAnyConfigText(text) {
  const t = String(text || '').trim();
  if (!t) return null;
  try {
    if (t.startsWith('vless://')) return parseVless(t);
    if (t.startsWith('vmess://')) return parseVmess(t);
    if (t.startsWith('trojan://')) return parseTrojan(t);
    if (t.startsWith('ss://')) return parseSs(t);
    if (t.startsWith('hysteria2://') || t.startsWith('hy2://')) return parseHysteria(t);
    if (t.startsWith('darktunnel://')) return parseDarkTunnel(t);
    // App share envelope: `armantunnel://<base64url(json)>` (the historical
    // `senseitunnel://` spelling stays accepted so old pasted links import).
    if (t.startsWith('armantunnel://') || t.startsWith('senseitunnel://')) {
      const raw = t.slice(t.indexOf('://') + 3).replace(/-/g, '+').replace(/_/g, '/');
      const padded = raw + '='.repeat((4 - raw.length % 4) % 4);
      const o = JSON.parse(atob(padded));
      return Array.isArray(o) ? o[0] : o;
    }
    // Raw wg-client conf: [Interface] keys + the [Peer] Endpoint it dials.
    if (/^\s*\[interface\]\s*$/im.test(t)) {
      const ep = t.match(/^\s*endpoint\s*=\s*([A-Za-z0-9.\-]+):(\d{1,5})\s*$/im);
      const name = ep ? 'WireGuard ' + ep[1] : 'WireGuard';
      return {
        protocol: 'wireguard',
        wireguardConfig: t,
        address: ep ? ep[1] : '',
        port: ep ? parseInt(ep[2], 10) : 51820,
        name,
        note: name,
      };
    }
    if (/(^|\n)\s*remote\s+\S+/i.test(t) && /(dev tun|dev tap|<ca>|client|proto |auth-user-pass)/i.test(t)) {
      const r = parseOvpnRemote(t);
      return {
        protocol: 'openvpn',
        address: r.host,
        port: r.port,
        ovpnConfig: t,
        name: r.host ? 'OpenVPN ' + r.host : 'OpenVPN',
      };
    }
    if (t.startsWith('{')) {
      const o = JSON.parse(t);
      if (o && typeof o === 'object') return o;
    }
  } catch {
    /* fall through */
  }
  return null;
}

function nameFromHash(u, fallback) {
  const h = (u.hash || '').replace(/^#/, '');
  if (!h) return fallback;
  try {
    return decodeURIComponent(h);
  } catch {
    return h;
  }
}

function parseVless(link) {
  const u = new URL(link);
  const q = u.searchParams;
  const name = nameFromHash(u, 'VLESS ' + u.hostname);
  return {
    protocol: 'vless',
    name,
    note: name,
    address: u.hostname,
    port: parseInt(u.port, 10) || 443,
    uuid: decodeURIComponent(u.username || ''),
    transport: q.get('type') || 'tcp',
    security: q.get('security') || 'none',
    encryption: q.get('encryption') || 'none',
    sni: q.get('sni') || q.get('peer') || '',
    wsHost: q.get('host') || '',
    path: q.get('path') || '',
    serviceName: q.get('serviceName') || '',
    flow: q.get('flow') || '',
    fingerprint: q.get('fp') || '',
    publicKey: q.get('pbk') || '',
    shortId: q.get('sid') || '',
  };
}

function parseTrojan(link) {
  const u = new URL(link);
  const q = u.searchParams;
  const name = nameFromHash(u, 'Trojan ' + u.hostname);
  const pass = decodeURIComponent(u.username || '');
  return {
    protocol: 'trojan',
    name,
    note: name,
    address: u.hostname,
    port: parseInt(u.port, 10) || 443,
    password: pass,
    uuid: pass,
    transport: q.get('type') || 'tcp',
    security: q.get('security') || 'tls',
    sni: q.get('sni') || q.get('peer') || '',
    wsHost: q.get('host') || '',
    path: q.get('path') || '',
    serviceName: q.get('serviceName') || '',
    fingerprint: q.get('fp') || '',
    flow: q.get('flow') || '',
  };
}

/**
 * Hysteria 2 share link: `hysteria2://auth@host:port?sni=…&insecure=1#name`
 * (also the `hy2://` shorthand). The auth userinfo is the password; empty SNI
 * (or insecure=1) is the app's accept-any-cert (insecure) mode.
 */
function parseHysteria(link) {
  const u = new URL(link.replace(/^hy2:\/\//, 'hysteria2://'));
  const q = u.searchParams;
  const name = nameFromHash(u, 'Hysteria ' + u.hostname);
  const insecure = q.get('insecure') === '1';
  return {
    protocol: 'hysteria',
    name,
    note: name,
    address: u.hostname,
    port: parseInt(u.port, 10) || 443,
    password: decodeURIComponent(u.username || ''),
    sni: q.get('sni') || '',
    security: insecure ? 'none' : 'tls',
  };
}

function parseVmess(link) {
  const body = link.replace(/^vmess:\/\//, '');
  const decoded = b64decode(body);
  if (!decoded || !decoded.trim().startsWith('{')) return null;
  const d = JSON.parse(decoded);
  const net = String(d.net || 'tcp').toLowerCase();
  const name = d.ps || 'VMess ' + (d.add || '');
  return {
    protocol: 'vmess',
    name,
    note: name,
    address: d.add || '',
    port: parseInt(d.port, 10) || 443,
    uuid: d.id || '',
    alterId: d.aid != null ? String(d.aid) : '0',
    transport: net,
    // vmess links use tls: "tls" | "" | "reality"
    security: normalizeSecurity(d.tls === true ? 'tls' : d.tls),
    encryption: d.scy || 'auto',
    sni: d.sni || '',
    wsHost: d.host || '',
    // For gRPC the service name lives in `path` — moving it to `path` breaks
    // grpcSettings on the device, so route it correctly here.
    path: net === 'grpc' ? '' : d.path || '',
    serviceName: net === 'grpc' ? d.path || '' : '',
    fingerprint: d.fp || '',
  };
}

function parseSs(link) {
  let rest = link.slice(5);
  let name = '';
  const h = rest.indexOf('#');
  if (h >= 0) {
    try {
      name = decodeURIComponent(rest.slice(h + 1));
    } catch {
      name = rest.slice(h + 1);
    }
    rest = rest.slice(0, h);
  }
  const qi = rest.indexOf('?');
  let query = '';
  if (qi >= 0) {
    query = rest.slice(qi + 1);
    rest = rest.slice(0, qi);
  }
  let method = '';
  let password = '';
  let address = '';
  let port = 0;
  if (rest.includes('@')) {
    const at = rest.lastIndexOf('@');
    const creds = b64decode(rest.slice(0, at)) || decodeURIComponent(rest.slice(0, at));
    [method, password] = splitFirst(creds, ':');
    const hp = rest.slice(at + 1).split(':');
    address = hp[0];
    port = parseInt(hp[1], 10) || 0;
  } else {
    const dec = b64decode(rest);
    const at = dec.lastIndexOf('@');
    [method, password] = splitFirst(dec.slice(0, at), ':');
    const hp = dec.slice(at + 1).split(':');
    address = hp[0];
    port = parseInt(hp[1], 10) || 0;
  }
  const q = new URLSearchParams(query);
  const plugin = q.get('plugin') || '';
  const out = {
    protocol: 'shadowsocks',
    name: name || 'SS ' + address,
    note: name,
    address,
    port: port || 443,
    password,
    encryption: method,
  };
  // v2ray-plugin / simple-obfs carry the ws transport in the plugin option.
  if (/v2ray-plugin/.test(plugin)) {
    out.transport = 'ws';
    const opts = plugin.split(';');
    for (const o of opts) {
      const [k, v] = splitFirst(o, '=');
      if (k === 'path') out.path = v;
      if (k === 'host') out.wsHost = v;
      if (k === 'tls') out.security = 'tls';
    }
  }
  return out;
}

/// darktunnel:// share = base64url(JSON). Mirrors the app's
/// `ServerConfig.fromDarkTunnelUri` flattening so the two agree.
function parseDarkTunnel(link) {
  // Bulk shares glue commas/newlines/emoji onto the link; the payload
  // alphabet never contains them, so cutting at the first foreign char fixes
  // the "throws on `darktunnel://…,`" import failure. Mirrors the app's
  // `DarkTunnelCodec.b64Trim`.
  const m = /^darktunnel:\/\/[A-Za-z0-9_\-%+/=]+/.exec(link);
  if (!m) return null;
  const payload = m[0].replace(/^darktunnel:\/\//, '');
  let decoded = '';
  try {
    decoded = b64decode(decodeURIComponent(payload));
  } catch {
    decoded = b64decode(payload);
  }
  if (!decoded.trim().startsWith('{')) return null;
  const d = JSON.parse(decoded);
  // Locked envelopes can only be opened by the app (AES-CFB + msgpack live in
  // darktunnel_codec.dart). The clear section is a decoy — importing it here
  // would create an empty server, so refuse with a clear reason instead.
  if (typeof d.encryptedLockedConfig === 'string' && d.encryptedLockedConfig) {
    return null;
  }
  const out = { ...d };

  if ((d.type === 'SSH' || d.type === 'SSH_DNSTT') && (d.sshTunnelConfig || d.sshDnsttTunnelConfig)) {
    const tunnel = d.sshTunnelConfig || d.sshDnsttTunnelConfig || {};
    const ssh = tunnel.sshConfig || {};
    const inj = tunnel.injectConfig || {};
    const dnstt = tunnel.dnsttConfig || {};
    out.protocol = d.type === 'SSH_DNSTT' ? 'ssh_dnstt' : 'ssh';
    out.address = out.address || ssh.host || '';
    out.port = out.port || ssh.port || 22;
    out.sshUser = out.sshUser || ssh.username || '';
    out.sshPass = out.sshPass || ssh.password || '';
    out.injectMode = out.injectMode || inj.mode || '';
    out.sni = out.sni || inj.serverNameIndication || '';
    out.payload = out.payload || inj.payload || '';
    out.injectHost = out.injectHost || inj.host || inj.proxyHost || inj.SquidProxy || inj.squidProxy || '';
    out.injectPort = out.injectPort || inj.port || inj.proxyPort || inj.SquidPort || inj.squidPort || '';
    out.dnsttResolver = out.dnsttResolver || dnstt.udpDnsHost || '';
    out.dnsttServer = out.dnsttServer || dnstt.serverName || '';
    out.dnsttKey = out.dnsttKey || dnstt.publicKey || '';
  } else if ((d.type === 'VLESS' || d.type === 'VMESS' || d.type === 'TROJAN') &&
    (d.vlessTunnelConfig || d.vmessTunnelConfig || d.trojanTunnelConfig)) {
    const tunnel = d.vlessTunnelConfig || d.vmessTunnelConfig || d.trojanTunnelConfig || {};
    const v = tunnel.v2rayConfig || {};
    const inj = tunnel.injectConfig || {};
    out.protocol = String(d.type).toLowerCase();
    out.address = out.address || v.host || '';
    out.port = out.port || v.port || 443;
    out.uuid = out.uuid || v.uuid || '';
    out.wsHost = out.wsHost || v.wsHeaderHost || '';
    // Transport comes from transportNetwork — with the SAME exception the app
    // makes (server_config.dart): shares that OMIT transportNetwork but carry
    // wsPath/wsHeaderHost are WebSocket. Explicit "Tcp" + wsPath stays TCP.
    const netRaw = String(v.transportNetwork || v.net || v.network || '').toLowerCase().trim();
    const isWs = netRaw === 'ws' || netRaw === 'websocket' ||
      (!netRaw && Boolean(v.wsPath));
    const isGrpc = netRaw === 'grpc';
    out.transport = isWs ? 'ws' : (isGrpc ? 'grpc' : 'tcp');
    const isTcp = !isWs && !isGrpc;
    if (!isTcp) {
      out.path = out.path || v.wsPath || '';
    }
    out.sni = out.sni || v.serverNameIndication || '';
    if (v.tls === true || (v.tls == null && out.sni)) out.security = out.security || 'tls';

    const enabled = !inj || inj.enabled !== false;
    if (enabled && inj && typeof inj === 'object') {
      if (inj.payload) out.payload = out.payload || inj.payload;
      out.injectHost = out.injectHost || inj.host || inj.proxyHost || inj.SquidProxy || inj.squidProxy || '';
      out.injectPort = out.injectPort || inj.port || inj.proxyPort || inj.SquidPort || inj.squidPort || '';
      if (isTcp) {
        // SSL(TCP) = TLS + SNI wrap only. `wsPath` is meaningless on TCP —
        // a path there is NOT an opener and must never reach the config.
        out.injectMode = out.injectMode || (out.sni ? 'directSni' : 'direct');
      } else {
        // ws/grpc: honour the share's own mode (PROXY on a bug host).
        out.injectMode = out.injectMode || inj.mode || '';
      }
    }
  }
  return out;
}

/**
 * Split a subscription blob (base64 of newline-separated links, or raw links)
 * into individual share links.
 */
export function splitSubscription(raw) {
  let text = String(raw || '').trim();
  if (!/:\/\//.test(text)) {
    const dec = b64decode(text.replace(/\s+/g, ''));
    if (dec && /:\/\//.test(dec)) text = dec;
  }
  return text
    .split(/\r?\n/)
    .flatMap((l) => {
      const t = l.trim();
      // Bulk darktunnel shares are comma-joined; the base64url payload never
      // contains a comma, so splitting on it is safe.
      if (/^darktunnel:\/\//i.test(t)) {
        return t.split(/,(?=darktunnel:\/\/)/i).map((x) => x.replace(/,+$/, ''));
      }
      return [t];
    })
    .filter((l) => /^(vless|vmess|trojan|ss|darktunnel|armantunnel|senseitunnel):\/\//.test(l));
}

/**
 * A `vless://` / `vmess://` / `trojan://` / `ss://` share link rebuilt from a
 * canonical config. Used by the panel's QR / copy-link actions so what the user
 * shares is exactly what the app stores.
 */
export function buildShareLink(c) {
  const label = encodeURIComponent(c.name || c.address || 'arman');
  const q = new URLSearchParams();
  const addTransport = () => {
    q.set('type', c.transport || 'tcp');
    q.set('security', c.security || 'none');
    if (c.sni) q.set('sni', c.sni);
    if (c.host) q.set('host', c.host);
    if (c.path) q.set('path', c.path);
    if (c.serviceName) q.set('serviceName', c.serviceName);
    if (c.fingerprint) q.set('fp', c.fingerprint);
    if (c.flow) q.set('flow', c.flow);
    if (c.publicKey) q.set('pbk', c.publicKey);
    if (c.shortId) q.set('sid', c.shortId);
  };
  switch (c.protocol) {
    case 'vless': {
      addTransport();
      q.set('encryption', c.encryption || 'none');
      return `vless://${encodeURIComponent(c.uuid)}@${c.address}:${c.port}?${q}#${label}`;
    }
    case 'trojan': {
      addTransport();
      return `trojan://${encodeURIComponent(c.password || c.uuid)}@${c.address}:${c.port}?${q}#${label}`;
    }
    case 'vmess': {
      const o = {
        v: '2',
        ps: c.name || '',
        add: c.address,
        port: String(c.port),
        id: c.uuid,
        aid: c.alterId || '0',
        scy: c.encryption || 'auto',
        net: c.transport || 'tcp',
        type: 'none',
        host: c.host || '',
        path: c.transport === 'grpc' ? c.serviceName || '' : c.path || '',
        tls: c.security === 'none' ? '' : c.security,
        sni: c.sni || '',
        fp: c.fingerprint || '',
      };
      const json = JSON.stringify(o);
      const b64 = btoa(String.fromCharCode(...new TextEncoder().encode(json)));
      return 'vmess://' + b64;
    }
    case 'shadowsocks': {
      const creds = `${c.encryption || 'aes-256-gcm'}:${c.password || ''}`;
      const b64 = btoa(String.fromCharCode(...new TextEncoder().encode(creds)));
      return `ss://${b64}@${c.address}:${c.port}#${label}`;
    }
    default:
      // SSH / SSH+DNSTT / OpenVPN have no standard share URI — the app imports
      // these as JSON, so hand back the canonical JSON instead of a fake link.
      return JSON.stringify(toAppConfig(c), null, 2);
  }
}

/**
 * The exact object shape written into the encrypted bundle the app downloads.
 * Admin-only bookkeeping (active/priority/maxConnections/updatedAt) is stripped
 * so the device payload stays small and every remaining key is one the app reads.
 */
export function toAppConfig(c) {
  // A vaulted VIP config publishes WITHOUT its real endpoint: the app resolves
  // address/port from GET /api/vip/resolve after a verified rewarded-ad unlock.
  // The stored `vault` is only an opt-in marker (it may be set on the config or
  // inherited from the server it rides); the PUBLISHED vault id is always this
  // config's own id, which is what the resolve endpoint keys on.
  const vaulted = c.vip === true && str(c.vault) !== '';
  return {
    id: c.id,
    name: c.name,
    note: c.note,
    protocol: c.protocol,
    transport: c.transport,
    security: c.security,
    address: vaulted ? '' : c.address,
    port: vaulted ? 0 : c.port,
    uuid: c.uuid,
    alterId: c.alterId,
    password: c.password,
    encryption: c.encryption,
    sni: c.sni,
    path: c.path,
    host: c.host,
    serviceName: c.serviceName,
    fingerprint: c.fingerprint,
    flow: c.flow,
    publicKey: c.publicKey,
    shortId: c.shortId,
    isOfficial: c.isOfficial,
    logoBase64: c.logoBase64,
    logoUrl: c.logoUrl,
    payload: c.payload,
    sshUser: c.sshUser,
    sshPass: c.sshPass,
    // The injection front IS an endpoint: a bug/squid host is frequently the
    // real relay the config points at, so a vaulted config must not ship it
    // in the bundle either. /api/vip/resolve hands it back after a verified
    // unlock, and the app merges it then.
    injectHost: vaulted ? '' : c.injectHost,
    injectPort: vaulted ? '' : c.injectPort,
    injectPayload: c.injectPayload,
    injectMode: c.injectMode,
    dnsttServer: c.dnsttServer,
    dnsttKey: c.dnsttKey,
    dnsttResolver: c.dnsttResolver,
    ovpnConfig: c.ovpnConfig,
    wireguardConfig: c.wireguardConfig,
    psiphonRegion: c.psiphonRegion,
    payloadEnhanced: c.payloadEnhanced,
    sshCompression: c.sshCompression,
    category: c.category,
    capability: str(c.capability).toUpperCase() || inferCapability(c),
    // Full server capability set (multi-cap nodes) + tweak metadata the app
    // needs for its own re-join: riding family ('mixed' = cross-engine pool)
    // and the preferred-anchor serverId.
    capabilities: normalizeCapabilities(c.capabilities),
    family: str(c.family).toLowerCase() || '',
    serverId: str(c.serverId) || '',
    // Failover pool: alternate compatible servers, ready-to-join endpoint
    // sets. Absent/empty on legacy standalone configs.
    //
    // A pool entry carries its OWN address/port, so for a vaulted config the
    // list is the biggest endpoint leak of all — it is stripped here and
    // restored from /api/vip/resolve after the unlock.
    serverPool: vaulted ? [] : (Array.isArray(c.serverPool) ? c.serverPool : []),
    country: c.country,
    region: c.region,
    server: c.server,
    author: c.author,
    encryptionKey: c.encryptionKey,
    locked: c.locked,
    lockMessage: c.lockMessage,
    expiresAt: c.expiresAt,
    vip: c.vip === true,
    vipUnlockHours: clampInt(c.vipUnlockHours, 1, 24, 2),
    vipNote: str(c.vipNote),
    // Server-side vault: a vaulted VIP config (vault === id) publishes the opaque
    // id instead of its real address/port, and the app resolves the endpoint via
    // GET /api/vip/resolve after a verified unlock. Non-vaulted configs (vault
    // blank, or any non-VIP) publish normally.
    vault: vaulted ? str(c.id) : '',
  };
}

/**
 * Project a PROXY (a server entity) into an app-facing node of its own.
 *
 * A proxy used to reach users only by riding a tweak: the app feed is
 * `configs joined with servers` and `compatibleServersFor` matches on
 * `capabilities`, so a proxy nobody bothered to write a tweak for was
 * completely invisible in the app. This makes the proxy a first-class node —
 * an empty tweak joined with just the server — so it shows up in the app like
 * any other config, and its OWN vip/vault/lock flags apply directly instead of
 * only being inherited by tweaks that ride it.
 *
 * `capability` is DIRECT: a bare proxy IS a plain connection, there is no tweak
 * method on it. (That is exactly what `inferCapability` returns for it.)
 *
 * Like [joinServerIntoConfig] this returns the RAW joined shape — it does NOT
 * apply [toAppConfig]. The publish path (`loadActiveConfigs`) projects once, and
 * the vault resolve route deliberately needs the un-redacted endpoint.
 */
export function serverToAppConfig(s) {
  return normalizeConfig({
    ...serverJoinFields({}, s),
    id: s.id,
    name: s.name,
    // Only a real note (the admin's customizable message). The old
    // `|| s.name` fallback showed the server name under every proxy card.
    note: s.note || '',
    capability: 'DIRECT',
    family: '',
    // A standalone proxy has no pool of its own — it IS one endpoint. (A
    // tweak that rides several servers still gets its serverPool from the
    // join.)
    serverPool: [],
    priority: s.priority,
    active: s.active,
  });
}

/// True when a server should publish as its OWN app node — i.e. it is an
/// actual PROXY endpoint (socks/http_proxy/psiphon). Tunnel ENDPOINT servers
/// (ssh/ssh_dnstt/vless/vmess/trojan/shadowsocks/openvpn/wireguard) must NOT:
/// they are the anchors tweaks ride, and publishing them standalone flooded
/// every Configs section with duplicate bare servers (the tweak place showed
/// the server list) — and old app versions, which never saw server nodes at
/// all, got a feed full of entries they cannot group. A proxy protocol is a
/// plain connection, so it is the only server kind that is a first-class node.
export function isProxyNode(s) {
  if (!s || typeof s !== 'object') return false;
  const p = normalizeProtocol(s.protocol);
  return p === 'socks' || p === 'http_proxy' || p === 'psiphon';
}

/// De-dup key: same endpoint + same credential is the same node — UNLESS it
/// carries a distinct injection variant. The same host/port/credential may
/// legitimately exist multiple times with a different payload/SNI/bug-host,
/// so those fields are part of the key. A config with no injection set (all
/// blanks) still collides with another blank-injection node on the same
/// endpoint, which is the duplicate we DO want to catch.
export function dedupeKey(c) {
  const variant = [
    c.injectMode || '',
    c.injectHost || '',
    c.injectPort || '',
    c.injectPayload || '',
    c.payload || '',
    c.sni || '',
  ].join('|');
  return [c.protocol, c.address, c.port, c.uuid || c.password || c.sshUser || '', variant]
    .join('|')
    .toLowerCase();
}

// ---------------------------------------------------------------------------
// Payload token library
//
// Payload fields may reference named tokens (`[RYZE]`, `[ROBI]`, `[AIRTEL]`) and
// intrinsic placeholders that are expanded just before the bundle is written,
// so the admin writes `payload=[ROBI]` and the app receives the full template.
// ---------------------------------------------------------------------------

export const DEFAULT_PAYLOAD_DEFS = {
  RYZE: 'HTTP/1.1[crlf]Host: telegram.org[crlf]User-Agent: [ua][crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf]Sec-WebSocket-Version: 13[crlf][crlf]',
  ROBI: 'HTTP/1.1[crlf]Host: viber.com[crlf]User-Agent: [ua][crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf]Sec-WebSocket-Version: 13[crlf][crlf]',
  AIRTEL: 'HTTP/1.1[crlf]Host: viber.com[crlf]User-Agent: [ua][crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf]Sec-WebSocket-Version: 13[crlf][crlf]',
};

const INTRINSIC_TOKENS = {
  ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
};

/// Expand `[TOKEN]` payload references against a defs map, resolve intrinsic
/// placeholders, and leave anything unknown untouched (safer than dropping it).
/// `context` can supply `host` for the optional `[host]` placeholder.
/// A resolved def may itself carry placeholders — `payload=[RYZE]` must yield
/// the FULLY expanded template, so expansion repeats (bounded) while the value
/// keeps changing and still contains brackets.
export function expandPayload(value, defs, context, depth = 0) {
  if (!value) return value;
  const d = defs || {};
  const out = String(value).replace(/\\\[(\w+)\]/g, '[$1]').replace(/\[(\w+)\]/g, (m, key) => {
    const k = String(key).toUpperCase();
    if (k === 'CRLF') return '\r\n';
    if (k === 'UA') return INTRINSIC_TOKENS.ua;
    if (k === 'HOST') return context?.host || '[HOST]';
    return d[k] !== undefined && d[k] !== null ? String(d[k]) : m;
  });
  if (depth < 3 && out !== value && out.includes('[')) {
    return expandPayload(out, d, context, depth + 1);
  }
  return out;
}

/// Expand every payload-ish field on a config that is about to be written to
/// the device bundle. Returns a new normalized config with tokens resolved.
export function expandConfigPayloads(c, defs) {
  const ctx = { host: c.host || c.sni || '' };
  return {
    ...c,
    payload: expandPayload(c.payload, defs, ctx),
    injectPayload: expandPayload(c.injectPayload, defs, ctx),
  };
}

// ---------------------------------------------------------------------------
// Server entity — the endpoint + credentials ("server add" flow).
//
// A Config is a connection METHOD (payload/SNI ticks) referencing a Server by
// id; the two are edited separately in the panel and JOINED at publish time,
// so the app keeps receiving the flat config shape it has always consumed.
// ---------------------------------------------------------------------------

export function newServerId() {
  return 'srv_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

/** Canonical Server object — every endpoint/credential field the app knows. */
export function normalizeServer(input, { keepId = true } = {}) {
  const d = input && typeof input === 'object' ? input : {};
  const m = stripEmpty(d);
  const protocol = normalizeProtocol(m.protocol) || (m.ovpnConfig ? 'openvpn' : 'vless');
  const transport = normalizeTransport(m.transport ?? m.net ?? m.type);
  const security = normalizeSecurity(m.security ?? m.tls);
  const ovpnConfig = str(m.ovpnConfig ?? m.ovpn);

  let address = str(m.address ?? m.host ?? m.add ?? m.serverHost);
  let port = int(m.port ?? m.serverPort, 0);
  if (protocol === 'openvpn' && ovpnConfig) {
    const remote = parseOvpnRemote(ovpnConfig);
    if (!address && remote.host) address = remote.host;
    if (!port && remote.port) port = remote.port;
  }
  if (!port) port = defaultPortFor(protocol, security);

  // `host` disambiguation identical to normalizeConfig.
  const explicitAddress = str(m.address ?? m.add ?? m.serverHost) !== '';
  const hostHeader = str(m.wsHost ?? m.hostHeader ?? m.wsHeaderHost ?? m.hostOverride) ||
    (explicitAddress ? str(m.host) : '');

  const catRaw = normalizeCategoryName(m.category);
  const looksLikeCountry =
    catRaw.length === 2 && /^[a-z]{2}$/i.test(catRaw) && !CATEGORIES.includes(catRaw.toLowerCase());
  const country = str(m.country ?? m.countryCode).toUpperCase() ||
    (looksLikeCountry ? catRaw.toUpperCase() : '') ||
    guessCountry(address, m.name, m.region);

  const out = {
    id: keepId && str(m.id) ? str(m.id) : newServerId(),
    name: str(m.name ?? m.ps) || (address ? `${protocolLabel(protocol)} ${address}` : ''),
    note: str(m.note ?? m.description ?? m.name),
    protocol,
    address,
    port,
    transport,
    security,
    uuid: str(m.uuid ?? m.userId),
    alterId: str(m.alterId ?? m.aid),
    password: str(m.password ?? m.pass),
    encryption: str(m.encryption ?? m.method ?? m.scy ?? m.cipher),
    host: hostHeader,
    // WS path is part of the SERVER (the backend's real route). It was
    // missing here once — the form value was silently dropped, tweaks joined
    // with an empty path and xray's handshake 404'd after the payload's
    // fake 101.
    path: str(m.path ?? m.wsPath),
    serviceName: str(m.serviceName),
    fingerprint: str(m.fingerprint ?? m.fp),
    flow: str(m.flow),
    publicKey: str(m.publicKey ?? m.pbk),
    shortId: str(m.shortId ?? m.sid),
    sshUser: str(m.sshUser ?? m.username ?? m.user),
    sshPass: str(m.sshPass),
    sshCompression: bool(m.sshCompression),
    dnsttServer: str(m.dnsttServer ?? m.dnsttServerName),
    dnsttKey: str(m.dnsttKey ?? m.dnsttPublicKey),
    dnsttResolver: str(m.dnsttResolver ?? m.dnsttUdpDnsHost),
    ovpnConfig,
    wireguardConfig: str(m.wireguardConfig),
    psiphonRegion: str(m.psiphonRegion),
    category: looksLikeCountry ? 'global' : normalizeCategoryValue(catRaw),
    // Capability types this server supports — tweaks of these types (and
    // the same protocol family) may ride on it. Legacy single-category
    // servers migrate to [category] when no explicit list exists.
    capabilities: normalizeCapabilities(m.capabilities),
    country,
    region: str(m.region ?? m.location),
    logoBase64: str(m.logoBase64),
    logoUrl: str(m.logoUrl),
    author: str(m.author),
    isOfficial: m.isOfficial === undefined ? true : bool(m.isOfficial),
    locked: bool(m.locked),
    lockMessage: str(m.lockMessage),
    expiresAt: Math.max(0, int(m.expiresAt, 0)),
    vip: bool(m.vip),
    vipUnlockHours: int(m.vipUnlockHours, 0) > 0 ? clampInt(m.vipUnlockHours, 1, 24, 2) : 2,
    vipNote: str(m.vipNote),
    // Vaulting is a per-SERVER decision: a VIP server can have its endpoint
    // kept server-side for every tweak that rides it.
    vault: str(m.vault),
    encryptionKey: str(m.encryptionKey),
    active: m.active === undefined ? true : bool(m.active),
    priority: int(m.priority, 0),
    createdAt: str(m.createdAt) || new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  if (protocol === 'vless' && !out.encryption) out.encryption = 'none';
  if (protocol === 'vmess' && !out.encryption) out.encryption = 'auto';
  if (protocol === 'vmess' && !out.alterId) out.alterId = '0';
  if (protocol === 'shadowsocks' && !out.encryption) out.encryption = 'aes-256-gcm';
  if (protocol === 'trojan' && !out.password) out.password = out.uuid;
  if (protocol === 'trojan' && !out.uuid) out.uuid = out.password;
  if (isV2ray(protocol) && security !== 'none' && !out.fingerprint) out.fingerprint = 'chrome';
  if (transport === 'grpc' && !out.serviceName && out.path) {
    out.serviceName = out.path.replace(/^\//, '');
  }
  // Note is a customizable, clearable field (mirrors normalizeConfig) — the
  // old sync to name put the server name under every proxy card.
  out.note = str(m.note ?? '');

  return out;
}

/** Validate a Server. Same rules as a config's endpoint/credential half. */
export function validateServer(s) {
  const errors = [];
  const warnings = [];
  const err = (field, message) => errors.push({ field, message });
  const warn = (field, message) => warnings.push({ field, message });

  if (!s.name) err('name', 'Name is required');
  if (!PROTOCOLS.includes(s.protocol)) err('protocol', 'Unknown protocol');
  if (!s.address) err('address', 'Server address is required');
  else if (/\s/.test(s.address)) err('address', 'Address must not contain spaces');
  if (!(s.port >= 1 && s.port <= 65535)) err('port', 'Port must be 1–65535');

  switch (s.protocol) {
    case 'vless':
    case 'vmess':
      if (!s.uuid) err('uuid', 'UUID is required');
      break;
    case 'trojan':
      if (!s.password) err('password', 'Trojan password is required');
      break;
    case 'shadowsocks':
      if (!s.password) err('password', 'Shadowsocks password is required');
      if (!s.encryption) err('encryption', 'Shadowsocks method is required');
      break;
    case 'ssh':
    case 'ssh_dnstt':
      // Credentials are OPTIONAL on a proxy: the panel must let a bare
      // endpoint be saved (it may be filled in per-connection, shared with
      // other tweaks, or the protocol may not need a password at all). The
      // engine is the backstop — `startSshSocks` refuses a blank user/pass
      // with a clear connect-time error instead of the admin being blocked
      // from saving the proxy in the first place.
      if (!s.sshUser) warn('sshUser', 'No SSH username — an SSH proxy will not connect until one is set');
      if (!s.sshPass) warn('sshPass', 'No SSH password — an SSH proxy will not connect until one is set');
      break;
    case 'openvpn':
      if (!s.ovpnConfig) err('ovpnConfig', 'The .ovpn profile body is required');
      else if (!/(^|\n)\s*remote\s+\S+/i.test(s.ovpnConfig)) {
        err('ovpnConfig', 'Profile has no `remote` line');
      }
      break;
    default:
      break;
  }

  if (isV2ray(s.protocol)) {
    if (s.transport === 'grpc' && !s.serviceName) err('serviceName', 'gRPC needs a service name');
    if (s.transport === 'ws' && !s.path) warn('path', 'WebSocket without a path — the backend usually only accepts its real path (404 otherwise)');
  }
  if (s.country && !/^[A-Z]{2}$/.test(s.country) && s.country !== 'GLOBAL') {
    warn('country', 'Country should be a 2-letter ISO code');
  }
  if (s.expiresAt > 0 && s.expiresAt < Date.now()) warn('expiresAt', 'Expiry is already in the past');
  if (s.expiresAt > 0 && s.expiresAt < 1e12) err('expiresAt', 'Expiry must be a millisecond epoch');

  return { ok: errors.length === 0, errors, warnings };
}

/** Validate a TWEAK (a config that references a server by id).
 *  Endpoint/credentials are NOT required — they come from the server. A bare
 *  tweak (no payload/SNI — plain server connection for IP change) is valid;
 *  the method-less case only warns. */
export function validateVariantConfig(c, servers) {
  const errors = [];
  const warnings = [];
  const err = (field, message) => errors.push({ field, message });
  const warn = (field, message) => warnings.push({ field, message });

  if (!c.name) err('name', 'Name is required');
  // A tweak needs EITHER a capability type (new model — joined with every
  // compatible server) or a legacy serverId (kept as preferred anchor).
  if (!c.capability && !c.serverId) {
    err('capability', 'Pick a tweak type (or a legacy server)');
  } else if (servers && servers.length > 0 && c.capability) {
    const pool = compatibleServersFor(c, servers);
    if (pool.length === 0) {
      const selected = normalizeServerIds(c.serverIds).length > 0 ? ' selected' : '';
      err('capability', `No${selected} server supports [${str(c.capability).toUpperCase()}] on this protocol family — tick a compatible server first`);
    }
  }
  if ((c.injectMode === 'proxy' || c.injectMode === 'proxySni') && !c.injectHost) {
    err('injectHost', 'Proxy inject modes need a bug/proxy host or [Default]');
  }
  if (c.injectMode === 'none' && !c.payload && !c.sni) {
    warn('payload', 'No method selected — this variant adds nothing over the server');
  }
  if (c.expiresAt > 0 && c.expiresAt < Date.now()) warn('expiresAt', 'Expiry is already in the past');

  return { ok: errors.length === 0, errors, warnings };
}

/**
 * JOIN: merge a method config with its Server entity into the flat shape the
 * app consumes. The config wins for method fields (payload/SNI/inject); the
 * server supplies endpoint + credentials + presentation defaults. `path` and
 * `sni` stay per-config (v2ray paths and bug hosts genuinely differ between
 * variants of one server); everything else inherits.
 * Falls back to the raw config when it has no serverId or the server is
 * missing (legacy configs keep working untouched).
 */
/**
 * SERVER ↔ TWEAK compatibility: a server is compatible with a tweak when
 *   · the server's capabilities include the tweak's capability type, AND
 *   · they share a protocol family (an SSH payload can't ride a vless host).
 * A tweak with no capability falls back to [inferCapability]; a tweak with a
 * legacy serverId keeps that server FIRST (preferred anchor) when it is still
 * compatible.
 */
export function compatibleServersFor(config, servers) {
  const capability = str(config.capability).toUpperCase() || inferCapability(config);
  const family = str(config.family).toLowerCase() || familyOfProtocol(str(config.protocol));
  const list = (servers || []).filter((s) => s.active !== false);
  // family 'mixed' (or '*'): the tweak rides compatible servers of EVERY
  // protocol family — a real cross-engine pool. Any other value must match
  // the server's family exactly.
  const match = list.filter((s) => {
    if (!(s.capabilities || []).map((c) => String(c).toUpperCase()).includes(capability)) return false;
    if (family === 'mixed' || family === '*') return true;
    return familyOfProtocol(String(s.protocol)) === family;
  });
  const selectedIds = normalizeServerIds(config.serverIds);
  const selected = selectedIds.length > 0
    ? match.filter((s) => selectedIds.includes(s.id))
    : match;
  // Legacy preferred server first (when still compatible), then the rest in
  // panel order (servers are priority-sorted upstream).
  const preferred = str(config.serverId);
  const anchor = preferred ? selected.find((s) => s.id === preferred) : null;
  if (anchor) return [anchor, ...selected.filter((s) => s.id !== anchor.id)];
  return selected;
}

function familyOfProtocol(p) {
  if (p === 'ssh' || p === 'ssh_dnstt') return 'ssh';
  if (p === 'openvpn') return 'openvpn';
  if (p === 'wireguard') return 'wireguard';
  if (p === 'socks' || p === 'http_proxy') return 'proxy';
  if (p === 'psiphon') return 'psiphon';
  return 'v2ray';
}

export { familyOfProtocol as familyOf };

/** The server-side fields a pool entry carries (everything except the
 *  tweak's own method fields — the app re-joins by copyWith). */
function serverPoolEntry(s) {
  return {
    id: s.id,
    name: s.name,
    protocol: s.protocol,
    address: s.address,
    port: s.port,
    transport: s.transport,
    security: s.security,
    uuid: s.uuid,
    alterId: s.alterId,
    password: s.password,
    encryption: s.encryption,
    host: s.host,
    path: s.path,
    serviceName: s.serviceName,
    fingerprint: s.fingerprint,
    flow: s.flow,
    publicKey: s.publicKey,
    shortId: s.shortId,
    sshUser: s.sshUser,
    sshPass: s.sshPass,
    sshCompression: s.sshCompression,
    dnsttServer: s.dnsttServer,
    dnsttKey: s.dnsttKey,
    dnsttResolver: s.dnsttResolver,
    ovpnConfig: s.ovpnConfig,
    // A joined config inherits the server's FULL capability set (not just
    // its own marker) so the app can list the node under every type it
    // genuinely supports — a vless node whose server also declares SNI must
    // show up in the SNI custom-config pool.
    capabilities: normalizeCapabilities(s.capabilities),
  };
}

export function joinServerIntoConfig(config, servers) {
  // A tweak with NO server reference joins with its compatible pool (anchor
  // = first compatible server); a legacy serverId also just anchors the pool.
  if (!config.serverId && !config.capability) return config;
  const pool = compatibleServersFor(config, servers);
  if (pool.length === 0) {
    // No compatible server: keep the legacy exact-server join if one exists
    // (so old data never silently vanishes), otherwise the tweak cannot
    // ride anything.
    if (!config.serverId) return config;
    const s = (servers || []).find((x) => x.id === config.serverId);
    return s ? { ...config, ...serverJoinFields(config, s), serverPool: [] } : config;
  }
  const joined = { ...config, ...serverJoinFields(config, pool[0]) };
  // Failover pool: every OTHER compatible server, ready-to-join endpoint
  // sets. The app walks them when the anchor fails — one server going down
  // never kills the tweak.
  joined.serverPool = pool.slice(1).map(serverPoolEntry);
  joined.capability = str(config.capability).toUpperCase() || inferCapability(config);
  // Riding family travels to the app so its re-join matches this pool —
  // 'mixed' tweaks must not collapse back to their own protocol family.
  const fam = str(config.family).toLowerCase();
  if (fam) joined.family = fam;
  return joined;
}

/** The per-server field overlay a join applies (endpoint, creds, branding). */
function serverJoinFields(config, s) {
  return {
    // endpoint + credentials from the server
    protocol: s.protocol,
    address: s.address,
    port: s.port,
    transport: s.transport,
    security: s.security,
    uuid: s.uuid,
    alterId: s.alterId,
    password: s.password,
    encryption: s.encryption,
    host: config.host || s.host,
    path: config.path || s.path,
    serviceName: config.serviceName || s.serviceName,
    fingerprint: s.fingerprint,
    flow: s.flow,
    publicKey: s.publicKey,
    shortId: s.shortId,
    sshUser: s.sshUser,
    sshPass: s.sshPass,
    sshCompression: s.sshCompression,
    dnsttServer: s.dnsttServer,
    dnsttKey: s.dnsttKey,
    dnsttResolver: s.dnsttResolver,
    ovpnConfig: s.ovpnConfig,
    // presentation + access control from the server (config may refine).
    // Category is the METHOD's property (which app group / session it serves)
    // — config wins, server value is only a legacy fallback.
    category: str(config.category) || s.category,
    country: s.country || config.country,
    region: s.region || config.region,
    // Logo precedence: the TWEAK's own logo wins (per-method branding —
    // e.g. the Robi variant of a shared host); the server's logo is the
    // fallback so one upload brands every tweak on that host.
    logoBase64: s.logoBase64 || config.logoBase64,
    logoUrl: config.logoUrl || s.logoUrl,
    author: s.author || config.author,
    isOfficial: s.isOfficial,
    locked: s.locked || config.locked,
    lockMessage: s.lockMessage || config.lockMessage,
    expiresAt: s.expiresAt || config.expiresAt,
    encryptionKey: s.encryptionKey || config.encryptionKey,
    // VIP: a VIP server turns every tweak riding it VIP unless the tweak
    // explicitly opts out; the hours the SERVER paid for win.
    vip: config.vip === false && config.ownsVip ? false : s.vip || config.vip,
    vipUnlockHours: s.vipUnlockHours || config.vipUnlockHours,
    vipNote: s.vipNote || config.vipNote,
    // Vault: a vaulted server keeps the endpoint server-side for every tweak
    // riding it. The config may set its own vault (=== its own id) to override.
    vault: config.vault || s.vault,
    // display name: config's own name. The note is the TWEAK's own
    // customizable message only — the old server-name fallback put the
    // joined host's name under every tweak card. Blank = the app hides it.
    note: config.note && config.note !== config.name ? config.note : '',
    server: s.name,
    // Full capability set follows the join (see comment in serverPoolEntry).
    capabilities: normalizeCapabilities(s.capabilities),
  };
}
