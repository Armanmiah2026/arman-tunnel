/**
 * Types for the Arman Tunnel admin panel.
 *
 * `ServerConfig` is the canonical wire format — it MUST stay in sync with
 * `admin-panel/src/config-schema.js` (normalizeConfig) and the app's
 * `lib/models/server_config.dart`. The Worker validates every field, so a
 * missing field here means the UI cannot edit what the app reads.
 */

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
] as const;
export type Protocol = (typeof PROTOCOLS)[number];

/// True when a server entity is an actual PROXY endpoint (socks/http_proxy/
/// psiphon) — the only server kind that publishes as its own app node.
/// Tunnel ENDPOINT servers (ssh/vless/openvpn/…) are tweak anchors; the
/// Proxies tab mirrors this filter so it shows proxies, not the whole
/// endpoint list. Keep in sync with config-schema.js isProxyNode.
export function isProxyNode(s: { protocol: string }): boolean {
  const p = String(s?.protocol || '').toLowerCase().replace(/[\s-]+/g, '_');
  return p === 'socks' || p === 'http_proxy' || p === 'psiphon';
}

export const TRANSPORTS = [
  'tcp',
  'ws',
  'grpc',
  'xhttp',
  'httpupgrade',
  'kcp',
] as const;
export type Transport = (typeof TRANSPORTS)[number];

export const SECURITIES = ['none', 'tls', 'reality'] as const;
export type Security = (typeof SECURITIES)[number];

export const INJECT_MODES = ['none', 'direct', 'directSni', 'proxy', 'proxySni', 'dnstt'] as const;
export type InjectMode = (typeof INJECT_MODES)[number];

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
] as const;
export type Category = (typeof CATEGORIES)[number];

/** Canonical node object — exactly what the encrypted bundle carries. */
export interface ServerConfig {
  id: string;
  name: string;
  note: string;
  protocol: Protocol;
  address: string;
  port: number;
  transport: Transport;
  security: Security;
  uuid: string;
  alterId: string;
  password: string;
  encryption: string;
  sni: string;
  path: string;
  host: string;
  serviceName: string;
  fingerprint: string;
  flow: string;
  publicKey: string;
  shortId: string;
  sshUser: string;
  sshPass: string;
  sshCompression: boolean;
  payload: string;
  payloadEnhanced: boolean;
  injectMode: InjectMode;
  injectHost: string;
  injectPort: string;
  injectPayload: string;
  dnsttServer: string;
  dnsttKey: string;
  dnsttResolver: string;
  ovpnConfig: string;
  wireguardConfig: string;
  psiphonRegion: string;
  category: Category | string;
  country: string;
  region: string;
  /** Logical server grouping label — one host may carry several payload/SNI configs. */
  server: string;
  logoBase64: string;
  /** Hosted logo image URL (imgbb upload). Wins over logoBase64 in the app. */
  logoUrl: string;
  author: string;
  isOfficial: boolean;
  locked: boolean;
  lockMessage: string;
  expiresAt: number;
  encryptionKey: string;
  /** VIP server: the app unlocks it for `vipUnlockHours` (default 2) per rewarded ad. */
  vip: boolean;
  vipUnlockHours: number;
  /** Optional note shown on the app's VIP unlock sheet. */
  vipNote: string;
  /** Server-side vault id. When this equals the config `id`, the published app
   *  bundle redacts address/port and the app resolves the endpoint from
   *  GET /api/vip/resolve after a verified rewarded-ad unlock. */
  vault: string;
  // Admin-only bookkeeping (never leaves the Worker in the app bundle).
  active: boolean;
  priority: number;
  maxConnections: number;
  createdAt: string;
  updatedAt: string;
  /** Reference to the ServerEntity this config is a method/variant of.
   *  LEGACY: the preferred/anchor server only — the tweak joins with every
   *  server whose capabilities include its type. Blank on new tweaks. */
  serverId: string;
  /** Explicit tweak server allow-list. Empty/absent means every compatible server. */
  serverIds: string[];
  /** The tweak's capability type ([SNI], [PROXY+PAYLOAD]…) — what kind of
   *  method it is. Compatible servers are derived from this. */
  capability: string;
  /** Protocol family the method targets: 'ssh' | 'openvpn' | 'v2ray'. */
  family: string;
}

/** A Server is the endpoint + credentials (the "host"); a Config is the
 *  connection METHOD (payload/SNI ticks) that points at it via serverId.
 *  They are edited separately and joined at publish time. */
export interface ServerEntity {
  id: string;
  name: string;
  note: string;
  /** Capability types this server supports — tweaks of these types (same
   *  protocol family) may ride on it. Drives the dynamic join + failover. */
  capabilities: string[];
  protocol: Protocol;
  address: string;
  port: number;
  transport: Transport;
  security: Security;
  uuid: string;
  alterId: string;
  password: string;
  encryption: string;
  sni: string;
  path: string;
  host: string;
  serviceName: string;
  fingerprint: string;
  flow: string;
  publicKey: string;
  shortId: string;
  sshUser: string;
  sshPass: string;
  sshCompression: boolean;
  dnsttServer: string;
  dnsttKey: string;
  dnsttResolver: string;
  ovpnConfig: string;
  wireguardConfig: string;
  psiphonRegion: string;
  category: Category | string;
  country: string;
  region: string;
  logoBase64: string;
  /** Hosted logo image URL (imgbb upload). Wins over logoBase64 in the app. */
  logoUrl: string;
  author: string;
  isOfficial: boolean;
  locked: boolean;
  lockMessage: string;
  expiresAt: number;
  encryptionKey: string;
  /** VIP server: unlocked client-side by watching a rewarded ad (vipUnlockHours each). */
  vip: boolean;
  vipUnlockHours: number;
  /** Optional note shown on the app's VIP unlock sheet. */
  vipNote: string;
  vault: string;
  // Admin-only bookkeeping.
  active: boolean;
  priority: number;
  createdAt: string;
  updatedAt: string;
}

/** A Tweak Category — the section headers the app's Configs menu renders.
 *  `country` is the flag (ISO-2); blank renders the earth emoji. */
export interface CategoryEntity {
  id: string;
  name: string;
  country: string;
  createdAt: string;
  updatedAt: string;
}

export interface FieldIssue {
  field: string;
  message: string;
}

export interface ValidationResult {
  ok: boolean;
  valid: boolean;
  errors: FieldIssue[];
  warnings: FieldIssue[];
}

/** Response of POST /api/validate — dry-run normalize + validate. For a
 *  tweak (serverId set) the fields describe the JOINED config. */
export interface DryRun extends ValidationResult {
  normalized: ServerConfig;
  appPayload: Record<string, unknown>;
  shareLink: string;
  /** Flag country of the matched category ('' when none). */
  categoryCountry?: string;
}

export interface PublishFileResult {
  ok: boolean;
  file: string;
  error?: string;
  status?: number;
  commit?: string;
  bytes?: number;
  rawUrl?: string;
}

export interface PublishResult {
  attempted: boolean;
  ok: boolean;
  time?: string;
  nodes?: number;
  envelope?: string;
  error?: string;
  files: PublishFileResult[];
}

export interface VerifyFileReport {
  file: string;
  fetched: boolean;
  decrypted?: boolean;
  matchesKv?: boolean;
  nodes?: number;
  url?: string;
  error?: string;
}

export interface VerifyResult {
  ok: boolean;
  configFile?: VerifyFileReport;
  settingsFile?: VerifyFileReport;
  backupFile?: VerifyFileReport;
}

export interface RepoInfo {
  repo: string;
  branch: string;
  configFile: string;
  settingsFile: string;
  configFileUrl: string;
  settingsFileUrl: string;
}

export interface AppSettings {
  appLocked: boolean;
  lockedMessage: string;
  forceUpdate: boolean;
  latestVersion: string;
  updateUrl: string;
  updateMessage: string;
  /** Payload token library: name → template ([RYZE] → HTTP/1.1 Host: telegram.org …). */
  payloadDefs: Record<string, string>;
  vers: AppVersionPayload | null;
  updatedAt: string;
}

/** version.json-style payload embedded in the encrypted settings bundle. */
export interface AppVersionPayload {
  appName?: string;
  packageName?: string;
  versionName?: string;
  versionCode?: number;
  minRequiredVersionCode?: number;
  forceUpdate?: boolean;
  apkDownloadUrl?: string;
  mirrorDownloadUrl?: string;
  fileSize?: string;
  releaseDate?: string;
  changelog?: string[] | string;
  author?: string;
}

/** information.json-style broadcast payload shown by the app's notice system. */
export interface BroadcastPayload {
  showDialog?: boolean;
  dialogTitle?: string;
  dialogMessage?: string;
  actionButtonText?: string;
  actionButtonUrl?: string;
  showMarquee?: boolean;
  marqueeNotice?: string;
  maintenanceMode?: boolean;
  maintenanceMessage?: string;
  supportTelegram?: string;
  showOncePerVersion?: boolean;
}

export interface BackendMeta {
  name: string;
  contact: string;
  whatsapp: string;
  description: string;
  /** Legacy single admin wallpaper URL (kept = wallpapers[0].url for old app builds). */
  wallpaper: string;
  /** Admin wallpaper gallery — {url, title} entries; untitled ones are auto-numbered. */
  wallpapers: { url: string; title: string }[];
  info: BroadcastPayload | null;
  updatedAt?: string;
}

export interface AdminAccount {
  username: string;
  createdAt: string;
}

/** One entry of the panel's image library (every imgbb upload). */
export interface PanelImage {
  url: string;
  filename?: string;
  time?: string;
}

export interface ActivityLog {
  id: string;
  time: string;
  actor?: string;
  action: string;
  type: string;
  status: string;
}

export interface Stats {
  total: number;
  active: number;
  inactive: number;
  locked: number;
  expired: number;
  official: number;
  custom: number;
  protocols: Record<string, number>;
  categories: Record<string, number>;
  countries: Record<string, number>;
}

export interface LastPublish {
  time: string;
  ok: boolean;
  nodes?: number;
  envelope?: string;
  files?: PublishFileResult[];
}

/** One-shot snapshot from GET /api/bootstrap. */
export interface Bootstrap {
  ok: true;
  me: string;
  role: 'dev' | 'admin';
  csrf: string;
  repo: RepoInfo;
  crypto: { version: string; certBound: boolean; certSha256: string };
  github: { configured: boolean };
  configs: ServerConfig[];
  servers: ServerEntity[];
  categories: CategoryEntity[];
  types: CapabilityType[];
  settings: AppSettings;
  backend: BackendMeta;
  logs: ActivityLog[];
  lastPublish: LastPublish | null;
  stats: Stats;
}

/** A tweak capability type — the Server ↔ Tweak compatibility marker. */
export interface CapabilityType {
  id: string;
  name: string;
  description: string;
  enabled: boolean;
  createdAt?: string;
}

/** A BDIX trial device (GET /api/devices). */
export interface TrialDevice {
  id: string;
  active: boolean;
  expiresAt: number;
  daysLeft: number;
  vip: boolean;
  trial: boolean;
  extended: boolean;
  revoked: boolean;
  firstSeen: number;
  lastSeen: number;
  note?: string;
  appVersion: string;
  platform: string;
  connectCount: number;
  lastConnected: number;
  /** Registration IP (may be blank when the header is absent). */
  regIp: string;
  /** Devices registered from the same regIp — trial-farming signal. */
  ipCount: number;
}

/** An admin-issued license key (GET /api/devices). */
export interface LicenseKey {
  key: string;
  days: number;
  deviceId: string;
  created: number;
  redeemedBy: string;
  redeemedAt: number;
}

/** Full panel backup (GET /api/backup / POST /api/backup). */
export interface BackupSnapshot {
  kind: 'sensei-panel-backup';
  version: number;
  exportedAt: string;
  configs: ServerConfig[];
  servers: ServerEntity[];
  categories: CategoryEntity[];
  settings: AppSettings | null;
  backend: BackendMeta | null;
  admins: Array<Record<string, unknown>>;
}

export interface RestoreResult {
  ok: true;
  restored: { configs: number; servers: number; categories: number };
  publish: PublishResult;
}
