/**
 * The single node editor — used for BOTH "Add" and "Edit".
 *
 * Layout mirrors a VPN app's add-config screen:
 *   1. Smart paste (new only)     4. Per-protocol settings
 *   2. Protocol picker (pills)    5. DPI / payload injection
 *   3. Server address             6. Access control
 *
 * Every field maps 1:1 to the canonical schema; the Worker fills engine
 * defaults for anything left blank.
 */
import React, { useEffect, useMemo, useRef, useState } from 'react';
import { api } from '../api';
import type { DryRun, ServerConfig } from '../types';
import { CATEGORIES, INJECT_MODES, PROTOCOLS, SECURITIES, TRANSPORTS } from '../types';
import { ImageUpload } from './ImageUpload';
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
} from './ui';
import { PayloadPicker } from './PayloadPicker';

export const PROTOCOL_LABELS: Record<string, string> = {
  vless: 'VLESS',
  vmess: 'VMess',
  trojan: 'Trojan',
  shadowsocks: 'SS',
  ssh: 'SSH',
  ssh_dnstt: 'SlowDNS',
  openvpn: 'OVPN',
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
  wireguard: '🛰️',
  socks: '🧦',
  http_proxy: '🌐',
  psiphon: '🌀',
};

type Family = 'v2ray' | 'ssh' | 'openvpn' | 'wireguard' | 'proxy' | 'psiphon';

function familyOf(protocol: string): Family {
  if (protocol === 'ssh' || protocol === 'ssh_dnstt') return 'ssh';
  if (protocol === 'openvpn') return 'openvpn';
  if (protocol === 'wireguard') return 'wireguard';
  if (protocol === 'socks' || protocol === 'http_proxy') return 'proxy';
  if (protocol === 'psiphon') return 'psiphon';
  return 'v2ray';
}

export function blankConfig(): Partial<ServerConfig> {
  return {
    name: '', note: '', protocol: 'vless', transport: 'tcp', security: 'none',
    address: '', port: 443, uuid: '', alterId: '', password: '', encryption: '',
    sni: '', path: '', host: '', serviceName: '', fingerprint: '', flow: '',
    publicKey: '', shortId: '', sshUser: '', sshPass: '', sshCompression: false,
    payload: '', payloadEnhanced: false, injectMode: 'none', injectHost: '',
    injectPort: '', dnsttServer: '', dnsttKey: '', dnsttResolver: '',
    ovpnConfig: '', wireguardConfig: '', psiphonRegion: '',
    category: 'global', country: '', region: '', author: '',
    logoUrl: '',
    isOfficial: true, active: true, locked: false, lockMessage: '',
    expiresAt: 0, priority: 0, vip: false, vipUnlockHours: 2, vault: '',
  };
}

// Reusable sub-section inside a card
function Sub(props: { title: string; caption?: string; children: React.ReactNode }) {
  return (
    <div className="mt-4 border-t border-line pt-3 first:mt-0 first:border-t-0 first:pt-0">
      <p className="mb-2 text-[11px] font-bold uppercase tracking-wider text-accent">{props.title}</p>
      {props.caption && <p className="mb-2 text-[11px] leading-relaxed text-hint">{props.caption}</p>}
      {props.children}
    </div>
  );
}

export function ConfigForm(props: {
  initial?: ServerConfig | null;
  prefill?: Partial<ServerConfig>;
  busy?: boolean;
  onSave: (config: Partial<ServerConfig>) => Promise<void>;
  onCancel?: () => void;
  compact?: boolean;
  notify?: (message: string, kind?: 'success' | 'error' | 'info') => void;
  /** Payload token library (Controls) — powers the insert-from-library picker. */
  payloadDefs?: Record<string, string>;
}) {
  const editing = props.initial != null;
  const [c, setC] = useState<Partial<ServerConfig>>(
    () => ({ ...blankConfig(), ...(props.initial || {}), ...(props.prefill || {}) }),
  );
  const [pasteText, setPasteText] = useState('');
  const [pasteBusy, setPasteBusy] = useState(false);
  const [dry, setDry] = useState<DryRun | null>(null);
  const debounce = useRef<ReturnType<typeof setTimeout> | null>(null);

  const set = <K extends keyof ServerConfig>(k: K, v: ServerConfig[K]) =>
    setC((prev) => ({ ...prev, [k]: v }));

  const family = familyOf(String(c.protocol));
  const transport = String(c.transport || 'tcp');
  const security = String(c.security || 'none');
  const injectMode = String(c.injectMode || 'none');

  useEffect(() => {
    clearTimeout(debounce.current);
    debounce.current = setTimeout(async () => {
      try {
        setDry(await api.validate(c));
      } catch {
        setDry(null);
      }
    }, 450);
    return () => clearTimeout(debounce.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [c]);

  const errorsByField = useMemo(() => {
    const m = new Map<string, string[]>();
    for (const e of dry?.errors || []) {
      const list = m.get(e.field) || [];
      list.push(e.message);
      m.set(e.field, list);
    }
    return m;
  }, [dry]);
  const fieldError = (f: string) => errorsByField.get(f)?.[0] || null;

  async function handleSmartPaste() {
    const text = pasteText.trim();
    if (!text) return;
    setPasteBusy(true);
    try {
      const res = await api.validate({ rawContent: text } as Partial<ServerConfig>);
      setC((prev) => ({
        ...prev,
        ...blankFromParsed(res.normalized),
        id: prev.id,
        active: prev.active,
        priority: prev.priority,
      }));
      setPasteText('');
      setDry(res);
    } catch { /* validation endpoint handles parse failures */ }
    finally { setPasteBusy(false); }
  }

  function submit() { void props.onSave(c); }
  const err = (f: string) => fieldError(f);

  return (
    <div className="space-y-4">

      {/* ═══ STEP 1: Smart paste (add only) ═══ */}
      {!editing && (
        <Card>
          <SectionTitle
            title="📋 Quick Import"
            caption="Paste a share link (senseitunnel://, vless://, vmess://, trojan://, ss://, .ovpn, JSON) and auto-fill everything below."
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

      {/* ═══ STEP 2: Protocol picker ═══ */}
      <Card>
        <SectionTitle title="🔌 Protocol" />
        <div className="grid grid-cols-4 gap-2 sm:grid-cols-7">
          {PROTOCOLS.map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => set('protocol', p)}
              className={`flex flex-col items-center gap-1.5 rounded-xl border px-2 py-3 text-[11px] font-bold transition ${
                c.protocol === p
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

      {/* ═══ STEP 3: Server address ═══ */}
      <Card>
        <SectionTitle title="🌐 Server" />
        <Grid>
          <Field label="Name" required value={String(c.name || '')} onChange={(v) => set('name', v)} error={err('name')} placeholder="SG Premium 01" />
          <Field label="Note" value={String(c.note || '')} onChange={(v) => set('note', v)} hint="Shown under the name in the app — Bangla/English, blank hides it" placeholder="রোবি ইউজারদের জন্য / Robi users" />
        </Grid>
        <div className="mt-3">
          <Grid>
            <Field label="Address / Host" required value={String(c.address || '')} onChange={(v) => set('address', v)} mono error={err('address')} placeholder="server.example.com" />
            <Field label="Port" required type="number" min={1} max={65535} value={String(c.port ?? '')} onChange={(v) => set('port', parseInt(v, 10) || 0)} error={err('port')} />
          </Grid>
        </div>
        <Sub title="Location & grouping">
          <Grid cols={3}>
            <Field label="Country code" value={String(c.country || '')} onChange={(v) => set('country', v.toUpperCase())} hint="ISO code (BD, SG…)" error={err('country')} />
            <Field label="Region" value={String(c.region || '')} onChange={(v) => set('region', v)} placeholder="Tokyo" />
            <Select label="Category" value={String(c.category || 'global') as any} options={CATEGORIES.map((x) => ({ value: x, label: x[0].toUpperCase() + x.slice(1) }))} onChange={(v) => set('category', v)} />
          </Grid>
          <div className="mt-3">
            <Field label="Server group" value={String(c.server || '')} onChange={(v) => set('server', v)} hint="One host, many payload/SNI variants" placeholder="SG Core 2" />
          </div>
          <div className="mt-3">
            <ImageUpload
              label="Logo image (shown instead of the country flag)"
              value={String(c.logoUrl || '')}
              onChange={(v) => set('logoUrl', v)}
              notify={props.notify || (() => {})}
              hint="Robi/Airtel logo etc. — PNG/JPG up to 5 MB"
            />
          </div>
        </Sub>
      </Card>

      {/* ═══ STEP 4: Protocol-specific settings ═══ */}

      {/* ── V2Ray ── */}
      {family === 'v2ray' && (
        <Card>
          <SectionTitle title={`${PROTOCOL_LABELS[String(c.protocol)]} Settings`} />

          <Sub title="Credentials">
            <Grid>
              {(c.protocol === 'vless' || c.protocol === 'vmess') ? (
                <Field label="UUID" required value={String(c.uuid || '')} onChange={(v) => set('uuid', v)} mono error={err('uuid')} />
              ) : (
                <Field label="Password" required value={String(c.password || '')} onChange={(v) => set('password', v)} mono error={err('password')} />
              )}
              {c.protocol === 'vmess' && (
                <>
                  <Field label="AlterID" type="number" value={String(c.alterId || '')} onChange={(v) => set('alterId', v)} placeholder="0" />
                  <Field label="Encryption" value={String(c.encryption || '')} onChange={(v) => set('encryption', v)} hint="auto / aes-128-gcm / none" />
                </>
              )}
              {c.protocol === 'shadowsocks' && (
                <Field label="Method" required value={String(c.encryption || '')} onChange={(v) => set('encryption', v)} hint="aes-256-gcm…" error={err('encryption')} />
              )}
              {c.protocol === 'vless' && (
                <Field label="Flow (XTLS)" value={String(c.flow || '')} onChange={(v) => set('flow', v)} placeholder="xtls-rprx-vision" />
              )}
            </Grid>
          </Sub>

          <Sub title="Transport">
            <Grid>
              <Select label="Network" value={transport as any} options={TRANSPORTS.map((t) => ({ value: t, label: t.toUpperCase() }))} onChange={(v) => set('transport', v)} />
              {transport === 'ws' && (
                <>
                  <Field label="WS Path" value={String(c.path || '')} onChange={(v) => set('path', v)} mono error={err('path')} placeholder="/vless" />
                  <Field label="WS Host Header" value={String(c.host || '')} onChange={(v) => set('host', v)} mono placeholder="cdn.example.com" />
                </>
              )}
              {transport === 'grpc' && (
                <Field label="gRPC Service Name" required value={String(c.serviceName || '')} onChange={(v) => set('serviceName', v)} mono error={err('serviceName')} />
              )}
            </Grid>
          </Sub>

          <Sub title="TLS / Security">
            <Grid>
              <Select label="Security" value={security as any} options={SECURITIES.map((s) => ({ value: s, label: s === 'none' ? 'None' : s.toUpperCase() }))} onChange={(v) => set('security', v)} />
              {security !== 'none' && (
                <Field label="SNI / serverName" value={String(c.sni || '')} onChange={(v) => set('sni', v)} mono error={err('sni')} placeholder="sni.example.com" />
              )}
              {security !== 'none' && (
                <Select label="uTLS Fingerprint" value={String(c.fingerprint || 'chrome')} options={['chrome', 'firefox', 'safari', 'ios', 'android', 'edge'].map((f) => ({ value: f, label: f }))} onChange={(v) => set('fingerprint', v)} />
              )}
              {security === 'reality' && (
                <>
                  <Field label="Public Key (pbk)" required value={String(c.publicKey || '')} onChange={(v) => set('publicKey', v)} mono error={err('publicKey')} />
                  <Field label="Short ID (sid)" value={String(c.shortId || '')} onChange={(v) => set('shortId', v)} mono />
                </>
              )}
            </Grid>
          </Sub>
        </Card>
      )}

      {/* ── SSH ── */}
      {family === 'ssh' && (
        <Card>
          <SectionTitle title="SSH Account" />

          <Sub title="Login">
            <Grid>
              <Field label="Username" required value={String(c.sshUser || '')} onChange={(v) => set('sshUser', v)} error={err('sshUser')} />
              <Field label="Password" required type="password" value={String(c.sshPass || '')} onChange={(v) => set('sshPass', v)} error={err('sshPass')} />
            </Grid>
          </Sub>

          {/* ── SSL / SNI (DarkTunnel-style) ── */}
          <Sub title="🔒 SSL / TLS (stunnel)" caption="Wrap the SSH stream in TLS with a spoofed SNI — the standard BD tunneling method for port 443.">
            <Switch
              label="Use SSL / TLS"
              checked={injectMode === 'directSni' || injectMode === 'proxySni'}
              onChange={(v) => {
                if (v) {
                  // Enable SSL → set directSni (or proxySni if proxy already on)
                  set('injectMode', injectMode.startsWith('proxy') ? 'proxySni' : 'directSni');
                  if (!String(c.sni || '').trim()) set('sni', '');
                } else {
                  // Disable SSL → downgrade to direct/proxy/none
                  if (injectMode === 'directSni') set('injectMode', String(c.payload || '').trim() ? 'direct' : 'none');
                  else if (injectMode === 'proxySni') set('injectMode', 'proxy');
                }
              }}
            />
            {(injectMode === 'directSni' || injectMode === 'proxySni') && (
              <div className="mt-2">
                <Field
                  label="SNI (Bug Host)"
                  required
                  value={String(c.sni || '')}
                  onChange={(v) => set('sni', v)}
                  mono
                  error={err('sni')}
                  placeholder="fbcdn.net"
                  hint="Fake SNI that the server's TLS accepts (e.g. fbcdn.net, Facebook.com)"
                />
              </div>
            )}
          </Sub>

          <Sub title="Options">
            <Switch label="zlib Compression" checked={!!c.sshCompression} onChange={(v) => set('sshCompression', v)} hint="Helps on slow connections" />
          </Sub>

          {/* ── SlowDNS (DNSTT) ── */}
          {c.protocol === 'ssh_dnstt' && (
            <Sub title="📡 SlowDNS (DNSTT)" caption="Carries the SSH stream inside DNS queries. Requires nameserver + public key.">
              <Grid cols={3}>
                <Field label="Nameserver" required value={String(c.dnsttServer || '')} onChange={(v) => set('dnsttServer', v)} mono error={err('dnsttServer')} placeholder="ns.example.com" />
                <Field label="Public Key" required value={String(c.dnsttKey || '')} onChange={(v) => set('dnsttKey', v)} mono error={err('dnsttKey')} />
                <Field label="Resolver" value={String(c.dnsttResolver || '')} onChange={(v) => set('dnsttResolver', v)} placeholder="1.1.1.1:53" />
              </Grid>
            </Sub>
          )}
        </Card>
      )}

      {/* ── OpenVPN ── */}
      {family === 'openvpn' && (
        <Card>
          <SectionTitle title=".ovpn Profile" caption="Paste the full profile contents." />
          <TextArea label="Profile" rows={8} mono value={String(c.ovpnConfig || '')} onChange={(v) => set('ovpnConfig', v)} error={err('ovpnConfig') || undefined} placeholder={'client\ndev tun\nremote vpn.example.com 1194 udp\n<ca>…'} />
          {(err('sshUser') || (String(c.ovpnConfig || '').includes('auth-user-pass'))) && (
            <div className="mt-3">
              <Grid>
                <Field label="Username" required value={String(c.sshUser || '')} onChange={(v) => set('sshUser', v)} error={err('sshUser')} />
                <Field label="Password" type="password" value={String(c.sshPass || '')} onChange={(v) => set('sshPass', v)} />
              </Grid>
            </div>
          )}
        </Card>
      )}

      {/* ── WireGuard ── */}
      {family === 'wireguard' && (
        <Card>
          <SectionTitle title="WireGuard Config" caption="Paste the full wg.conf contents (interface + peers). The app loads it directly." />
          <TextArea label="wg.conf" rows={8} mono value={String(c.wireguardConfig || '')} onChange={(v) => set('wireguardConfig', v)} error={err('wireguardConfig') || undefined} placeholder={'[Interface]\nPrivateKey = …\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = …\nAllowedIPs = 0.0.0.0/0\nEndpoint = vpn.example.com:51820'} />
        </Card>
      )}

      {/* ── SOCKS / HTTP Proxy ── */}
      {family === 'proxy' && (
        <Card>
          <SectionTitle title={c.protocol === 'http_proxy' ? 'HTTP Proxy' : 'SOCKS5 Proxy'} caption={c.protocol === 'http_proxy' ? 'CONNECT-style HTTP proxy (proxied via SSH where applicable).' : 'SOCKS5 tunnel through a remote host.'} />
          <Sub title="Remote account">
            <Grid>
              <Field label="Username" required value={String(c.sshUser || '')} onChange={(v) => set('sshUser', v)} error={err('sshUser')} />
              <Field label="Password" required type="password" value={String(c.sshPass || '')} onChange={(v) => set('sshPass', v)} error={err('sshPass')} />
            </Grid>
          </Sub>
        </Card>
      )}

      {/* ── Psiphon ── */}
      {family === 'psiphon' && (
        <Card>
          <SectionTitle title="Psiphon" caption="Psiphon tunnel onto any server. Region answers where to anchor." />
          <Grid>
            <Field label="Region" value={String(c.psiphonRegion || '')} onChange={(v) => set('psiphonRegion', v)} error={err('psiphonRegion')} placeholder="US" />
            <Field label="Password" value={String(c.password || '')} onChange={(v) => set('password', v)} error={err('password')} />
          </Grid>
        </Card>
      )}

      {/* ═══ STEP 5: DPI Bypass / Injection ═══ */}
      {(family === 'v2ray' || family === 'ssh' || family === 'openvpn') && (
      <Card>
        <SectionTitle
          title="💉 Payload / DPI Bypass"
          caption="Fronts the tunnel with an HTTP request, TLS/SNI wrapper or bug-host proxy. OpenVPN uses the injector as an HTTP proxy (the engine appends http-proxy locally); V2Ray/SSH use it as a direct/proxy front."
        />
        <Grid>
          <Select
            label="Inject Mode"
            value={injectMode as any}
            options={INJECT_MODES
              .filter((m) => (m === 'dnstt' ? family === 'ssh' : true))
              .map((m) => ({
                value: m,
                label: { none: 'None', direct: 'Direct', directSni: 'Direct + SNI', proxy: 'Proxy (Bug)', proxySni: 'Proxy + SNI', dnstt: 'DNSTT' }[m],
              }))}
            onChange={(v) => set('injectMode', v)}
          />
          {injectMode !== 'none' && (
            <Switch label="Enhanced" checked={!!c.payloadEnhanced} onChange={(v) => set('payloadEnhanced', v)} hint="Split-send packets" />
          )}
        </Grid>

        {(injectMode.startsWith('proxy')) && (
          <div className="mt-3">
            <Grid>
              <Field label="Bug / Proxy Host" value={String(c.injectHost || '')} onChange={(v) => set('injectHost', v)} mono error={err('injectHost')} />
              <Field label="Bug Port" value={String(c.injectPort || '')} onChange={(v) => set('injectPort', v.replace(/\D/g, ''))} placeholder="80" />
            </Grid>
          </div>
        )}

        {injectMode !== 'none' && (
          <div className="mt-3">
            <PayloadPicker
              defs={props.payloadDefs}
              onInsert={(tpl) =>
                set('payload', String(c.payload || '').trim() ? `${String(c.payload || '')}\n${tpl}` : tpl)
              }
            />
            <TextArea label="Payload Template" rows={3} mono value={String(c.payload || '')} onChange={(v) => set('payload', v)} placeholder={'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]'} />
            <p className="mt-1 text-[11px] text-hint">
              Placeholders: <code>[host_port]</code>, <code>[crlf]</code>, <code>[split]</code>, <code>[host]</code> etc. — expanded at connect time.
            </p>
          </div>
        )}
      </Card>
      )}

      {/* ═══ STEP 6: Access Control ═══ */}
      <Card>
        <SectionTitle title="⚙️ Options" />
        <Grid>
          <Switch label="Active" checked={c.active !== false} onChange={(v) => set('active', v)} hint="Publish to app" />
          <Switch label="Official" checked={c.isOfficial !== false} onChange={(v) => set('isOfficial', v)} hint="Not editable on-device" />
          <Switch danger label="Locked" checked={!!c.locked} onChange={(v) => set('locked', v)} hint="Blocks connections" />
          {c.locked && <Field label="Lock Message" value={String(c.lockMessage || '')} onChange={(v) => set('lockMessage', v)} />}
          <Switch label="👑 VIP" checked={!!c.vip} onChange={(v) => set('vip', v)} hint="Reward-ad unlock per node — admin-VIP devices open it automatically, no ad" />
          {c.vip && <Field label="Unlock hours per ad" type="number" min={1} max={24} value={String(c.vipUnlockHours ?? 2)} onChange={(v) => set('vipUnlockHours', parseInt(v, 10) || 2)} hint="1–24h of access per watched ad" />}
          {c.vip && <Field label="VIP note (optional)" value={String(c.vipNote || '')} onChange={(v) => set('vipNote', v)} placeholder="Shown on the app's unlock sheet" />}
          {c.vip && (
            <Switch
              label="🔒 Server-side vault"
              checked={!!c.vault}
              onChange={(v) => set('vault', v ? (c.id || 'pending') : '')}
              hint="Keeps the real address/port out of the app bundle — the app resolves it after a verified unlock"
            />
          )}
        </Grid>
        <div className="mt-3">
          <Grid cols={3}>
            <ExpiryField value={Number(c.expiresAt || 0)} onChange={(ms) => set('expiresAt', ms)} error={err('expiresAt')} />
            <Field label="Priority" type="number" value={String(c.priority ?? 0)} onChange={(v) => set('priority', parseInt(v, 10) || 0)} hint="Higher first" />
            <Field label="Author" value={String(c.author || '')} onChange={(v) => set('author', v)} placeholder="Your Name" />
          </Grid>
        </div>
      </Card>

      {/* ═══ Live validation ═══ */}
      {dry && (
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
          {dry.valid && !dry.warnings.length && (
            <Notice kind="info">All checks pass.</Notice>
          )}
        </Card>
      )}

      {/* Sticky save bar */}
      <div className="sticky bottom-16 z-10 flex gap-2 rounded-2xl border border-line bg-surface/95 p-2 backdrop-blur lg:bottom-2">
        <Button variant="primary" full busy={props.busy} onClick={submit} disabled={!dry?.valid}>
          {editing ? 'Save changes' : 'Add node'}
        </Button>
        {props.onCancel && <Button onClick={props.onCancel}>Cancel</Button>}
      </div>
    </div>
  );
}

/** Copy only fields a share-link parse could plausibly provide. */
function blankFromParsed(n: Partial<ServerConfig>): Partial<ServerConfig> {
  const keys: Array<keyof ServerConfig> = [
    'name', 'note', 'protocol', 'address', 'port', 'transport', 'security',
    'uuid', 'alterId', 'password', 'encryption', 'sni', 'path', 'host',
    'serviceName', 'fingerprint', 'flow', 'publicKey', 'shortId',
    'sshUser', 'sshPass', 'sshCompression', 'payload', 'payloadEnhanced',
    'injectMode', 'injectHost', 'injectPort', 'dnsttServer', 'dnsttKey',
    'dnsttResolver', 'ovpnConfig', 'wireguardConfig', 'psiphonRegion',
  ];
  const out: Partial<ServerConfig> = {};
  for (const k of keys) {
    const v = n[k];
    if (v !== undefined && v !== null && v !== '' && v !== false) {
      (out as Record<string, unknown>)[k] = v;
    }
  }
  return out;
}

export function ExpiryField(props: { value: number; onChange: (ms: number) => void; error?: string | null }) {
  const dateValue = props.value > 0 ? new Date(props.value).toISOString().slice(0, 10) : '';
  return (
    <label className="block">
      <span className="mb-1.5 block text-[11px] font-semibold uppercase tracking-wider text-muted">Expires</span>
      <div className="flex items-center gap-2">
        <input
          type="date"
          value={dateValue}
          onChange={(e) => {
            const t = e.target.value ? new Date(e.target.value + 'T23:59:59Z').getTime() : 0;
            props.onChange(t);
          }}
          className="w-full rounded-xl border border-line bg-bg px-3 py-2.5 text-[13px] text-ink outline-none focus:border-accent"
        />
        {props.value > 0 && <Button small variant="ghost" onClick={() => props.onChange(0)}>Clear</Button>}
      </div>
      {(props.error || (props.value > 0 && props.value < Date.now())) && (
        <span className="mt-1 block text-[11px] text-warn">{props.error || 'Already expired'}</span>
      )}
    </label>
  );
}
