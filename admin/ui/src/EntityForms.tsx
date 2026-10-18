/**
 * Entity forms for the Servers / Tweaks flow.
 *
 * ServerForm — the raw endpoint + credentials entity (protocol pills, quick
 *              import, endpoint, location). NO payload/SNI/injection here:
 *              those are Tweak properties. A server alone never reaches the
 *              app; it goes live only when a Tweak references it.
 * TweaksForm  — the tunneling METHOD builder: category (existing or new,
 *              with flag country), tweak name, the server it rides on,
 *              per-protocol options (payload/SNI/proxy), and the app-facing
 *              Options (lock / expiry / priority). Live "Checks" validate the
 *              JOINED config — the exact node the app would receive.
 */
import React, { useEffect, useMemo, useRef, useState } from 'react';
import { api } from './api';
import type { CapabilityType, CategoryEntity, DryRun, ServerConfig, ServerEntity } from './types';
import {
  Badge,
  Button,
  Card,
  Field,
  Grid,
  Notice,
  SectionTitle,
  Select,
  Switch,
  TextArea,
} from './components/ui';
import { ExpiryField } from './components/ConfigForm';
import { ImageUpload } from './components/ImageUpload';

export const PROTOCOL_LABELS: Record<string, string> = {
  vless: 'VLESS',
  vmess: 'VMess',
  trojan: 'Trojan',
  shadowsocks: 'SS',
  ssh: 'SSH',
  ssh_dnstt: 'SlowDNS',
  openvpn: 'OVPN',
  hysteria: 'Hy2',
  wireguard: 'WG',
  socks: 'SOCKS',
  http_proxy: 'HTTP',
  psiphon: 'Psi',
};

const PROTOCOL_ICONS: Record<string, string> = {
  vless: '⚡',
  vmess: '☁️',
  trojan: '🛡️',
  shadowsocks: '🔒',
  ssh: '💻',
  ssh_dnstt: '📡',
  openvpn: '🔐',
  hysteria: '🚀',
  wireguard: '🛰️',
  socks: '🧦',
  http_proxy: '🌐',
  psiphon: '🌀',
};

type Family = 'v2ray' | 'ssh' | 'openvpn' | 'udp' | 'wireguard' | 'proxy' | 'psiphon';

function familyOf(protocol: string): Family {
  if (protocol === 'ssh' || protocol === 'ssh_dnstt') return 'ssh';
  if (protocol === 'openvpn') return 'openvpn';
  if (protocol === 'hysteria') return 'udp';
  if (protocol === 'wireguard') return 'wireguard';
  if (protocol === 'socks' || protocol === 'http_proxy') return 'proxy';
  if (protocol === 'psiphon') return 'psiphon';
  return 'v2ray';
}

export function flagOf(country?: string): string {
  const c = String(country || '').toUpperCase();
  if (!c || c === 'GLOBAL' || !/^[A-Z]{2}$/.test(c)) return '🌐';
  return String.fromCodePoint(...[...c].map((ch) => 0x1f1e6 + ch.charCodeAt(0) - 65));
}

export function blankServer(): Partial<ServerEntity> {
  return {
    name: '', note: '', protocol: 'vless', transport: 'tcp', security: 'none',
    address: '', port: 443, uuid: '', alterId: '', password: '', encryption: '',
    sni: '', path: '', host: '', serviceName: '', fingerprint: '', flow: '',
    publicKey: '', shortId: '', sshUser: '', sshPass: '', sshCompression: false,
    dnsttServer: '', dnsttKey: '', dnsttResolver: '', ovpnConfig: '',
    wireguardConfig: '', psiphonRegion: '',
    country: '', region: '', author: '', logoUrl: '', capabilities: [],
    isOfficial: true, active: true,
    // A proxy is its own node in the app; VIP just gates it behind an ad.
    vip: false, vipUnlockHours: 2, vault: '',
  };
}

/** Copy only fields a share-link parse could plausibly provide (endpoint,
 *  transport and credentials — never tweak/method fields). */
function serverFromParsed(n: Partial<ServerEntity>): Partial<ServerEntity> {
  const keys: Array<keyof ServerEntity> = [
    'name', 'protocol', 'address', 'port', 'transport', 'security',
    'uuid', 'alterId', 'password', 'encryption', 'sni', 'path', 'host',
    'serviceName', 'fingerprint', 'flow', 'publicKey', 'shortId',
    'sshUser', 'sshPass', 'dnsttServer', 'dnsttKey', 'dnsttResolver',
    'ovpnConfig', 'wireguardConfig', 'psiphonRegion',
  ];
  const out: Partial<ServerEntity> = {};
  for (const k of keys) {
    const v = n[k];
    if (v !== undefined && v !== null && v !== '' && v !== false) {
      (out as Record<string, unknown>)[k] = v;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// ServerForm
// ---------------------------------------------------------------------------

export function ServerForm(props: {
  initial?: ServerEntity | null;
  types: CapabilityType[];
  busy?: boolean;
  onSave: (server: Partial<ServerEntity>) => Promise<void>;
  onCancel: () => void;
  notify?: (message: string, kind?: 'success' | 'error' | 'info') => void;
  /** Fired after an inline type was created so the parent can re-fetch. */
  onTypesChanged?: () => void | Promise<void>;
}) {
  const editing = props.initial != null;
  const [s, setS] = useState<Partial<ServerEntity>>(
    () => ({ ...blankServer(), ...(props.initial || {}) }),
  );
  const [pasteText, setPasteText] = useState('');
  // Inline capability-type creation (the "+ Add type" row): creates a real
  // CapabilityType via the API and selects it on this server right away.
  const [newTypeName, setNewTypeName] = useState('');
  const [typeBusy, setTypeBusy] = useState(false);
  const [typeError, setTypeError] = useState('');
  const [pasteBusy, setPasteBusy] = useState(false);
  const [dry, setDry] = useState<DryRun | null>(null);
  const debounce = useRef<ReturnType<typeof setTimeout> | null>(null);

  const set = <K extends keyof ServerEntity>(k: K, v: ServerEntity[K]) =>
    setS((prev) => ({ ...prev, [k]: v }));

  // The validate endpoint accepts the superset config shape — a server body
  // validates fine there because every server field exists on a config too.
  useEffect(() => {
    clearTimeout(debounce.current);
    debounce.current = setTimeout(async () => {
      try {
        setDry(await api.validate(s as Partial<ServerConfig>));
      } catch {
        setDry(null);
      }
    }, 450);
    return () => clearTimeout(debounce.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [s]);

  const family = familyOf(String(s.protocol));
  const transport = String(s.transport || 'tcp');
  const security = String(s.security || 'none');
  const err = (f: string) => dry?.errors.find((e) => e.field === f)?.message || null;

  /** Create a capability type inline and tick it onto this server. */
  async function addType() {
    const name = newTypeName.trim().toUpperCase().replace(/\s+/g, '_');
    if (!name || name.length < 2) return;
    setTypeBusy(true);
    setTypeError('');
    try {
      await api.createType({ name });
      set('capabilities', [...(s.capabilities || []), name]);
      setNewTypeName('');
      if (props.onTypesChanged) await props.onTypesChanged();
      props.notify?.(`Type [${name}] created and selected`, 'success');
    } catch (e: any) {
      setTypeError(e?.message || 'Could not create the type');
    } finally {
      setTypeBusy(false);
    }
  }

  async function handleSmartPaste() {
    const text = pasteText.trim();
    if (!text) return;
    setPasteBusy(true);
    try {
      const res = await api.validate({ rawContent: text } as Partial<ServerConfig>);
      setS((prev) => ({
        ...prev,
        ...serverFromParsed(res.normalized as Partial<ServerEntity>),
        id: prev.id,
        active: prev.active,
      }));
      setPasteText('');
      setDry(res);
    } catch { /* validation endpoint handles parse failures */ }
    finally { setPasteBusy(false); }
  }

  return (
    <div className="space-y-4">
      {/* Quick Import */}
      {!editing && (
        <Card>
          <SectionTitle
            title="📋 Quick Import"
            caption="Paste a share link (vless://, vmess://, trojan://, ss://, hy2://, .ovpn, wg.conf, JSON) and auto-fill everything below. Only the raw server part is kept — no payload/SNI."
          />
          <div className="flex flex-col gap-2 sm:flex-row">
            <textarea
              rows={2}
              value={pasteText}
              onChange={(e) => setPasteText(e.target.value)}
              placeholder="vless://uuid@host:443?type=ws&security=tls…"
              spellCheck={false}
              className="w-full resize-y rounded-xl border border-line bg-bg px-3 py-2 font-mono text-xs text-ink outline-none placeholder:text-hint focus:border-accent"
            />
            <Button onClick={handleSmartPaste} busy={pasteBusy} disabled={!pasteText.trim()} variant="primary">
              Fill
            </Button>
          </div>
        </Card>
      )}

      {/* Protocol picker */}
      <Card>
        <SectionTitle title="🔌 Protocol" />
        <div className="grid grid-cols-4 gap-2 sm:grid-cols-7">
          {Object.keys(PROTOCOL_LABELS).map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => set('protocol', p as any)}
              className={`flex flex-col items-center gap-1.5 rounded-xl border px-2 py-3 text-[11px] font-bold transition ${
                s.protocol === p
                  ? 'border-accent bg-accent/10 text-accent'
                  : 'border-line bg-bg text-muted hover:border-accent/40 hover:text-ink'
              }`}
            >
              <span className="text-lg leading-none">{PROTOCOL_ICONS[p]}</span>
              {PROTOCOL_LABELS[p]}
            </button>
          ))}
        </div>
      </Card>

      {/* Endpoint */}
      <Card>
        <SectionTitle title="🌐 Server" caption="Raw endpoint only — payload, SNI, DNS and injection belong to the Tweaks that reference this server. This proxy also publishes to the app as its own plain node, with no tweak needed." />
        <Grid>
          <Field label="Name" required value={String(s.name || '')} onChange={(v) => set('name', v)} error={err('name')} placeholder="SG Premium 01" />
          <Field label="Note" value={String(s.note || '')} onChange={(v) => set('note', v)} hint="Shown under the name in the app — Bangla/English, blank hides it" placeholder="রোবি ইউজারদের জন্য / Robi users" />
        </Grid>
        <div className="mt-3">
          <Grid>
            <Field label="Address / Host" required value={String(s.address || '')} onChange={(v) => set('address', v)} mono error={err('address')} placeholder="server.example.com" />
            <Field label="Port" required type="number" min={1} max={65535} value={String(s.port ?? '')} onChange={(v) => set('port', parseInt(v, 10) || 0)} error={err('port')} />
          </Grid>
        </div>
        <div className="mt-3">
          <Grid cols={2}>
            <Field label="Country code" value={String(s.country || '')} onChange={(v) => set('country', v.toUpperCase())} hint="ISO code (BD, SG…)" error={err('country')} />
            <Field label="Region" value={String(s.region || '')} onChange={(v) => set('region', v)} placeholder="Tokyo" />
          </Grid>
        </div>
        {/* Supported tweak types — the dynamic join key. Tweaks of these
            types (same protocol family) ride this server; if it goes down
            the app fails over to another server sharing the type. Custom
            types can be created INLINE here (no detour to the Types tab):
            they are saved as real CapabilityType entities via the API. */}
        <div className="mt-3">
          <p className="mb-1 text-[11px] font-semibold uppercase tracking-wider text-hint">
            Supported tweak types <span className="text-accent">*</span>
          </p>
          <div className="flex flex-wrap gap-1.5">
            {props.types.map((t) => {
              const on = (s.capabilities || []).includes(t.name);
              return (
                <button
                  key={t.id}
                  type="button"
                  disabled={t.enabled === false}
                  onClick={() =>
                    set('capabilities',
                      on
                        ? (s.capabilities || []).filter((c) => c !== t.name)
                        : [...(s.capabilities || []), t.name])
                  }
                  className={`rounded-lg border px-2.5 py-1 text-[11px] font-bold transition-colors ${
                    on
                      ? 'border-accent bg-accent/15 text-accent'
                      : 'border-line text-muted hover:border-accent/50'
                  } ${t.enabled === false ? 'opacity-40' : ''}`}
                  title={t.description || t.name}
                >
                  {on ? '☑' : '☐'} {t.name}
                </button>
              );
            })}
          </div>
          {(s.capabilities || []).length > 0 && (
            <div className="mt-2 space-y-1 rounded-xl border border-line bg-bg/70 px-3 py-2">
              {(s.capabilities || []).map((name) => {
                const t = props.types.find((x) => x.name === name);
                return (
                  <p key={name} className="text-[11px] text-hint">
                    <b className="font-mono text-accent">[{name}]</b>{' '}
                    Description: {t?.description || 'No description set'}
                  </p>
                );
              })}
            </div>
          )}
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <input
              value={newTypeName}
              onChange={(e) => setNewTypeName(e.target.value.toUpperCase())}
              placeholder="NEW_TYPE (e.g. CLOUDFRONT+PROXY+PAYLOAD)"
              maxLength={40}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  void addType();
                }
              }}
              className="min-w-[220px] flex-1 rounded-lg border border-line bg-bg px-2.5 py-1.5 font-mono text-[11px] uppercase text-ink outline-none placeholder:text-hint focus:border-accent"
            />
            <button
              type="button"
              disabled={!newTypeName.trim() || typeBusy}
              onClick={() => void addType()}
              className="rounded-lg border border-accent/50 bg-accent/10 px-3 py-1.5 text-[11px] font-bold text-accent hover:bg-accent/20 disabled:opacity-40"
            >
              {typeBusy ? 'Adding…' : '+ Add type'}
            </button>
            {typeError && <span className="text-[11px] font-semibold text-danger">{typeError}</span>}
          </div>
          {(s.capabilities || []).length === 0 && (
            <p className="mt-1 text-[11px] text-warn">
              No types selected — no tweak can ride this server.
            </p>
          )}
        </div>
        {/* Operator logo (Robi / Airtel / …) — replaces the country flag in
            the app when set. Uploaded to imgbb; only the URL is stored. */}
        <div className="mt-3">
          <ImageUpload
            label="Logo image (shown instead of the country flag)"
            value={String(s.logoUrl || '')}
            onChange={(v) => set('logoUrl', v)}
            notify={props.notify || (() => {})}
            hint="Robi/Airtel logo etc. — PNG/JPG up to 5 MB"
          />
        </div>
      </Card>

      {/* Per-protocol credentials */}
      {family === 'v2ray' && (
        <Card>
          <SectionTitle title={`${PROTOCOL_LABELS[String(s.protocol)]} Settings`} />
          <Grid>
            {(s.protocol === 'vless' || s.protocol === 'vmess') ? (
              <Field label="UUID" required value={String(s.uuid || '')} onChange={(v) => set('uuid', v)} mono error={err('uuid')} />
            ) : (
              <Field label="Password" required value={String(s.password || '')} onChange={(v) => set('password', v)} mono error={err('password')} />
            )}
            {s.protocol === 'vmess' && (
              <>
                <Field label="AlterID" type="number" value={String(s.alterId || '')} onChange={(v) => set('alterId', v)} placeholder="0" />
                <Field label="Encryption" value={String(s.encryption || '')} onChange={(v) => set('encryption', v)} hint="auto / aes-128-gcm / none" />
              </>
            )}
            {s.protocol === 'shadowsocks' && (
              <Field label="Method" required value={String(s.encryption || '')} onChange={(v) => set('encryption', v)} hint="aes-256-gcm…" error={err('encryption')} />
            )}
            {s.protocol === 'vless' && (
              <Field label="Flow (XTLS)" value={String(s.flow || '')} onChange={(v) => set('flow', v)} placeholder="xtls-rprx-vision" />
            )}
          </Grid>
          <Sub title="Transport">
            <Grid>
              <Select label="Network" value={transport} options={['tcp', 'ws', 'grpc'].map((t) => ({ value: t, label: t.toUpperCase() }))} onChange={(v) => set('transport', v as any)} />
              {transport === 'ws' && (
                <>
                  <Field label="WS Path" value={String(s.path || '')} onChange={(v) => set('path', v)} mono placeholder="/vless" />
                  <Field label="WS Host Header" value={String(s.host || '')} onChange={(v) => set('host', v)} mono placeholder="cdn.example.com" />
                </>
              )}
              {transport === 'grpc' && (
                <Field label="gRPC Service Name" required value={String(s.serviceName || '')} onChange={(v) => set('serviceName', v)} mono error={err('serviceName')} />
              )}
            </Grid>
          </Sub>
          <Sub title="TLS / Security">
            <Grid>
              <Select label="Security" value={security} options={['none', 'tls', 'reality'].map((x) => ({ value: x, label: x === 'none' ? 'None' : x.toUpperCase() }))} onChange={(v) => set('security', v as any)} />
              {security !== 'none' && (
                <Field label="SNI / serverName" required={security === 'reality'} value={String(s.sni || '')} onChange={(v) => set('sni', v)} mono placeholder="sni.example.com" />
              )}
              {security !== 'none' && (
                <Select label="uTLS Fingerprint" value={String(s.fingerprint || 'chrome')} options={['chrome', 'firefox', 'safari', 'ios', 'android', 'edge'].map((f) => ({ value: f, label: f }))} onChange={(v) => set('fingerprint', v)} />
              )}
              {security === 'reality' && (
                <>
                  <Field label="Public Key (pbk)" required value={String(s.publicKey || '')} onChange={(v) => set('publicKey', v)} mono error={err('publicKey')} />
                  <Field label="Short ID (sid)" value={String(s.shortId || '')} onChange={(v) => set('shortId', v)} mono />
                </>
              )}
            </Grid>
          </Sub>
        </Card>
      )}

      {family === 'ssh' && (
        <Card>
          <SectionTitle title="SSH Account" caption="Optional — a proxy can be saved without them, but an SSH node needs a username + password before it can connect." />
          <Grid>
            <Field label="Username" value={String(s.sshUser || '')} onChange={(v) => set('sshUser', v)} error={err('sshUser')} />
            <Field label="Password" type="password" value={String(s.sshPass || '')} onChange={(v) => set('sshPass', v)} error={err('sshPass')} />
          </Grid>
          {s.protocol === 'ssh_dnstt' && (
            <Sub title="📡 SlowDNS (DNSTT)">
              <Grid cols={3}>
                <Field label="Nameserver" required value={String(s.dnsttServer || '')} onChange={(v) => set('dnsttServer', v)} mono error={err('dnsttServer')} placeholder="ns.example.com" />
                <Field label="Public Key" required value={String(s.dnsttKey || '')} onChange={(v) => set('dnsttKey', v)} mono error={err('dnsttKey')} />
                <Field label="Resolver" value={String(s.dnsttResolver || '')} onChange={(v) => set('dnsttResolver', v)} placeholder="1.1.1.1:53" />
              </Grid>
            </Sub>
          )}
        </Card>
      )}

      {family === 'openvpn' && (
        <Card>
          <SectionTitle title=".ovpn Profile" caption="Paste the full profile contents." />
          <TextArea label="Profile" rows={8} mono value={String(s.ovpnConfig || '')} onChange={(v) => set('ovpnConfig', v)} error={err('ovpnConfig') || undefined} placeholder={'client\ndev tun\nremote vpn.example.com 1194 udp\n<ca>…'} />
          {(err('sshUser') || (String(s.ovpnConfig || '').includes('auth-user-pass'))) && (
            <div className="mt-3">
              <Grid>
                <Field label="Username" required value={String(s.sshUser || '')} onChange={(v) => set('sshUser', v)} error={err('sshUser')} />
                <Field label="Password" type="password" value={String(s.sshPass || '')} onChange={(v) => set('sshPass', v)} />
              </Grid>
            </div>
          )}
        </Card>
      )}

      {family === 'udp' && (
        <Card>
          <SectionTitle
            title="Hysteria 2 (UDP)"
            caption="QUIC/UDP — already encrypted end to end, so no payload/SNI front applies. Empty SNI = accept any certificate (insecure mode)."
          />
          <Grid>
            <Field label="Auth Token" value={String(s.password || '')} onChange={(v) => set('password', v)} mono placeholder="server password / auth — empty if none" />
            <Field label="SNI (optional)" value={String(s.sni || '')} onChange={(v) => set('sni', v)} mono placeholder="sni.example.com — empty = insecure" error={err('sni')} />
          </Grid>
        </Card>
      )}

      {family === 'wireguard' && (
        <Card>
          <SectionTitle title="WireGuard Config" caption="Paste the full wg.conf contents (interface + peers). The app loads it directly." />
          <TextArea label="wg.conf" rows={8} mono value={String(s.wireguardConfig || '')} onChange={(v) => set('wireguardConfig', v)} error={err('wireguardConfig') || undefined} placeholder={'[Interface]\nPrivateKey = …\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = …\nAllowedIPs = 0.0.0.0/0\nEndpoint = vpn.example.com:51820'} />
        </Card>
      )}

      {family === 'proxy' && (
        <Card>
          <SectionTitle title={s.protocol === 'http_proxy' ? 'HTTP Proxy' : 'SOCKS5 Proxy'} caption={s.protocol === 'http_proxy' ? 'CONNECT-style HTTP proxy (proxied via SSH where applicable).' : 'SOCKS5 tunnel through a remote host.'} />
          <Grid>
            <Field label="Username" value={String(s.sshUser || '')} onChange={(v) => set('sshUser', v)} error={err('sshUser')} />
            <Field label="Password" type="password" value={String(s.sshPass || '')} onChange={(v) => set('sshPass', v)} error={err('sshPass')} />
          </Grid>
        </Card>
      )}

      {family === 'psiphon' && (
        <Card>
          <SectionTitle title="Psiphon" caption="Psiphon tunnel onto any server. Region answers where to anchor." />
          <Grid>
            <Field label="Region" value={String(s.psiphonRegion || '')} onChange={(v) => set('psiphonRegion', v)} error={err('psiphonRegion')} placeholder="US" />
            <Field label="Password" value={String(s.password || '')} onChange={(v) => set('password', v)} error={err('password')} />
          </Grid>
        </Card>
      )}

      <Card>
        <SectionTitle title="⚙️ Status" />
        <Grid>
          <Switch label="Active" checked={s.active !== false} onChange={(v) => set('active', v)} hint="Inactive proxies are hidden from the app" />
          <Switch label="Official" checked={s.isOfficial !== false} onChange={(v) => set('isOfficial', v)} hint="Not editable on-device" />
        </Grid>
      </Card>

      <Card>
        <SectionTitle
          title="👑 VIP / Access"
          caption="This proxy publishes to the app as its own node — no tweak required. Mark it VIP and users unlock it by watching a reward ad."
        />
        <Grid>
          <Switch label="👑 VIP (rewarded ad)" checked={!!s.vip} onChange={(v) => set('vip', v)} hint="Users watch a reward ad to unlock this proxy for the hours below" />
          {!!s.vip && (
            <Field label="Unlock hours per ad" type="number" min={1} max={24} value={String(s.vipUnlockHours ?? 2)} onChange={(v) => set('vipUnlockHours', Math.min(24, Math.max(1, parseInt(v, 10) || 2)))} hint="1–24h of access per watched ad" />
          )}
          {!!s.vip && (
            <Field
              label="Server-side vault"
              value={String(s.vault || '')}
              onChange={(ev) => set('vault', ev)}
              hint="Non-empty = keep this proxy's real address/port off the app bundle; the app fetches it after the ad unlock. Also applies to every tweak riding this proxy."
            />
          )}
        </Grid>
      </Card>

      <ChecksCard dry={dry} />

      {!dry?.valid && (
        <Notice kind={dry ? 'warn' : 'info'}>
          {dry ? 'Fix the errors above to enable saving.' : 'Running checks…'}
        </Notice>
      )}

      <div className="sticky bottom-16 z-10 flex gap-2 rounded-2xl border border-line bg-surface/95 p-2 backdrop-blur lg:bottom-2">
        <Button variant="primary" full busy={props.busy} onClick={() => void props.onSave(s)} disabled={!dry?.valid}>
          {editing ? 'Save server' : 'Add server'}
        </Button>
        <Button onClick={props.onCancel}>Cancel</Button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// TweaksForm
// ---------------------------------------------------------------------------

/** A tweak being built. `newCategory` is set when the admin is creating a
 *  brand-new category inline — the page creates it before saving the tweak. */
export interface TweakDraft {
  tweak: Partial<ServerConfig>;
  newCategory?: { name: string; country: string };
}

export function TweaksForm(props: {
  initial?: ServerConfig | null;
  servers: ServerEntity[];
  categories: CategoryEntity[];
  types: CapabilityType[];
  busy?: boolean;
  onSave: (draft: TweakDraft) => Promise<void>;
  onCancel: () => void;
  onGoServers: () => void;
  notify?: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  const editing = props.initial != null;
  const init = props.initial;
  const initialServerId = String(init?.serverId || '');
  const initialServerIds = Array.isArray((init as any)?.serverIds)
    ? ((init as any).serverIds as string[]).map(String)
    : (initialServerId ? [initialServerId] : []);

  const [catMode, setCatMode] = useState<'existing' | 'new'>(
    editing && init?.category && !props.categories.some((c) => c.name === init.category)
      ? 'new'
      : 'existing',
  );
  const [categoryId, setCategoryId] = useState<string>(() => {
    const match = props.categories.find((c) => c.name === init?.category);
    if (match) return match.id;
    // Default to the first existing category (old ConfigForm behaviour) so
    // the select never sits on a phantom blank value.
    return props.categories[0]?.id ?? '';
  });
  const [newCatName, setNewCatName] = useState(
    catMode === 'new' ? String(init?.category || '') : '',
  );
  const [newCatCountry, setNewCatCountry] = useState('');

  const [name, setName] = useState(String(init?.name || ''));
  const [serverId, setServerId] = useState(initialServerId);
  const [serverIds, setServerIds] = useState<string[]>(initialServerIds);
  // Compatibility key: the tweak's TYPE — the servers it can ride are derived,
  // never hand-picked through a duplicated protocol-family dropdown.
  const [capability, setCapability] = useState(String(init?.capability || ''));

  // Method fields
  const [usePayload, setUsePayload] = useState(!!(init?.payload || '').trim());
  const [payload, setPayload] = useState(String(init?.payload || ''));
  const [injectMode, setInjectMode] = useState(String(init?.injectMode || 'none'));
  const [injectHost, setInjectHost] = useState(String(init?.injectHost || ''));
  const [injectPort, setInjectPort] = useState(String(init?.injectPort || ''));
  const [enhanced, setEnhanced] = useState(!!init?.payloadEnhanced);
  const [sni, setSni] = useState(String(init?.sni || ''));
  const [useSni, setUseSni] = useState(!!(init?.sni || '').trim());
  const [path, setPath] = useState(String(init?.path || ''));
  const [hostHeader, setHostHeader] = useState(String(init?.host || ''));

  // Options
  const [active, setActive] = useState(init?.active !== false);
  const [isOfficial, setIsOfficial] = useState(init?.isOfficial !== false);
  const [locked, setLocked] = useState(!!init?.locked);
  const [lockMessage, setLockMessage] = useState(String(init?.lockMessage || ''));
  const [expiresAt, setExpiresAt] = useState(Number(init?.expiresAt || 0));
  const [priority, setPriority] = useState(Number(init?.priority ?? 0));
  const [author, setAuthor] = useState(String(init?.author || ''));
  // VIP: unlocked client-side by a rewarded ad (vipUnlockHours per watch).
  const [vip, setVip] = useState(!!init?.vip);
  const [vipUnlockHours, setVipUnlockHours] = useState(Number(init?.vipUnlockHours ?? 2));
  // Server-side endpoint vault: keeps this server's real address/port out of
  // the app bundle for every tweak that rides it.
  const [vault, setVault] = useState(String(init?.vault || ''));
  // Tweak-level logo (wins over the server's own logo at publish time).
  const [logoUrl, setLogoUrl] = useState(String(init?.logoUrl || ''));

  const server = props.servers.find((s) => s.id === serverId) || null;
  const compatibleServers = useMemo(
    () =>
      !capability
        ? []
        : props.servers.filter(
            (s) =>
              s.active !== false &&
              (s.capabilities || []).map((c) => String(c).toUpperCase()).includes(capability),
          ),
    [capability, props.servers],
  );
  const selectedServers = useMemo(() => {
    if (serverIds.length === 0) return compatibleServers;
    const picked = compatibleServers.filter((s) => serverIds.includes(s.id));
    return picked.length > 0 ? picked : compatibleServers;
  }, [compatibleServers, serverIds]);
  const anchorServer = selectedServers[0] || server || compatibleServers[0] || null;
  const fam = familyOf(String(anchorServer?.protocol || 'v2ray'));
  const selectedType = props.types.find((t) => t.name === capability) || null;
  const isWs = anchorServer?.transport === 'ws';

  const [dry, setDry] = useState<DryRun | null>(null);
  const debounce = useRef<ReturnType<typeof setTimeout> | null>(null);

  // No servers yet → this form is unusable. Tell the admin and bounce them to
  // the Servers tab to add one first.
  useEffect(() => {
    if (props.servers.length === 0) {
      props.onGoServers();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (compatibleServers.length === 0) {
      setServerIds([]);
      setServerId('');
      return;
    }
    setServerIds((prev) => {
      const kept = prev.filter((id) => compatibleServers.some((s) => s.id === id));
      const next = kept.length > 0 ? kept : compatibleServers.map((s) => s.id);
      setServerId((cur) => (next.includes(cur) ? cur : next[0] || ''));
      return next;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [capability, compatibleServers.length]);

  // SSH on 443 is the standard stunnel shape: the port speaks TLS, so the SSH
  // stream MUST be wrapped. Auto-tick SSL/SNI for a brand-new tweak whose
  // compatible pool is ssh-on-443 (the admin can still untick it).
  useEffect(() => {
    if (editing) return;
    const anchor = server || compatibleServers[0];
    if (
      anchor &&
      anchor.protocol === 'ssh' &&
      anchor.port === 443 &&
      !useSni &&
      !usePayload &&
      !sni.trim()
    ) {
      toggleSni(true);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [capability, server?.protocol, server?.port]);

  const categoryName =
    catMode === 'new'
      ? newCatName.trim()
      : (props.categories.find((c) => c.id === categoryId)?.name ?? '');

  // Live dry-run of the JOINED config (tweak + its compatible servers),
  // exactly what the app would receive — the server-side validate joins on
  // capability. The anchor server (legacy serverId or first compatible)
  // supplies the endpoint fields for family-specific UI.
  useEffect(() => {
    if (!capability || !categoryName) {
      setDry(null);
      return;
    }
    clearTimeout(debounce.current);
    const anchor = selectedServers[0] || server || compatibleServers[0] || null;
    const body: Partial<ServerConfig> = {
      capability,
      family: fam,
      serverId: anchor?.id,
      serverIds,
      name: name.trim(),
      category: categoryName,
      payload: usePayload ? payload : '',
      injectMode: (usePayload || useSni ? injectMode : 'none') as ServerConfig['injectMode'],
      injectHost: usePayload ? injectHost : '',
      injectPort: usePayload ? injectPort : '',
      payloadEnhanced: usePayload ? enhanced : false,
      sni: useSni ? sni : '',
      path,
      host: hostHeader,
      locked,
      lockMessage,
      expiresAt,
      priority,
      author,
      logoUrl,
      vip,
      vipUnlockHours,
      vault: vip ? vault : '',
      active,
      isOfficial,
    };
    debounce.current = setTimeout(async () => {
      try {
        setDry(await api.validate(body));
      } catch {
        setDry(null);
      }
    }, 450);
    return () => clearTimeout(debounce.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    capability, fam, serverId, serverIds, categoryName, name, usePayload, payload, injectMode, injectHost,
    injectPort, enhanced, useSni, sni, path, hostHeader, locked, lockMessage,
    expiresAt, priority, author, logoUrl, active, isOfficial,
  ]);

  const err = (f: string) => dry?.errors.find((e) => e.field === f)?.message || null;

  const ready = useMemo(() => {
    if (!name.trim()) return false;
    if (!capability) return false;
    if (selectedServers.length === 0) return false;
    if (catMode === 'new' && !newCatName.trim()) return false;
    if (catMode === 'existing' && !categoryId) return false;
    if (usePayload && !payload.trim()) return false;
    if (useSni && !sni.trim()) return false;
    return true;
  }, [name, capability, selectedServers.length, catMode, newCatName, categoryId, usePayload, payload, useSni, sni]);

  /** Human labels for whatever still blocks the save — shown right above the
   *  button so a dull button always has a visible reason. */
  const missing = useMemo(() => {
    const out: string[] = [];
    if (!name.trim()) out.push('tweak name');
    if (!capability) out.push('pick a type');
    if (capability && selectedServers.length === 0) out.push('a selected server with this type');
    if (catMode === 'new' && !newCatName.trim()) out.push('category name');
    if (catMode === 'existing' && !categoryId) out.push('pick a category');
    if (usePayload && !payload.trim()) out.push('payload template');
    if (useSni && !sni.trim()) out.push('SNI');
    return out;
  }, [name, capability, selectedServers.length, catMode, newCatName, categoryId, usePayload, payload, useSni, sni]);

  function toggleServer(id: string, checked: boolean) {
    setServerIds((prev) => {
      const next = checked ? [...new Set([...prev, id])] : prev.filter((x) => x !== id);
      setServerId((cur) => (next.includes(cur) ? cur : next[0] || ''));
      return next;
    });
  }

  function togglePayload(v: boolean) {
    setUsePayload(v);
    if (v && injectMode === 'none') setInjectMode('direct');
    if (!v && (injectMode === 'direct' || injectMode === 'proxy')) {
      setInjectMode(useSni && injectMode === 'proxy' ? 'proxySni' : useSni ? 'directSni' : 'none');
    }
  }

  function toggleSni(v: boolean) {
    setUseSni(v);
    if (v && fam === 'ssh') {
      setInjectMode(injectMode.startsWith('proxy') ? 'proxySni' : 'directSni');
    }
    if (!v && fam === 'ssh') {
      if (injectMode === 'directSni') setInjectMode(usePayload ? 'direct' : 'none');
      else if (injectMode === 'proxySni') setInjectMode('proxy');
    }
  }

  async function submit() {
    await props.onSave({
      tweak: {
        // Compatibility key — the tweak rides on EVERY server supporting
        // this type; serverId (legacy) only pins the preferred anchor.
        capability,
        family: fam,
        serverId: serverIds[0] || serverId || compatibleServers[0]?.id,
        serverIds,
        name: name.trim(),
        category: categoryName,
        payload: usePayload ? payload : '',
        // Keep the mode the toggles tracked: an SSH tweak with only SSL/SNI
        // ticked must keep directSni (the TLS wrap) — blanking it when the
        // payload is off left the app dialing plain SSH into a TLS port.
        injectMode: (usePayload || useSni ? injectMode : 'none') as ServerConfig['injectMode'],
        injectHost: usePayload ? injectHost : '',
        injectPort: usePayload ? injectPort : '',
        payloadEnhanced: usePayload ? enhanced : false,
        sni: useSni ? sni : '',
        path,
        host: hostHeader,
        locked,
        lockMessage,
        expiresAt,
        priority,
        author,
        logoUrl,
        vip,
        vipUnlockHours,
        vault: vip ? vault : '',
        active,
        isOfficial,
      },
      newCategory:
        catMode === 'new'
          ? { name: newCatName.trim(), country: newCatCountry.trim().toUpperCase() }
          : undefined,
    });
  }

  if (props.servers.length === 0) {
    return (
      <Card>
        <SectionTitle
          title="No servers yet"
          caption="A tweak rides on a server. Add the raw server first, then come back to build tweaks on it."
        />
        <Button variant="primary" onClick={props.onGoServers}>
          Go to Servers
        </Button>
      </Card>
    );
  }

  return (
    <div className="space-y-4">
      {/* 1. Category */}
      <Card>
        <SectionTitle
          title="🗂️ Category"
          caption="The app's Configs menu shows one section per category, with the category's flag in front of its name."
        />
        {!props.categories.length && !editing && (
          <Notice kind="info">
            No categories yet — create the first one below. Leave the country blank for a 🌐 earth flag.
          </Notice>
        )}
        <div className="mt-3 flex gap-2">
          <button
            type="button"
            onClick={() => setCatMode('existing')}
            className={`rounded-xl border px-3 py-2 text-xs font-bold transition ${
              catMode === 'existing' ? 'border-accent bg-accent/10 text-accent' : 'border-line bg-bg text-muted'
            }`}
          >
            Existing
          </button>
          <button
            type="button"
            onClick={() => setCatMode('new')}
            className={`rounded-xl border px-3 py-2 text-xs font-bold transition ${
              catMode === 'new' ? 'border-accent bg-accent/10 text-accent' : 'border-line bg-bg text-muted'
            }`}
          >
            + New category
          </button>
        </div>
        {catMode === 'existing' ? (
          <div className="mt-3">
            <Select
              label="Category"
              value={categoryId}
              options={[
                ...(props.categories.length
                  ? []
                  : [{ value: '', label: 'No categories yet — use “+ New category”' }]),
                ...props.categories.map((c) => ({
                  value: c.id,
                  label: `${flagOf(c.country)} ${c.name}`,
                })),
              ]}
              onChange={setCategoryId}
            />
          </div>
        ) : (
          <div className="mt-3">
            <Grid cols={2}>
              <Field
                label="Category name"
                required
                value={newCatName}
                onChange={setNewCatName}
                placeholder="Normal Internet"
                error={newCatName.trim() ? null : 'Category name is required'}
              />
              <Field
                label="Country code"
                value={newCatCountry}
                onChange={(v) => setNewCatCountry(v.toUpperCase())}
                hint="Optional ISO code (SG → 🇸🇬); blank → 🌐"
              />
            </Grid>
            {newCatName.trim() && (
              <p className="mt-2 text-[11px] text-accent">
                Preview: {flagOf(newCatCountry)} {newCatName.trim()}
              </p>
            )}
          </div>
        )}
      </Card>

      {/* 2. Name + Type (compatibility key) */}
      <Card>
        <SectionTitle
          title="🧩 Tweak"
          caption="Name the tweak and pick its TYPE — the tweak rides on every server that supports that type, so one dead server never kills it."
        />
        <Field label="Tweak name" required value={name} onChange={setName} placeholder="Robi Free Net / SG Direct…" error={err('name')} />
        <div className="mt-3">
          <Select
            label="Tweak type"
            value={capability}
            options={[
              { value: '', label: '— Pick a type —' },
              ...props.types
                .filter((t) => t.enabled !== false)
                .map((t) => ({ value: t.name, label: `[${t.name}]` })),
            ]}
            onChange={setCapability}
            hint={[
              selectedType?.description ? `Description: ${selectedType.description}` : '',
              `Compatible servers: ${compatibleServers.length}`,
            ].filter(Boolean).join(' • ')}
          />
        </div>
        <p className="mt-2 rounded-xl border border-line bg-bg px-3 py-2 text-[11px] text-hint">
          {compatibleServers.length > 0 ? (
            <>
              Rides on <b className="text-accent">{selectedServers.length}</b> selected
              server{selectedServers.length > 1 ? 's' : ''}:{' '}
              {selectedServers.map((s) => `${flagOf(s.country)} ${s.name}`).join(' · ')}
              {' '}— failover follows automatically.
            </>
          ) : (
            <>
              No server supports this type yet — add the capability to a
              server first ({props.onGoServers ? 'see Servers' : ''}).
            </>
          )}
        </p>
        {compatibleServers.length > 0 && (
          <div className="mt-3 grid gap-2 md:grid-cols-2">
            {compatibleServers.map((s) => {
              const checked = serverIds.includes(s.id);
              return (
                <button
                  key={s.id}
                  type="button"
                  onClick={() => toggleServer(s.id, !checked)}
                  className={`rounded-xl border p-3 text-left transition ${
                    checked ? 'border-accent bg-accent/10' : 'border-line bg-bg'
                  }`}
                >
                  <div className="flex items-start gap-2">
                    <span className={`mt-0.5 inline-flex h-5 w-5 items-center justify-center rounded-md border text-xs font-black ${
                      checked ? 'border-accent bg-accent text-bg' : 'border-line text-muted'
                    }`}>{checked ? '✓' : ''}</span>
                    <div>
                      <p className="text-sm font-bold text-fg">{flagOf(s.country)} {s.name}</p>
                      <p className="text-[11px] text-hint">
                        {PROTOCOL_LABELS[String(s.protocol)] || s.protocol} · {s.address}:{s.port}
                      </p>
                    </div>
                  </div>
                </button>
              );
            })}
          </div>
        )}
      </Card>

      {/* 3. Protocol options */}
      <Card>
        <SectionTitle
          title={`⚙️ ${anchorServer ? PROTOCOL_LABELS[String(anchorServer.protocol)] : 'Protocol'} options`}
          caption="Optional per the server's protocol. Nothing ticked = plain connection (validity still checked)."
        />
        <div className="space-y-3">
          {(fam === 'v2ray' || fam === 'ssh' || fam === 'openvpn') && (
            <Switch
              label="Payload injection"
              checked={usePayload}
              onChange={togglePayload}
              hint={
                fam === 'v2ray' && isWs
                  ? 'WS servers: the front answers the payload with a fake 101, then xray sends the REAL handshake — the WS path below must match the backend exactly or it 404s'
                  : 'HTTP/DPI fronting — a template or a token like [RYZE] from the library'
              }
            />
          )}
          {usePayload && (
            <div className="space-y-2 rounded-xl border border-line bg-bg p-3">
              <Select
                label="Inject Mode"
                value={injectMode}
                options={['none', 'direct', 'directSni', 'proxy', 'proxySni', 'dnstt']
                  .filter((m) => (m === 'dnstt' ? fam === 'ssh' : true))
                  .map((m) => ({
                    value: m,
                    label: { none: 'None', direct: 'Direct', directSni: 'Direct + SNI', proxy: 'Proxy (Bug)', proxySni: 'Proxy + SNI', dnstt: 'DNSTT' }[m],
                  }))}
                onChange={setInjectMode}
              />
              {(injectMode === 'proxy' || injectMode === 'proxySni') && (
                <Grid>
                  <Field label="Bug / Proxy Host" value={injectHost} onChange={setInjectHost} mono placeholder="[Default] = selected server host" error={err('injectHost')} />
                  <Field label="Bug Port" value={injectPort} onChange={(v) => setInjectPort(v.replace(/\D/g, ''))} placeholder="80" />
                </Grid>
              )}
              <TextArea label="Payload template" rows={3} mono value={payload} onChange={setPayload} placeholder={'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]  —  or [RYZE]'} />
              <Switch label="Enhanced" checked={enhanced} onChange={setEnhanced} hint="Split-send packets" />
            </div>
          )}

          <Switch
            label={fam === 'ssh' ? 'SSL / SNI (stunnel)' : 'SNI override'}
            checked={useSni}
            onChange={toggleSni}
            hint={fam === 'ssh' ? 'Wrap the SSH stream in TLS with a bug-host SNI' : 'Fake serverName for TLS'}
          />
          {useSni && (
            <div className="rounded-xl border border-line bg-bg p-3">
              <Field label={fam === 'ssh' ? 'SNI (Bug Host)' : 'SNI override'} required value={sni} onChange={setSni} mono placeholder="fbcdn.net" error={err('sni')} />
            </div>
          )}

          {fam === 'v2ray' && isWs && (
            <div className="space-y-2 rounded-xl border border-line bg-bg p-3">
              <p className="text-[11px] font-bold uppercase tracking-wider text-accent">WS settings (path is critical)</p>
              <Grid>
                <Field label="WS path" value={path} onChange={setPath} mono placeholder={anchorServer?.path || '/@user'} hint="The backend's real path — xray requests exactly this" />
                <Field label="Host header override" value={hostHeader} onChange={setHostHeader} mono placeholder={anchorServer?.host || 'cdn.example.com'} />
              </Grid>
              <p className="text-[11px] text-hint">
                Blank = use the server's own values
                {anchorServer?.path ? '.' : ' — the anchor server has NO path set.'}
              </p>
              {!server?.path && !path.trim() && (
                <Notice kind="warn">
                  No WebSocket path on the server or this tweak — xray will send
                  `GET /`. A v2rayinject-style front answers the payload with a fake
                  101 and the backend then REFUSES (`404`) any path except its real
                  one. Put the backend's actual path here.
                </Notice>
              )}
            </div>
          )}
        </div>
      </Card>

      {/* 4. Options (app-facing) */}
      <Card>
        <SectionTitle title="🛡️ Options" caption="The final release controls — how the app treats this tweak." />
        <Grid>
          <Switch label="Active" checked={active} onChange={setActive} hint="Publish to app" />
          <Switch label="Official" checked={isOfficial} onChange={setIsOfficial} hint="Not editable on-device" />
          <Switch danger label="Locked" checked={locked} onChange={setLocked} hint="Blocks connections" />
          {locked && <Field label="Lock Message" value={lockMessage} onChange={setLockMessage} />}
          <Switch label="👑 VIP" checked={vip} onChange={setVip} hint="Users watch a reward ad to unlock this node" />
          {vip && <Field label="Unlock hours per ad" type="number" min={1} max={24} value={String(vipUnlockHours)} onChange={(v) => setVipUnlockHours(parseInt(v, 10) || 2)} hint="1–24h of access per watched ad" />}
          {vip && (
            <Field
              label="Server-side vault"
              value={vault}
              onChange={setVault}
              placeholder="(off)"
              hint="Any non-empty value keeps this endpoint server-side; the app resolves it after a verified unlock"
            />
          )}
        </Grid>
        <div className="mt-3">
          <Grid cols={3}>
            <ExpiryField value={expiresAt} onChange={setExpiresAt} error={err('expiresAt')} />
            <Field label="Priority" type="number" value={String(priority)} onChange={(v) => setPriority(parseInt(v, 10) || 0)} hint="Higher first" />
            <Field label="Author" value={author} onChange={setAuthor} placeholder="Your Name" />
          </Grid>
          <div className="mt-3">
            <ImageUpload
              label="Logo image (this tweak's own — replaces the server logo)"
              value={logoUrl}
              onChange={setLogoUrl}
              notify={props.notify || (() => {})}
              hint="Robi/Airtel etc. — upload or pick from the library"
            />
          </div>
        </div>
      </Card>

      {/* 5. Checks */}
      <ChecksCard dry={dry} />

      {/* Why is the button dull? Always say so, right next to it. */}
      {(!ready || !dry?.valid) && (
        <Notice kind={missing.length ? 'warn' : 'info'}>
          {missing.length
            ? `Still needed: ${missing.join(', ')}.`
            : !dry
              ? 'Running checks…'
              : 'Fix the errors above to enable saving.'}
        </Notice>
      )}

      <div className="sticky bottom-16 z-10 flex gap-2 rounded-2xl border border-line bg-surface/95 p-2 backdrop-blur lg:bottom-2">
        <Button
          variant="primary"
          full
          busy={props.busy}
          onClick={() => void submit()}
          disabled={!ready || !dry?.valid}
          title={missing.length ? `Still needed: ${missing.join(', ')}` : undefined}
        >
          {editing ? 'Save & publish' : 'Add tweak & publish'}
        </Button>
        <Button onClick={props.onCancel}>Cancel</Button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------

/** Live validation card — errors block the save, warnings are advisory. */
export function ChecksCard(props: { dry: DryRun | null }) {
  const { dry } = props;
  if (!dry) return null;
  return (
    <Card>
      <SectionTitle
        title="Checks"
        right={
          <Badge tone={dry.valid ? 'accent' : 'warn'}>
            {dry.valid ? '✓ Ready' : `${dry.errors.length} issue${dry.errors.length === 1 ? '' : 's'}`}
          </Badge>
        }
      />
      {!!dry.errors.length && (
        <ul className="mb-2 space-y-1">
          {dry.errors.map((e, i) => (
            <li key={i} className="text-xs text-warn">• <b>{e.field}</b> — {e.message}</li>
          ))}
        </ul>
      )}
      {!!dry.warnings.length && (
        <ul className="space-y-1">
          {dry.warnings.map((e, i) => (
            <li key={i} className="text-xs text-hint">• <b>{e.field}</b> — {e.message}</li>
          ))}
        </ul>
      )}
      {dry.valid && !dry.warnings.length && <Notice kind="info">All checks pass.</Notice>}
    </Card>
  );
}

function Sub(props: { title: string; children: React.ReactNode }) {
  return (
    <div className="mt-4 border-t border-line pt-3">
      <p className="mb-2 text-[11px] font-bold uppercase tracking-wider text-accent">{props.title}</p>
      {props.children}
    </div>
  );
}
