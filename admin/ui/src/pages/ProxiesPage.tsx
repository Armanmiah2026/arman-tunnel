/**
 * Proxies — the endpoint entities that reach the app DIRECTLY.
 *
 * A proxy (socks/http_proxy/psiphon) is its own node in the feed: no tweak, no
 * capability type, no join. Adding one here is all it takes for it to appear in
 * the app and be selectable. Tunnel ENDPOINT servers (ssh/vless/openvpn/…) do
 * NOT appear here — they are tweak anchors (see the Servers tab).
 *
 * The only field on this page is the one that matters for a bare proxy — the
 * endpoint itself. Everything that a *tuned* variant would carry (payload,
 * SNI, DNS, injection) belongs to a Tweak on the Tweaks tab, which can still
 * reference this same endpoint.
 */
import React, { useMemo, useState } from 'react';
import {
  Globe,
  Lock,
  Pencil,
  Plus,
  Server as ServerIcon,
  Trash2,
} from 'lucide-react';
import type { Bootstrap, ServerConfig, ServerEntity } from '../types';
import { isProxyNode } from '../types';
import { api, publishErrorText } from '../api';
import {
  Badge,
  Button,
  Card,
  EmptyState,
  Modal,
  Notice,
  PageHeader,
} from '../components/ui';
import { PROTOCOL_LABELS, ServerForm, flagOf } from '../EntityForms';

export function ProxiesPage(props: {
  data: Bootstrap;
  refresh: () => Promise<void>;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  const { configs, servers } = props.data;
  const [formMode, setFormMode] = useState<'closed' | 'new' | 'edit'>('closed');
  const [editingServer, setEditingServer] = useState<ServerEntity | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<ServerEntity | null>(null);
  const [busy, setBusy] = useState(false);
  const [highlightId, setHighlightId] = useState('');

  /** Tweaks per proxy — informational only. A proxy does not NEED a tweak to
   *  reach the app; this just shows which ones are also riding it. */
  const tweaksByServer = useMemo(() => {
    const m = new Map<string, ServerConfig[]>();
    for (const c of configs) {
      const key = String(c.serverId || '');
      if (!key) continue;
      if (!m.has(key)) m.set(key, []);
      m.get(key)!.push(c);
    }
    return m;
  }, [configs]);

  function revealServer(id: string) {
    setFormMode('closed');
    setEditingServer(null);
    setHighlightId(id);
    setTimeout(() => {
      document.getElementById(`pxy-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }, 80);
    setTimeout(() => setHighlightId(''), 2600);
  }

  async function saveServer(server: Partial<ServerEntity>) {
    setBusy(true);
    try {
      const res = editingServer
        ? await api.updateServer(editingServer.id, server)
        : await api.createServer(server);
      const pubOk = res.publish?.ok !== false;
      const pubWhy = pubOk ? '' : ' — GitHub push FAILED: ' + (publishErrorText(res.publish) || 'unknown error');
      props.notify(
        pubOk
          ? `Proxy "${res.server.name}" saved — live in the app`
          : `Proxy "${res.server.name}" saved${pubWhy}`,
        pubOk ? 'success' : 'error',
      );
      await props.refresh();
      revealServer(res.server.id);
    } catch (e: any) {
      props.notify(e?.message || 'Save failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function doDelete(s: ServerEntity) {
    setBusy(true);
    setConfirmDelete(null);
    try {
      await api.deleteServer(s.id);
      await props.refresh();
      props.notify(`Deleted proxy "${s.name}"`, 'info');
    } catch (e: any) {
      props.notify(e?.message || 'Delete failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  // ------------------------------------------------------------------ form
  if (formMode !== 'closed') {
    return (
      <div className="space-y-4">
        <PageHeader
          title={formMode === 'edit' ? `Edit proxy — ${editingServer?.name ?? ''}` : 'New proxy'}
          caption="Just the endpoint. It publishes to the app as its own plain node — no tweak needed, and no payload/SNI/DNS fields here (those belong to a Tweak)."
        />
        <ServerForm
          key={editingServer?.id ?? 'new-proxy'}
          initial={formMode === 'edit' ? editingServer : null}
          types={props.data.types}
          busy={busy}
          notify={props.notify}
          onTypesChanged={props.refresh}
          onSave={saveServer}
          onCancel={() => {
            setFormMode('closed');
            setEditingServer(null);
          }}
        />
      </div>
    );
  }

  // ------------------------------------------------------------------ list
  // Only actual PROXY endpoints (socks/http_proxy/psiphon) are proxies —
  // tunnel ENDPOINT servers (ssh/vless/openvpn/…) are tweak anchors and
  // live on the Servers tab. Publishing them here too flooded the app's
  // Configs list with bare server copies (and old app versions with nodes
  // they cannot group).
  const proxies = servers.filter((s) => isProxyNode(s));
  const hidden = proxies.filter((s) => s.active === false).length;
  const vip = proxies.filter((s) => s.vip).length;
  return (
    <div className="space-y-4">
      <PageHeader
        title="Proxies"
        caption={`${proxies.length} prox${proxies.length === 1 ? 'y' : 'ies'} · every proxy here reaches the app directly — no tweak required.${
          vip ? ` ${vip} gated behind the ad-unlock.` : ''
        }`}
        actions={
          <Button
            variant="primary"
            onClick={() => {
              setEditingServer(null);
              setFormMode('new');
            }}
          >
            <Plus className="h-4 w-4" /> New proxy
          </Button>
        }
      />

      {!proxies.length ? (
        <EmptyState
          icon={<Globe className="h-8 w-8" />}
          title="No proxies yet"
          caption="Add a SOCKS/HTTP proxy endpoint and it appears in the app as a selectable node straight away. Its latency badge shows up there once the list is open."
          action={
            <Button
              variant="primary"
              onClick={() => {
                setEditingServer(null);
                setFormMode('new');
              }}
            >
              <Plus className="h-4 w-4" /> New proxy
            </Button>
          }
        />
      ) : (
        <div className="space-y-3">
          {proxies.map((s) => {
            const tweaks = tweaksByServer.get(s.id) || [];
            const highlighted = highlightId === s.id;
            return (
              <Card key={s.id} className={highlighted ? 'anim-pop ring-2 ring-accent' : ''}>
                <div id={`pxy-${s.id}`} className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-1.5">
                      <span className="text-base leading-none">{flagOf(s.country)}</span>
                      <h3 className="truncate text-sm font-bold text-ink">{s.name}</h3>
                      <Badge tone="accent">{PROTOCOL_LABELS[s.protocol] || s.protocol}</Badge>
                      {s.protocol === 'ssh' && s.port === 443 && (
                        <Badge tone="accent" title="SSH wrapped in TLS (stunnel-style)">
                          SSL/TLS
                        </Badge>
                      )}
                      {s.transport !== 'tcp' && <Badge>{s.transport.toUpperCase()}</Badge>}
                      {s.security !== 'none' && <Badge>{s.security.toUpperCase()}</Badge>}
                      {s.vip && (
                        <Badge tone="warn" title="Users must watch a rewarded ad to unlock this">
                          <Lock className="h-3 w-3" /> VIP
                        </Badge>
                      )}
                      {s.vault && (
                        <Badge tone="warn" title="Endpoint is withheld from the bundle and resolved on the server after unlock">
                          Vaulted
                        </Badge>
                      )}
                      {s.active === false && <Badge tone="warn">Hidden</Badge>}
                    </div>
                    <p className="mt-1 truncate font-mono text-[11px] text-hint" title={`${s.address}:${s.port}`}>
                      {s.address}:{s.port}
                    </p>
                    {s.region && <p className="mt-0.5 truncate text-[11px] text-muted">{s.region}</p>}
                    {s.note && (
                      <p className="mt-1 line-clamp-2 text-[11px] italic text-muted" title={s.note}>
                        “{s.note}”
                      </p>
                    )}
                  </div>
                  <div className="flex shrink-0 gap-1.5">
                    <Button
                      small
                      variant="ghost"
                      onClick={() => {
                        setEditingServer(s);
                        setFormMode('edit');
                      }}
                    >
                      <Pencil className="h-3.5 w-3.5" /> Edit
                    </Button>
                    <Button small variant="danger" onClick={() => setConfirmDelete(s)}>
                      <Trash2 className="h-3.5 w-3.5" />
                    </Button>
                  </div>
                </div>

                <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-line pt-3">
                  <ServerIcon className="h-3.5 w-3.5 shrink-0 text-accent" />
                  <p className="text-[11px] font-semibold uppercase tracking-wider text-muted">
                    Live in the app as its own node
                  </p>
                  {tweaks.length > 0 && (
                    <Badge>
                      also rides {tweaks.length} tweak{tweaks.length === 1 ? '' : 's'}
                    </Badge>
                  )}
                </div>
              </Card>
            );
          })}

          {hidden > 0 && (
            <Notice kind="info">
              {hidden} prox{hidden === 1 ? 'y is' : 'ies are'} hidden — they stay in the panel but are
              not published to the app.
            </Notice>
          )}
        </div>
      )}

      <Modal open={!!confirmDelete} onClose={() => setConfirmDelete(null)} title="Delete proxy?">
        <Notice kind="warn">
          “{confirmDelete?.name}” will disappear from the app as well. Proxies with tweaks attached
          cannot be deleted until those tweaks are removed.
        </Notice>
        <div className="mt-4 flex justify-end gap-2">
          <Button onClick={() => setConfirmDelete(null)}>Cancel</Button>
          <Button variant="danger" busy={busy} onClick={() => confirmDelete && doDelete(confirmDelete)}>
            Delete
          </Button>
        </div>
      </Modal>
    </div>
  );
}