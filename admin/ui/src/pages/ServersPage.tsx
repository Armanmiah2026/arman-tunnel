/**
 * Servers — the raw endpoints that TUNED variants are built on.
 *
 * A server here is a starting point for tweaks: it holds the endpoint +
 * credentials once, and every tweak that references it inherits them. It does
 * NOT need a tweak to reach the app — a server publishes as its own plain node
 * too, which the Proxies tab surfaces directly. This page is the "tweak
 * plumbing" view; the Proxies tab is the user-facing one.
 */
import React, { useMemo, useState } from 'react';
import {
  Pencil,
  Plus,
  Server as ServerIcon,
  SlidersHorizontal,
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

export function ServersPage(props: {
  data: Bootstrap;
  refresh: () => Promise<void>;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
  onGoTweaks?: () => void;
  /** Jump to the Proxies tab (a proxy needs no tweak to reach the app). */
  onGoProxies?: () => void;
}) {
  const { configs, servers } = props.data;
  const [formMode, setFormMode] = useState<'closed' | 'new' | 'edit'>('closed');
  const [editingServer, setEditingServer] = useState<ServerEntity | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<ServerEntity | null>(null);
  const [busy, setBusy] = useState(false);
  const [highlightId, setHighlightId] = useState('');

  /** Tweaks per server (a tweak is a config with serverId). */
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

  /** Close the form, then scroll the freshly saved server into view and
   *  flash its card so the admin sees exactly where it landed. */
  function revealServer(id: string) {
    setFormMode('closed');
    setEditingServer(null);
    setHighlightId(id);
    setTimeout(() => {
      document.getElementById(`srv-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }, 80);
    setTimeout(() => setHighlightId(''), 2600);
  }

  async function saveServer(server: Partial<ServerEntity>) {
    setBusy(true);
    try {
      const res = editingServer
        ? await api.updateServer(editingServer.id, server)
        : await api.createServer(server);
      // A failed GitHub push must surface — but it never masks the save.
      const pubOk = res.publish?.ok !== false;
      const pubWhy = pubOk ? '' : ' — GitHub push FAILED: ' + (publishErrorText(res.publish) || 'unknown error');
      props.notify(
        editingServer
          ? pubOk
            ? `Server "${res.server.name}" saved`
            : `Server "${res.server.name}" saved${pubWhy}`
          : pubOk
            ? `Server "${res.server.name}" added — live in the app, and ready for tweaks`
            : `Server "${res.server.name}" added${pubWhy}`,
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
      props.notify(`Deleted server "${s.name}"`, 'info');
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
          title={formMode === 'edit' ? `Edit server — ${editingServer?.name ?? ''}` : 'New server'}
          caption="Raw endpoint + credentials, shared by every tweak that references it. Payload, SNI, DNS and injection live on those tweaks."
        />
        <ServerForm
          key={editingServer?.id ?? 'new-server'}
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
  const unlinked = configs.filter((c) => !c.serverId).length;
  // Only tunnel ENDPOINT servers (ssh/vless/openvpn/…) live here — actual
  // PROXY endpoints (socks/http_proxy/psiphon) are first-class nodes and
  // live on the Proxies tab. Publishing them here too flooded the app's
  // Configs list with bare server copies (and old app versions with nodes
  // they cannot group).
  const endpoints = servers.filter((s) => !isProxyNode(s));
  return (
    <div className="space-y-4">
      <PageHeader
        title="Servers"
        caption={`${endpoints.length} server${endpoints.length === 1 ? '' : 's'} · each anchors tweaks; proxy endpoints live on the Proxies tab.`}
        actions={
          <Button
            variant="primary"
            onClick={() => {
              setEditingServer(null);
              setFormMode('new');
            }}
          >
            <ServerIcon className="h-4 w-4" /> New server
          </Button>
        }
      />

      {!endpoints.length ? (
        <EmptyState
          icon={<ServerIcon className="h-8 w-8" />}
          title="No servers yet"
          caption="Add the raw server (protocol + host + credentials) first. Tweaks are then stacked on it without re-typing anything."
          action={
            <Button
              variant="primary"
              onClick={() => {
                setEditingServer(null);
                setFormMode('new');
              }}
            >
              <Plus className="h-4 w-4" /> New server
            </Button>
          }
        />
      ) : (
        <div className="space-y-3">
          {endpoints.map((s) => {
            const tweaks = tweaksByServer.get(s.id) || [];
            const highlighted = highlightId === s.id;
            return (
              <Card key={s.id} className={highlighted ? 'anim-pop ring-2 ring-accent' : ''}>
                <div id={`srv-${s.id}`} className="flex items-start justify-between gap-3">
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
                      {s.protocol === 'ssh' && s.port !== 443 && s.port !== 22 && (
                        <Badge>:{s.port}</Badge>
                      )}
                      {s.transport !== 'tcp' && <Badge>{s.transport.toUpperCase()}</Badge>}
                      {s.security !== 'none' && <Badge>{s.security.toUpperCase()}</Badge>}
                      {s.active === false && <Badge tone="warn">Hidden</Badge>}
                    </div>
                    <p className="mt-1 truncate font-mono text-[11px] text-hint" title={`${s.address}:${s.port}`}>
                      {s.address}:{s.port}
                    </p>
                    {s.region && <p className="mt-0.5 truncate text-[11px] text-muted">{s.region}</p>}
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

                <div className="mt-3 flex items-center gap-2 border-t border-line pt-3">
                  <SlidersHorizontal className="h-3.5 w-3.5 shrink-0 text-accent" />
                  <p className="text-[11px] font-semibold uppercase tracking-wider text-muted">
                    {tweaks.length
                      ? `${tweaks.length} tweak${tweaks.length === 1 ? '' : 's'} attached`
                      : 'No tweaks attached — still reaches the app on its own'}
                  </p>
                </div>
              </Card>
            );
          })}

          {unlinked > 0 && (
            <Notice kind="warn">
              {unlinked} legacy config{unlinked === 1 ? '' : 's'} carry their own endpoint (no
              server reference). Manage them on the Tweaks tab.
            </Notice>
          )}
        </div>
      )}

      <Modal open={!!confirmDelete} onClose={() => setConfirmDelete(null)} title="Delete server?">
        <Notice kind="warn">
          “{confirmDelete?.name}” will be removed from the server list. Servers with tweaks
          attached cannot be deleted — remove the tweaks first.
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
