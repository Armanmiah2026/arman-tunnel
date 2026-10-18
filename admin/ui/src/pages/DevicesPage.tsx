/**
 * Devices — the BDIX user management system.
 *
 * Every device that registers (the app auto-registers its stable hardware id on
 * first launch) appears here automatically with full details: trial/VIP status,
 * app version, platform, connection count, redeemed keys, and admin notes.
 *
 * Flow: first launch → 1-day trial → admin grants VIP (permanent) or extends
 * the trial. The admin can also add a device permanently by typing its id.
 * Revoke = ban (the device can never re-trial; its id is burned).
 */
import React, { useCallback, useEffect, useState } from 'react';
import { KeyRound, Plus, Search, ShieldCheck, Trash2 } from 'lucide-react';
import type { LicenseKey, TrialDevice } from '../types';
import { api } from '../api';
import { Badge, Button, Card, EmptyState, Field, Modal, Notice, PageHeader } from '../components/ui';

function fmtDate(ms: number) {
  if (!ms) return '—';
  // Explicit English locale — a Bengali-locale phone renders plain
  // toLocaleString() in Bengali numerals, which reads as garbage here.
  return new Date(ms).toLocaleString('en-GB', {
    day: '2-digit',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function statusLabel(d: TrialDevice): { label: string; tone: 'accent' | 'warn' | 'muted' } {
  if (d.vip) return { label: 'VIP', tone: 'accent' };
  if (d.revoked) return { label: 'Revoked', tone: 'warn' };
  if (d.active && d.trial) return { label: 'Trial', tone: 'accent' };
  if (d.active) return { label: 'Active', tone: 'muted' };
  return { label: 'Expired', tone: 'warn' };
}

export function DevicesPage(props: {
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  const [devices, setDevices] = useState<TrialDevice[]>([]);
  const [keys, setKeys] = useState<LicenseKey[]>([]);
  const [busy, setBusy] = useState(false);
  const [keyDays, setKeyDays] = useState('7');
  const [keyDevice, setKeyDevice] = useState('');
  const [confirmRevoke, setConfirmRevoke] = useState<TrialDevice | null>(null);
  const [confirmDropVip, setConfirmDropVip] = useState<TrialDevice | null>(null);
  const [editNote, setEditNote] = useState<TrialDevice | null>(null);
  const [noteText, setNoteText] = useState('');
  const [query, setQuery] = useState('');
  const [addId, setAddId] = useState('');
  const [addNote, setAddNote] = useState('');
  const [lookupId, setLookupId] = useState('');
  const [lookupResult, setLookupResult] = useState<
    { registered: boolean; status: Record<string, any> | null } | null
  >(null);
  const [lookupBusy, setLookupBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const res = await api.getDevices();
      setDevices(res.devices);
      setKeys(res.keys);
    } catch (e: any) {
      props.notify(e?.message || 'Failed to load devices', 'error');
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function extend(d: TrialDevice, days: number) {
    setBusy(true);
    try {
      await api.extendDevice(d.id, days);
      props.notify(`Extended "${d.id}" by ${days} day${days === 1 ? '' : 's'}`, 'success');
      await load();
    } catch (e: any) {
      props.notify(e?.message || 'Extend failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function addPermanently() {
    const id = addId.trim();
    if (!id) {
      props.notify('Enter a device id', 'error');
      return;
    }
    setBusy(true);
    try {
      await api.addDevice(id, { note: addNote.trim() || undefined });
      props.notify(`Added "${id}" permanently (VIP)`, 'success');
      setAddId('');
      setAddNote('');
      await load();
    } catch (e: any) {
      props.notify(e?.message || 'Add failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function grantVip(d: TrialDevice) {
    setBusy(true);
    try {
      await api.grantVip(d.id);
      props.notify(`Granted permanent VIP to "${d.id}"`, 'success');
      await load();
    } catch (e: any) {
      props.notify(e?.message || 'Grant VIP failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function dropVip(d: TrialDevice) {
    setBusy(true);
    setConfirmDropVip(null);
    try {
      await api.revokeVip(d.id);
      props.notify(`VIP revoked for "${d.id}" — access ended (not banned)`, 'success');
      await load();
    } catch (e: any) {
      props.notify(e?.message || 'Revoke VIP failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function lookup() {
    const id = lookupId.trim();
    if (!id) {
      props.notify('Enter a device id', 'error');
      return;
    }
    setLookupBusy(true);
    setLookupResult(null);
    try {
      const res = await api.lookupDevice(id);
      setLookupResult(res);
      if (!res.registered) {
        props.notify(`Device "${id}" is not registered yet`, 'info');
      }
    } catch (e: any) {
      props.notify(e?.message || 'Lookup failed', 'error');
    } finally {
      setLookupBusy(false);
    }
  }

  async function issueKey() {
    setBusy(true);
    try {
      const days = Math.max(1, parseInt(keyDays, 10) || 7);
      const res = await api.createKey(days, keyDevice.trim() || undefined);
      props.notify(`Key ${res.key} issued (${days} days)`, 'success');
      setKeyDays('7');
      setKeyDevice('');
      await load();
    } catch (e: any) {
      props.notify(e?.message || 'Could not issue key', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function revoke(d: TrialDevice) {
    setBusy(true);
    setConfirmRevoke(null);
    try {
      await api.revokeDevice(d.id);
      props.notify(`Banned "${d.id}" — the device cannot re-trial`, 'info');
      await load();
    } catch (e: any) {
      props.notify(e?.message || 'Ban failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  async function saveNote() {
    if (!editNote) return;
    setBusy(true);
    try {
      await api.updateDevice(editNote.id, { note: noteText });
      props.notify('Note saved', 'success');
      setEditNote(null);
      await load();
    } catch (e: any) {
      props.notify(e?.message || 'Save failed', 'error');
    } finally {
      setBusy(false);
    }
  }

  const active = devices.filter((d) => d.active).length;
  const trials = devices.filter((d) => d.trial && d.active).length;
  const vips = devices.filter((d) => d.vip).length;
  const filtered = query.trim()
    ? devices.filter(
        (d) =>
          d.id.toLowerCase().includes(query.toLowerCase()) ||
          (d.note || '').toLowerCase().includes(query.toLowerCase()) ||
          (d.platform || '').toLowerCase().includes(query.toLowerCase()),
      )
    : devices;

  return (
    <div className="space-y-4">
      <PageHeader
        title="Users"
        caption={`${devices.length} device${devices.length === 1 ? '' : 's'} · ${active} active · ${trials} on trial · ${vips} VIP. Search, extend, grant VIP, or ban users.`}
      />

      {/* Search */}
      <div className="relative">
        <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />
        <input
          className="w-full rounded-lg border border-border bg-surface py-2 pl-9 pr-3 text-sm text-ink placeholder:text-muted focus:border-accent focus:outline-none"
          placeholder="Search by device id, note, or platform…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </div>

      {/* Lookup a device by id */}
      <Card>
        <div className="flex items-center gap-2">
          <Search className="h-4 w-4 text-accent" />
          <h3 className="text-sm font-bold text-ink">Lookup device</h3>
        </div>
        <p className="mt-1 text-[11px] text-muted">
          Type a device id to see its status — even if it hasn't registered yet.
        </p>
        <div className="mt-3 flex flex-wrap items-end gap-2">
          <div className="min-w-40 flex-1">
            <Field
              label="Device ID"
              value={lookupId}
              onChange={setLookupId}
              placeholder="e.g. a1b2c3d4e5f6…"
              mono
            />
          </div>
          <Button variant="primary" busy={lookupBusy} onClick={lookup}>
            <Search className="h-4 w-4" /> Lookup
          </Button>
        </div>
        {lookupResult && (
          <div className="mt-3 rounded-lg border border-border bg-surface p-3">
            {lookupResult.registered && lookupResult.status ? (
              <div className="space-y-1 text-[12px]">
                <div className="flex items-center gap-2">
                  <span className="break-all font-mono font-bold text-ink">{lookupId.trim().toLowerCase()}</span>
                  {lookupResult.status.vip ? (
                    <Badge tone="accent">VIP</Badge>
                  ) : lookupResult.status.active ? (
                    <Badge tone="accent">Active</Badge>
                  ) : (
                    <Badge tone="warn">Expired</Badge>
                  )}
                </div>
                <p className="text-muted">
                  {lookupResult.status.vip
                    ? 'VIP — permanent access'
                    : lookupResult.status.active
                      ? `Expires ${fmtDate(lookupResult.status.expiresAt)} (${lookupResult.status.daysLeft}d left)`
                      : `Expired ${fmtDate(lookupResult.status.expiresAt)}`}
                </p>
                {lookupResult.status.platform && (
                  <p className="text-muted">
                    {lookupResult.status.platform} · app v{lookupResult.status.appVersion || '—'}
                  </p>
                )}
                <p className="text-muted">
                  {lookupResult.status.connectCount} connection{lookupResult.status.connectCount === 1 ? '' : 's'}
                </p>
              </div>
            ) : (
              <div className="text-[12px]">
                <p className="text-muted">This device has not registered yet.</p>
                <p className="mt-1 text-muted">
                  You can add it permanently below, or ask the user to open the app first.
                </p>
              </div>
            )}
          </div>
        )}
      </Card>

      {/* Add device permanently */}
      <Card>
        <div className="flex items-center gap-2">
          <Plus className="h-4 w-4 text-accent" />
          <h3 className="text-sm font-bold text-ink">Add device permanently</h3>
        </div>
        <p className="mt-1 text-[11px] text-muted">
          Type the device id (the user can find it in My Access). The device gets VIP access immediately.
        </p>
        <div className="mt-3 flex flex-wrap items-end gap-2">
          <div className="min-w-40 flex-1">
            <Field
              label="Device ID"
              value={addId}
              onChange={setAddId}
              placeholder="e.g. a1b2c3d4e5f6…"
              mono
            />
          </div>
          <div className="min-w-40 flex-1">
            <Field
              label="Note (optional)"
              value={addNote}
              onChange={setAddNote}
              placeholder="e.g. paid via bKash"
            />
          </div>
          <Button variant="primary" busy={busy} onClick={addPermanently}>
            <Plus className="h-4 w-4" /> Add permanently
          </Button>
        </div>
      </Card>

      {/* Issue a license key */}
      <Card>
        <div className="flex items-center gap-2">
          <KeyRound className="h-4 w-4 text-accent" />
          <h3 className="text-sm font-bold text-ink">Issue a license key</h3>
        </div>
        <p className="mt-1 text-[11px] text-muted">
          The key extends a device's access and binds to it. Show it to the user (it also appears on their device).
        </p>
        <div className="mt-3 flex flex-wrap items-end gap-2">
          <div className="w-28">
            <Field
              label="Days"
              type="number"
              min={1}
              max={3650}
              value={keyDays}
              onChange={setKeyDays}
            />
          </div>
          <div className="min-w-40 flex-1">
            <Field
              label="Bind to device (optional)"
              value={keyDevice}
              onChange={setKeyDevice}
              placeholder="blank = any device"
              mono
            />
          </div>
          <Button variant="primary" busy={busy} onClick={issueKey}>
            <Plus className="h-4 w-4" /> Issue key
          </Button>
        </div>
      </Card>

      {/* Device list */}
      {!filtered.length ? (
        <EmptyState
          icon={<ShieldCheck className="h-8 w-8" />}
          title={query ? 'No matching users' : 'No users yet'}
          caption={
            query
              ? 'Try a different search term.'
              : 'When a user opens the app, their device registers here automatically and starts a 1-day BDIX trial.'
          }
        />
      ) : (
        <div className="space-y-3">
          {filtered.map((d) => {
            const st = statusLabel(d);
            return (
              <Card key={d.id}>
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-1.5">
                      <span className="break-all font-mono text-[13px] font-bold text-ink">{d.id}</span>
                      <Badge tone={st.tone}>{st.label}</Badge>
                      {d.extended && !d.vip && <Badge>Extended</Badge>}
                      {d.ipCount >= 2 && (
                        <Badge
                          tone={d.ipCount >= 5 ? 'warn' : 'outline'}
                          title={`${d.ipCount} devices registered from the same IP${d.regIp ? ` (${d.regIp})` : ''} — possible trial farming`}
                        >
                          {d.ipCount} from this IP
                        </Badge>
                      )}
                    </div>
                    <p className="mt-1 text-[11px] text-muted">
                      First seen {fmtDate(d.firstSeen)} · last seen {fmtDate(d.lastSeen)}
                    </p>
                    <p className="text-[11px] text-muted">
                      {d.vip
                        ? 'VIP access — permanent (no expiry)'
                        : d.revoked
                          ? 'Banned — cannot connect, and the device will NOT get a new trial'
                          : d.active
                            ? `Expires ${fmtDate(d.expiresAt)} (${d.daysLeft}d left)`
                            : `Expired ${fmtDate(d.expiresAt)}`}
                    </p>
                    {d.platform && (
                      <p className="mt-1 text-[11px] text-muted">
                        {d.platform} · app v{d.appVersion || '—'}
                      </p>
                    )}
                    <p className="text-[11px] text-muted">
                      {d.connectCount} connection{d.connectCount === 1 ? '' : 's'}
                      {d.lastConnected > 0 && ` · last ${fmtDate(d.lastConnected)}`}
                    </p>
                    {d.note && (
                      <p className="mt-1 rounded bg-surface px-2 py-1 text-[11px] text-muted">
                        Note: {d.note}
                      </p>
                    )}
                  </div>
                  <div className="flex shrink-0 flex-wrap justify-end gap-1.5">
                    {!d.vip && (
                      <>
                        <Button small variant="ghost" disabled={busy} onClick={() => extend(d, 1)}>
                          +1d
                        </Button>
                        <Button small variant="ghost" disabled={busy} onClick={() => extend(d, 7)}>
                          +7d
                        </Button>
                        <Button small variant="ghost" disabled={busy} onClick={() => extend(d, 30)}>
                          +30d
                        </Button>
                        <Button small variant="primary" disabled={busy} onClick={() => grantVip(d)}>
                          Grant VIP
                        </Button>
                      </>
                    )}
                    {d.vip && !d.revoked && (
                      <Button small variant="ghost" disabled={busy} onClick={() => setConfirmDropVip(d)}>
                        Drop VIP
                      </Button>
                    )}
                    <Button
                      small
                      variant="ghost"
                      onClick={() => {
                        setEditNote(d);
                        setNoteText(d.note || '');
                      }}
                    >
                      Note
                    </Button>
                    <Button small variant="danger" onClick={() => setConfirmRevoke(d)}>
                      <Trash2 className="h-3.5 w-3.5" />
                    </Button>
                  </div>
                </div>
              </Card>
            );
          })}
        </div>
      )}

      {/* Issued keys */}
      {keys.length > 0 && (
        <Card>
          <div className="flex items-center gap-2">
            <KeyRound className="h-4 w-4 text-accent" />
            <h3 className="text-sm font-bold text-ink">Issued keys</h3>
          </div>
          <div className="mt-2 space-y-1.5">
            {keys.map((k) => (
              <div key={k.key} className="flex flex-wrap items-center gap-2 text-[12px]">
                <span className="break-all font-mono font-bold text-ink">{k.key}</span>
                <Badge>{k.days}d</Badge>
                {k.deviceId && <Badge tone="accent">bound</Badge>}
                {k.redeemedBy ? (
                  <span className="text-muted">
                    redeemed by <span className="break-all font-mono">{k.redeemedBy}</span> {fmtDate(k.redeemedAt)}
                  </span>
                ) : (
                  <span className="text-muted">unused</span>
                )}
              </div>
            ))}
          </div>
        </Card>
      )}

      {/* Edit note modal */}
      <Modal open={!!editNote} onClose={() => setEditNote(null)} title="Edit note">
        <p className="mb-2 text-[12px] text-muted">
          Note for <span className="break-all font-mono font-bold text-ink">{editNote?.id}</span>
        </p>
        <textarea
          className="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-ink focus:border-accent focus:outline-none"
          rows={3}
          value={noteText}
          onChange={(e) => setNoteText(e.target.value)}
          placeholder="e.g. paid via bKash, family user…"
        />
        <div className="mt-4 flex justify-end gap-2">
          <Button onClick={() => setEditNote(null)}>Cancel</Button>
          <Button variant="primary" busy={busy} onClick={saveNote}>
            Save note
          </Button>
        </div>
      </Modal>

      {/* Revoke (ban) confirm */}
      <Modal open={!!confirmRevoke} onClose={() => setConfirmRevoke(null)} title="Ban device?">
        <Notice kind="warn">
          This bans <span className="font-mono font-bold">{confirmRevoke?.id}</span> — the device
          cannot connect and will <b>NOT</b> get a new trial, even after reinstalling the app. Its
          trial/VIP access and keys are cleared. Reactivate later with +d or Grant VIP.
        </Notice>
        <div className="mt-4 flex justify-end gap-2">
          <Button onClick={() => setConfirmRevoke(null)}>Cancel</Button>
          <Button variant="danger" busy={busy} onClick={() => confirmRevoke && revoke(confirmRevoke)}>
            Ban device
          </Button>
        </div>
      </Modal>

      {/* Drop VIP (not a ban) confirm */}
      <Modal open={!!confirmDropVip} onClose={() => setConfirmDropVip(null)} title="Revoke VIP access?">
        <Notice kind="warn">
          <span className="font-mono font-bold">{confirmDropVip?.id}</span> loses permanent VIP:
          VIP servers stop auto-opening and access ends immediately (the app falls back to the ad
          / extend flow). The device is <b>not</b> banned and keeps its record. Grant VIP again any
          time, or hand out days with +d.
        </Notice>
        <div className="mt-4 flex justify-end gap-2">
          <Button onClick={() => setConfirmDropVip(null)}>Cancel</Button>
          <Button variant="danger" busy={busy} onClick={() => confirmDropVip && dropVip(confirmDropVip)}>
            Revoke VIP
          </Button>
        </div>
      </Modal>
    </div>
  );
}
