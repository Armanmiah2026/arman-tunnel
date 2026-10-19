/**
 * Tweaks — the tunneling methods the app receives, grouped by category.
 *
 * A tweak = category + name + server + optional per-protocol options
 * (payload / SNI / proxy) + app-facing Options. This is the ONLY thing the
 * app's Configs menu shows: a category with no tweaks is still published
 * (empty section), a server with no tweaks is invisible.
 *
 * Categories live at the top (create inside the builder, delete when empty).
 * Editing a legacy standalone config (one that carries its own endpoint)
 * falls back to the full config editor.
 */
import React, { useMemo, useState } from 'react';
import {
  Layers,
  Pencil,
  Plus,
  QrCode,
  Search,
  SlidersHorizontal,
  Trash2,
} from 'lucide-react';
import type { Bootstrap, CategoryEntity, ServerConfig } from '../types';
import { api } from '../api';
import {
  Badge,
  Button,
  Card,
  EmptyState,
  Modal,
  Notice,
  PageHeader,
} from '../components/ui';
import { ShareModal } from '../components/ShareModal';
import { ConfigForm } from '../components/ConfigForm';
import { PROTOCOL_LABELS, TweaksForm, flagOf, type TweakDraft } from '../EntityForms';

export function TweaksPage(props: {
  data: Bootstrap;
  refresh: () => Promise<void>;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
  onGoServers: () => void;
}) {
  const { configs, servers, categories } = props.data;
  const [mode, setMode] = useState<'list' | 'new' | 'edit'>('list');
  const [editing, setEditing] = useState<ServerConfig | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<ServerConfig | null>(null);
  const [confirmDeleteCat, setConfirmDeleteCat] = useState<CategoryEntity | null>(null);
  const [shareTarget, setShareTarget] = useState<ServerConfig | null>(null);
  const [query, setQuery] = useState('');
  const [busy, setBusy] = useState(false);

  const byCategory = useMemo(() => {
    const m = new Map<string, ServerConfig[]>();
    for (const c of configs) {
      const key = String(c.category || 'global');
      if (!m.has(key)) m.set(key, []);
      m.get(key)!.push(c);
    }
    return m;
  }, [configs]);

  /** Known categories + any category values that exist only on tweaks
   *  (legacy enum values, or a category whose entity was deleted) — in
   *  panel order first, then first-seen order. */
  const displayCategories = useMemo(() => {
    const out: Array<{ name: string; country: string; id?: string }> = categories.map((c) => ({
      name: c.name,
      country: c.country,
      id: c.id,
    }));
    for (const name of byCategory.keys()) {
      if (!out.some((c) => c.name.toLowerCase() === name.toLowerCase())) {
        out.push({ name, country: '' });
      }
    }
    return out;
  }, [categories, byCategory]);

  const q = query.trim().toLowerCase();
  const matches = (c: ServerConfig) =>
    !q ||
    [c.name, c.note, c.server, c.category, c.author].join(' ').toLowerCase().includes(q);

  async function saveTweak(draft: TweakDraft) {
    setBusy(true);
    try {
      let categoryName = draft.tweak.category || '';
      // Inline category creation first (its name then rides the tweak).
      if (draft.newCategory && draft.newCategory.name) {
        try {
          const cat = await api.createCategory(draft.newCategory);
          categoryName = cat.category.name;
        } catch (e: any) {
          // Already exists (409) → keep going with the same name.
          if (!/already exists/i.test(String(e?.message || ''))) throw e;
        }
      }
      const body = { ...draft.tweak, category: categoryName };
      const res = editing
        ? await api.updateConfig(editing.id, body)
        : await api.createConfig(body);
      props.notify(
        res.publish.ok
          ? `${editing ? 'Saved' : 'Added'} "${res.config.name}" & published (${res.publish.nodes ?? 0} nodes live)`
          : `"${res.config.name}" saved — but GitHub push FAILED`,
        res.publish.ok ? 'success' : 'error',
      );
      await props.refresh();
      setMode('list');
      setEditing(null);
    } catch (e: any) {
      props.notify(e?.message || 'Save failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function saveLegacyConfig(partial: Partial<ServerConfig>) {
    setBusy(true);
    try {
      const res = editing
        ? await api.updateConfig(editing.id, partial)
        : await api.createConfig(partial);
      props.notify(
        res.publish.ok
          ? `Saved "${res.config.name}" & published`
          : `"${res.config.name}" saved — but GitHub push FAILED`,
        res.publish.ok ? 'success' : 'error',
      );
      await props.refresh();
      setMode('list');
      setEditing(null);
    } catch (e: any) {
      props.notify(e?.message || 'Save failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function doDeleteTweak(c: ServerConfig) {
    setBusy(true);
    setConfirmDelete(null);
    try {
      const res = await api.deleteConfig(c.id);
      props.notify(res.publish.ok ? `Deleted "${c.name}"` : 'Deleted — but GitHub push FAILED', 'info');
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Delete failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function doDeleteCategory(cat: CategoryEntity) {
    setBusy(true);
    setConfirmDeleteCat(null);
    try {
      const res = await api.deleteCategory(cat.id);
      props.notify(res.publish.ok ? `Deleted category "${cat.name}"` : 'Deleted — but GitHub push FAILED', 'info');
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Delete failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function toggleActive(c: ServerConfig) {
    setBusy(true);
    try {
      await api.patchConfig(c.id, { active: c.active === false });
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Toggle failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  // ------------------------------------------------------------------ editor
  if (mode !== 'list') {
    const isLegacyEdit = mode === 'edit' && editing != null && !editing.serverId;
    return (
      <div className="space-y-4">
        <PageHeader
          title={mode === 'edit' ? `Edit tweak — ${editing?.name ?? ''}` : 'New tweak'}
          caption={
            isLegacyEdit
              ? 'This is a legacy config carrying its own endpoint — the full editor is shown.'
              : 'Pick a category, name the tweak, choose its server, tick the options the protocol needs — validity is checked live.'
          }
        />
        {isLegacyEdit ? (
          <ConfigForm
            key={editing!.id}
            initial={editing}
            busy={busy}
            notify={props.notify}
            payloadDefs={props.data.settings?.payloadDefs}
            onSave={saveLegacyConfig}
            onCancel={() => {
              setMode('list');
              setEditing(null);
            }}
          />
        ) : (
          <TweaksForm
            key={editing?.id ?? 'new-tweak'}
            initial={mode === 'edit' ? editing : null}
            servers={servers}
            categories={categories}
            types={props.data.types}
            busy={busy}
            notify={props.notify}
            payloadDefs={props.data.settings?.payloadDefs}
            onSave={saveTweak}
            onCancel={() => {
              setMode('list');
              setEditing(null);
            }}
            onGoServers={() => {
              setMode('list');
              setEditing(null);
              props.notify('Add a server first — a tweak needs a server to ride on.', 'info');
              props.onGoServers();
            }}
          />
        )}
      </div>
    );
  }

  // -------------------------------------------------------------------- list
  const totalTweaks = configs.length;
  return (
    <div className="space-y-4">
      <PageHeader
        title="Tweaks"
        caption={`${totalTweaks} tweak${totalTweaks === 1 ? '' : 's'} in ${displayCategories.length} categor${displayCategories.length === 1 ? 'y' : 'ies'} · each tweak is a tuned variant of an endpoint. A bare endpoint needs none — see Proxies.`}
        actions={
          <Button
            variant="primary"
            onClick={() => {
              setEditing(null);
              setMode('new');
            }}
            disabled={!servers.length}
            title={servers.length ? undefined : 'Add a server first'}
          >
            <SlidersHorizontal className="h-4 w-4" /> New tweak
          </Button>
        }
      />

      {!servers.length && (
        <Notice kind="warn">
          No servers yet — a tweak needs a server to ride on.{' '}
          <button
            className="font-bold text-accent underline"
            onClick={() => {
              props.notify('Add a server first, then build tweaks on it.', 'info');
              props.onGoServers();
            }}
          >
            Go to Servers →
          </button>
        </Notice>
      )}

      {/* Search */}
      {totalTweaks > 0 && (
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-hint" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search tweaks…"
            className="w-full rounded-xl border border-line bg-bg py-2.5 pl-9 pr-3 text-[13px] outline-none placeholder:text-hint focus:border-accent"
          />
        </div>
      )}

      {/* Categories strip */}
      {displayCategories.length > 0 && (
        <Card>
          <p className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-muted">
            Categories — the app's Configs menu sections
          </p>
          <div className="flex flex-wrap gap-2">
            {displayCategories.map((c) => {
              const items = byCategory.get(c.name) || [];
              const deletable = !!c.id && items.length === 0;
              return (
                <div
                  key={c.name}
                  className="flex items-center gap-1.5 rounded-xl border border-line bg-bg px-2.5 py-1.5 text-xs"
                >
                  <span>{flagOf(c.country)}</span>
                  <span className="font-bold text-ink">{c.name}</span>
                  <span className="text-hint">({items.length})</span>
                  {c.id && (
                    <button
                      disabled={!deletable || busy}
                      title={deletable ? 'Delete category' : 'Only empty categories can be deleted'}
                      onClick={() => {
                        const cat = categories.find((x) => x.id === c.id);
                        if (cat) setConfirmDeleteCat(cat);
                      }}
                      className="ml-1 rounded-md p-0.5 text-hint transition hover:text-warn disabled:cursor-not-allowed disabled:opacity-40"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        </Card>
      )}

      {/* Tweaks grouped by category */}
      {totalTweaks === 0 ? (
        <EmptyState
          icon={<SlidersHorizontal className="h-8 w-8" />}
          title={categories.length ? 'No tweaks yet' : 'Nothing here yet'}
          caption={
            categories.length
              ? 'Open a category and add the first tweak — pick its server, tick payload/SNI if the protocol needs it.'
              : 'Create your first tweak — you will name its category along the way (e.g. "Normal Internet").'
          }
          action={
            <Button
              variant="primary"
              disabled={!servers.length}
              onClick={() => {
                setEditing(null);
                setMode('new');
              }}
            >
              <Plus className="h-4 w-4" /> New tweak
            </Button>
          }
        />
      ) : (
        displayCategories.map((cat) => {
          const items = (byCategory.get(cat.name) || []).filter(matches);
          if (q && items.length === 0) return null;
          return (
            <Card key={cat.name}>
              <div className="flex items-center gap-2">
                <span className="text-base leading-none">{flagOf(cat.country)}</span>
                <h3 className="text-sm font-bold text-ink">{cat.name}</h3>
                <Badge>{items.length}</Badge>
              </div>
              <div className="mt-3 space-y-1.5">
                {items.length === 0 && (
                  <p className="text-[11px] text-hint">Empty — this section still shows in the app.</p>
                )}
                {items.map((c) => (
                  <TweakRow
                    key={c.id}
                    tweak={c}
                    servers={servers}
                    onEdit={() => {
                      setEditing(c);
                      setMode('edit');
                    }}
                    onShare={() => setShareTarget(c)}
                    onDelete={() => setConfirmDelete(c)}
                    onToggle={() => void toggleActive(c)}
                  />
                ))}
              </div>
            </Card>
          );
        })
      )}

      <Modal open={!!confirmDelete} onClose={() => setConfirmDelete(null)} title="Delete tweak?">
        <Notice kind="warn">
          “{confirmDelete?.name}” will be removed and the bundle republished. The category stays.
        </Notice>
        <div className="mt-4 flex justify-end gap-2">
          <Button onClick={() => setConfirmDelete(null)}>Cancel</Button>
          <Button variant="danger" busy={busy} onClick={() => confirmDelete && doDeleteTweak(confirmDelete)}>
            Delete &amp; republish
          </Button>
        </div>
      </Modal>

      <Modal open={!!confirmDeleteCat} onClose={() => setConfirmDeleteCat(null)} title="Delete category?">
        <Notice kind="warn">
          Category “{confirmDeleteCat?.name}” will disappear from the app's Configs menu. Only
          empty categories can be deleted.
        </Notice>
        <div className="mt-4 flex justify-end gap-2">
          <Button onClick={() => setConfirmDeleteCat(null)}>Cancel</Button>
          <Button variant="danger" busy={busy} onClick={() => confirmDeleteCat && doDeleteCategory(confirmDeleteCat)}>
            Delete &amp; republish
          </Button>
        </div>
      </Modal>

      {shareTarget && (
        <ShareModal config={shareTarget} onClose={() => setShareTarget(null)} />
      )}
    </div>
  );
}

function TweakRow(props: {
  tweak: ServerConfig;
  servers: Bootstrap['servers'];
  onEdit: () => void;
  onShare: () => void;
  onDelete: () => void;
  onToggle: () => void;
}) {
  const c = props.tweak;
  const server = props.servers.find((s) => s.id === c.serverId);
  const expired = c.expiresAt > 0 && c.expiresAt < Date.now();
  return (
    <div className="flex items-center gap-2 rounded-xl border border-line bg-bg px-3 py-2">
      <Layers className="h-3.5 w-3.5 shrink-0 text-accent" />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-1.5">
          <p className="truncate text-xs font-semibold text-ink">{c.name}</p>
          {server && <Badge tone="accent">{PROTOCOL_LABELS[server.protocol] || server.protocol}</Badge>}
          {!server && <Badge>{PROTOCOL_LABELS[c.protocol] || c.protocol}</Badge>}
          {c.active === false && <Badge tone="warn">Hidden</Badge>}
          {c.locked && <Badge tone="warn">Locked</Badge>}
          {expired && <Badge tone="warn">Expired</Badge>}
        </div>
        <p className="truncate font-mono text-[10px] text-hint">
          {server ? `${server.name} · ${server.address}:${server.port}` : `${c.address}:${c.port}`}
          {methodSummary(c) ? ` · ${methodSummary(c)}` : ''}
        </p>
        {/* Sharer's note directly under the name row — small, muted, no
            "note:" label (same convention as the name itself). Hidden when
            blank or identical to the name. */}
        {String(c.note || '').trim() && String(c.note).trim() !== String(c.name).trim() && (
          <p className="mt-0.5 text-[10px] leading-snug text-hint">{String(c.note).trim()}</p>
        )}
      </div>
      <button
        onClick={props.onToggle}
        title={c.active === false ? 'Publish to app' : 'Hide from app'}
        className="rounded-md p-1.5 text-hint transition hover:text-accent"
      >
        <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="2">
          {c.active === false ? (
            <path d="M22.54 6.42a2.78 2.78 0 0 0-1.94-2C18.88 4 12 4 12 4s-6.88 0-8.6.46a2.78 2.78 0 0 0-1.94 2A29 29 0 0 0 1 11.75a29 29 0 0 0 .46 5.33A2.78 2.78 0 0 0 3.4 19c1.72.46 8.6.46 8.6.46s6.88 0 8.6-.46a2.78 2.78 0 0 0 1.94-2 29 29 0 0 0 .46-5.25 29 29 0 0 0-.46-5.33z" />
          ) : (
            <>
              <polygon points="23 7 16 12 23 17 23 7" />
              <rect x="1" y="5" width="15" height="14" rx="2" ry="2" />
            </>
          )}
        </svg>
      </button>
      <Button small variant="ghost" onClick={props.onShare}>
        <QrCode className="h-3.5 w-3.5" />
      </Button>
      <Button small variant="ghost" onClick={props.onEdit}>
        <Pencil className="h-3.5 w-3.5" />
      </Button>
      <Button small variant="danger" onClick={props.onDelete}>
        <Trash2 className="h-3.5 w-3.5" />
      </Button>
    </div>
  );
}

function methodSummary(c: ServerConfig): string {
  const parts: string[] = [];
  const mode = String(c.injectMode || 'none');
  if ((c.payload || '').trim() && mode !== 'none' && mode !== 'dnstt') {
    parts.push(`payload (${mode})`);
  }
  if (mode.includes('sni') || ((c.sni || '').trim() && mode !== 'none')) {
    parts.push(`sni: ${c.sni}`);
  }
  if (mode === 'dnstt') parts.push('slowdns');
  return parts.join(' · ');
}
