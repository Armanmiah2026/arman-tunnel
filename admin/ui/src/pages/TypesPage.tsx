/**
 * Types — the capability-type manager (Server ↔ Tweak compatibility system).
 * Types are what a server SUPPORTS and a tweak IS; the join between them is
 * dynamic. Admins create/edit/enable/disable types here; disabled types
 * drop out of the pickers and the app's Custom Tweak list, and deleting one
 * strips it from every server.
 */
import React, { useState } from 'react';
import { api } from '../api';
import type { CapabilityType } from '../types';
import {
  Badge,
  Button,
  Card,
  Field,
  Modal,
  PageHeader,
  SectionTitle,
} from '../components/ui';

export function TypesPage(props: {
  types: CapabilityType[];
  servers: Array<{ id: string; name: string; capabilities?: string[] }>;
  refresh: () => Promise<void>;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  const [busy, setBusy] = useState('');
  const [editOpen, setEditOpen] = useState(false);
  const [editing, setEditing] = useState<CapabilityType | null>(null);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [confirmDel, setConfirmDel] = useState<CapabilityType | null>(null);

  function openEdit(t: CapabilityType | null) {
    setEditing(t);
    setName(t?.name ?? '');
    setDescription(t?.description ?? '');
    setEditOpen(true);
  }

  async function save() {
    const trimmed = name.trim().toUpperCase().replace(/\s+/g, '_');
    if (!trimmed) return;
    setBusy('save');
    try {
      if (editing) {
        await api.updateType(editing.id, { name: trimmed, description: description.trim() });
        props.notify(`Type [${trimmed}] updated`, 'success');
      } else {
        await api.createType({ name: trimmed, description: description.trim() });
        props.notify(`Type [${trimmed}] created`, 'success');
      }
      setEditOpen(false);
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Save failed', 'error');
    } finally {
      setBusy('');
    }
  }

  async function toggleEnabled(t: CapabilityType) {
    setBusy('en-' + t.id);
    try {
      await api.updateType(t.id, { enabled: t.enabled === false });
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Failed', 'error');
    } finally {
      setBusy('');
    }
  }

  async function doDelete() {
    if (!confirmDel) return;
    setBusy('del');
    try {
      await api.deleteType(confirmDel.id);
      props.notify(`Type [${confirmDel.name}] deleted — removed from every server`, 'info');
      setConfirmDel(null);
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Delete failed', 'error');
    } finally {
      setBusy('');
    }
  }

  const usage = (tname: string) =>
    props.servers.filter((s) => (s.capabilities || []).includes(tname));

  return (
    <div className="space-y-4">
      <PageHeader
        title="Types"
        caption="Capability markers: a server SUPPORTS types, a tweak IS one — matching is dynamic, so a dead server never kills a tweak. Types ride the settings bundle: new ones reach the app without an update."
      />

      <Card>
        <SectionTitle
          title={`Capability types (${props.types.length})`}
          caption="Used by servers (capabilities) and tweaks (their type). Renaming follows every server + tweak."
        />
        <div className="space-y-2">
          {props.types.map((t) => {
            const servers = usage(t.name);
            return (
              <div
                key={t.id}
                className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-line bg-bg px-3 py-2"
              >
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-[13px] font-bold text-ink">[{t.name}]</span>
                    {t.enabled === false && <Badge tone="warn">disabled</Badge>}
                    <Badge tone="accent">{servers.length} server{servers.length === 1 ? '' : 's'}</Badge>
                  </div>
                  {t.description && (
                    <p className="mt-0.5 truncate text-[11px] text-hint">{t.description}</p>
                  )}
                  {servers.length > 0 && (
                    <p className="mt-0.5 truncate text-[11px] text-hint">
                      {servers.map((s) => s.name).join(' · ')}
                    </p>
                  )}
                </div>
                <div className="flex gap-1.5">
                  <Button small onClick={() => openEdit(t)}>Edit</Button>
                  <Button small busy={busy === 'en-' + t.id} onClick={() => void toggleEnabled(t)}>
                    {t.enabled === false ? 'Enable' : 'Disable'}
                  </Button>
                  <Button small variant="danger" onClick={() => setConfirmDel(t)}>
                    Delete
                  </Button>
                </div>
              </div>
            );
          })}
        </div>
        <div className="mt-3">
          <Button variant="primary" onClick={() => openEdit(null)}>New type…</Button>
        </div>
      </Card>

      <Modal
        open={editOpen}
        onClose={() => setEditOpen(false)}
        title={editing ? `Edit type [${editing.name}]` : 'New capability type'}
      >
        <Field
          label="Name (marker)"
          value={name}
          onChange={(v) => setName(v.toUpperCase())}
          placeholder="PROXY+PAYLOAD"
          hint="Uppercase marker shown as [NAME]"
        />
        <Field
          label="Description (optional)"
          value={description}
          onChange={setDescription}
          placeholder="SSH payload through a bug host proxy"
        />
        <div className="mt-3 flex justify-end gap-2">
          <Button onClick={() => setEditOpen(false)}>Cancel</Button>
          <Button variant="primary" disabled={!name.trim()} busy={busy === 'save'} onClick={() => void save()}>
            {editing ? 'Save' : 'Create'}
          </Button>
        </div>
      </Modal>

      <Modal open={confirmDel != null} onClose={() => setConfirmDel(null)} title={`Delete [${confirmDel?.name}]?`}>
        <p className="text-sm text-muted">
          Every server loses this capability, and tweaks using it move to{' '}
          <b className="text-accent">[DIRECT]</b> (plain connection) — nothing is orphaned.
        </p>
        <div className="mt-3 flex justify-end gap-2">
          <Button onClick={() => setConfirmDel(null)}>Cancel</Button>
          <Button variant="danger" busy={busy === 'del'} onClick={() => void doDelete()}>
            Delete
          </Button>
        </div>
      </Modal>
    </div>
  );
}
