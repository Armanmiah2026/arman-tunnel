/**
 * Settings — deployment truth (repo/crypto), extra admin accounts, danger zone.
 * The GitHub/encryption facts are read-only here on purpose: they live in
 * Worker secrets + wrangler.toml, not in the panel.
 */
import React, { useEffect, useState } from 'react';
import { api } from '../api';
import type { Bootstrap } from '../types';
import {
  Badge,
  Button,
  Card,
  Field,
  Modal,
  Notice,
  PageHeader,
  SectionTitle,
} from '../components/ui';

export function SettingsPage(props: {
  data: Bootstrap;
  refresh: () => Promise<void>;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  const isDev = props.data.role === 'dev';
  const [admins, setAdmins] = useState<Array<{ username: string; createdAt: string }>>([]);
  const [newUser, setNewUser] = useState('');
  const [newPass, setNewPass] = useState('');
  const [curPass, setCurPass] = useState('');
  const [myPass1, setMyPass1] = useState('');
  const [myPass2, setMyPass2] = useState('');
  const [busy, setBusy] = useState('');
  const [dangerOpen, setDangerOpen] = useState(false);
  const [confirmText, setConfirmText] = useState('');
  const [restoreOpen, setRestoreOpen] = useState(false);
  const [restoreText, setRestoreText] = useState('');
  const [restoreBusy, setRestoreBusy] = useState('');

  async function loadAdmins() {
    try {
      const res = await api.admins();
      setAdmins(res.admins);
    } catch {
      /* non-fatal */
    }
  }

  useEffect(() => {
    void loadAdmins();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function addAdmin() {
    setBusy('add');
    try {
      await api.addAdmin(newUser.trim(), newPass);
      props.notify(`Admin "${newUser.trim()}" created`, 'success');
      setNewUser('');
      setNewPass('');
      await loadAdmins();
    } catch (e: any) {
      props.notify(e?.message || 'Failed to create admin', 'error');
    } finally {
      setBusy('');
    }
  }

  async function removeAdmin(username: string) {
    setBusy('rm-' + username);
    try {
      await api.removeAdmin(username);
      await loadAdmins();
      props.notify(`Admin "${username}" removed`, 'info');
    } catch (e: any) {
      props.notify(e?.message || 'Failed to remove', 'error');
    } finally {
      setBusy('');
    }
  }

  async function changeMyPassword() {
    if (myPass1 !== myPass2) {
      props.notify('New passwords do not match', 'error');
      return;
    }
    setBusy('pw');
    try {
      await api.changePassword(curPass, myPass1);
      props.notify('Password changed — use the new password from the next login', 'success');
      setCurPass('');
      setMyPass1('');
      setMyPass2('');
    } catch (e: any) {
      props.notify(e?.message || 'Failed to change password', 'error');
    } finally {
      setBusy('');
    }
  }

  async function deleteAllConfigs() {
    setBusy('wipe');
    try {
      await api.deleteAllConfigs();
      await props.refresh();
      setDangerOpen(false);
      setConfirmText('');
      props.notify('All nodes deleted and empty bundle published', 'info');
    } catch (e: any) {
      props.notify(e?.message || 'Failed', 'error');
    } finally {
      setBusy('');
    }
  }

  async function downloadBackup() {
    setRestoreBusy('dl');
    try {
      const snap = await api.downloadBackup();
      const blob = new Blob([JSON.stringify(snap, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `sensei-backup-${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      URL.revokeObjectURL(url);
      props.notify(
        `Backup downloaded (${snap.configs.length} configs, ${snap.servers.length} servers, ${snap.categories.length} categories)`,
        'success',
      );
    } catch (e: any) {
      props.notify(e?.message || 'Backup download failed', 'error');
    } finally {
      setRestoreBusy('');
    }
  }

  async function restoreFromText() {
    setRestoreBusy('json');
    try {
      const snapshot = JSON.parse(restoreText);
      const res = await api.restoreBackup(snapshot);
      props.notify(
        `Restored ${res.restored.configs} configs / ${res.restored.servers} servers / ${res.restored.categories} categories`,
        res.publish.ok ? 'success' : 'error',
      );
      setRestoreOpen(false);
      setRestoreText('');
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Restore failed', 'error');
    } finally {
      setRestoreBusy('');
    }
  }

  async function restoreFromGithub() {
    setRestoreBusy('gh');
    try {
      const res = await api.restoreBackupFromGithub();
      props.notify(
        `Restored from GitHub: ${res.restored.configs} configs / ${res.restored.servers} servers / ${res.restored.categories} categories`,
        res.publish.ok ? 'success' : 'error',
      );
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Restore failed', 'error');
    } finally {
      setRestoreBusy('');
    }
  }

  const d = props.data;
  return (
    <div className="space-y-4">
      <PageHeader title="Settings" caption="Deployment facts and admin accounts. Secrets never appear in this panel." />

      <Card>
        <SectionTitle
          title="Change password"
          caption={`Signed in as ${props.data.me}. Applies to this account only — the new password is stored salted + PBKDF2.`}
        />
        <div className="grid gap-2 sm:grid-cols-3">
          <Field label="Current password" type="password" value={curPass} onChange={setCurPass} />
          <Field label="New password" type="password" value={myPass1} onChange={setMyPass1} hint="Minimum 8 characters" />
          <Field label="Repeat new password" type="password" value={myPass2} onChange={setMyPass2} />
        </div>
        <div className="mt-2 flex justify-end">
          <Button
            variant="primary"
            small
            disabled={!curPass || myPass1.length < 8 || myPass1 !== myPass2}
            busy={busy === 'pw'}
            onClick={changeMyPassword}
          >
            Change password
          </Button>
        </div>
      </Card>

      <Card>
        <SectionTitle title="Config delivery" caption="Where the app's encrypted bundles are published and how they are sealed." />
        <dl className="space-y-2 text-[13px]">
          <Fact label="Repo" value={`${d.repo.repo} · ${d.repo.branch}`} mono />
          <Fact label="Nodes file" value={d.repo.configFileUrl || d.repo.configFile} mono link />
          <Fact label="Settings file" value={d.repo.settingsFileUrl || d.repo.settingsFile} mono link />
          <Fact
            label="Envelope"
            value={d.crypto.certBound ? `v3 — signature-bound to app cert` : 'v2 — shared key'}
            right={
              d.crypto.certBound ? (
                <Badge tone="accent">cert-bound</Badge>
              ) : (
                <Badge tone="warn">set APP_CERT_SHA256 for v3</Badge>
              )
            }
          />
          {d.crypto.certSha256 && <Fact label="App cert" value={d.crypto.certSha256} mono />}
        </dl>
        {!d.github.configured && (
          <div className="mt-3">
            <Notice kind="warn">
              GITHUB_TOKEN / GITHUB_REPO secrets are missing — nothing can be published to the app.
            </Notice>
          </div>
        )}
      </Card>

      {isDev && (
        <Card>
          <SectionTitle title="Admin accounts" caption={`Primary: ${d.me}. Extra accounts get their own password (stored salted+PBKDF2).`} />
          <div className="space-y-2">
            {admins.map((a) => (
              <div key={a.username} className="flex items-center justify-between gap-2 rounded-xl border border-line bg-bg px-3 py-2">
                <span className="text-[13px] font-semibold text-ink">{a.username}</span>
                <Button small variant="danger" busy={busy === 'rm-' + a.username} onClick={() => removeAdmin(a.username)}>
                  Remove
                </Button>
              </div>
            ))}
          </div>
          <div className="mt-3 grid gap-2 sm:grid-cols-2">
            <Field label="Username" value={newUser} onChange={setNewUser} placeholder="co_admin" />
            <Field label="Password" type="password" value={newPass} onChange={setNewPass} hint="Minimum 8 characters" />
          </div>
          <div className="mt-2 flex justify-end">
            <Button variant="primary" small disabled={!newUser.trim() || newPass.length < 8} busy={busy === 'add'} onClick={addAdmin}>
              Create admin
            </Button>
          </div>
        </Card>
      )}

      {isDev && (
        <Card>
          <SectionTitle title="Backup &amp; restore" caption="Every publish also pushes an encrypted full-panel snapshot to the repo (sensei_backup.enc). Download a JSON backup here, or restore from it / from the repo copy." />
          <div className="flex flex-wrap gap-2">
            <Button busy={restoreBusy === 'dl'} onClick={() => void downloadBackup()}>
              Download backup (JSON)
            </Button>
            <Button onClick={() => setRestoreOpen(true)}>Restore from JSON…</Button>
            <Button variant="danger" busy={restoreBusy === 'gh'} onClick={() => void restoreFromGithub()}>
              Restore from GitHub backup
            </Button>
          </div>
          <p className="mt-2 text-[11px] text-hint">
            Restoring overwrites configs, servers, categories, settings, branding and admin
            accounts, then republishes. If KV is ever wiped, “Restore from GitHub backup” is
            the recovery path.
          </p>
        </Card>
      )}

      {isDev && (
        <Card className="border-warn/40">
          <SectionTitle title="Danger zone" caption="Wipes every node and republishes an EMPTY bundle. The app loses all official tunnels." />
          <Button variant="danger" onClick={() => setDangerOpen(true)}>Delete all nodes…</Button>
        </Card>
      )}

      <Modal open={restoreOpen} onClose={() => setRestoreOpen(false)} title="Restore from JSON backup">
        <Notice kind="warn">
          Paste the contents of a downloaded backup file. This overwrites the current panel state
          and republishes.
        </Notice>
        <textarea
          rows={8}
          value={restoreText}
          onChange={(e) => setRestoreText(e.target.value)}
          placeholder='{"kind":"sensei-panel-backup",…}'
          spellCheck={false}
          className="mt-3 w-full resize-y rounded-xl border border-line bg-bg px-3 py-2 font-mono text-xs text-ink outline-none placeholder:text-hint focus:border-accent"
        />
        <div className="mt-3 flex justify-end gap-2">
          <Button onClick={() => setRestoreOpen(false)}>Cancel</Button>
          <Button variant="danger" disabled={!restoreText.trim()} busy={restoreBusy === 'json'} onClick={() => void restoreFromText()}>
            Restore &amp; republish
          </Button>
        </div>
      </Modal>

      <Modal open={dangerOpen} onClose={() => setDangerOpen(false)} title="Delete ALL nodes?">
        <Notice kind="warn">
          This cannot be undone. Type <b>DELETE</b> to confirm.
        </Notice>
        <div className="mt-3">
          <Field label="Confirmation" value={confirmText} onChange={setConfirmText} />
        </div>
        <div className="mt-3 flex justify-end gap-2">
          <Button onClick={() => setDangerOpen(false)}>Cancel</Button>
          <Button variant="danger" disabled={confirmText !== 'DELETE'} busy={busy === 'wipe'} onClick={deleteAllConfigs}>
            Wipe &amp; republish
          </Button>
        </div>
      </Modal>
    </div>
  );
}

function Fact(props: { label: string; value: string; mono?: boolean; link?: boolean; right?: React.ReactNode }) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 border-b border-line pb-2 last:border-0 last:pb-0">
      <dt className="text-[11px] font-semibold uppercase tracking-wider text-hint">{props.label}</dt>
      <dd className="flex min-w-0 items-center gap-2">
        {props.mono ? (
          <code className="block max-w-full truncate font-mono text-xs text-muted" title={props.value}>
            {props.value}
          </code>
        ) : (
          <span className="text-[13px] text-ink">{props.value}</span>
        )}
        {props.link && (
          <a href={props.value} target="_blank" rel="noreferrer" className="text-xs font-bold text-accent hover:underline">
            open ↗
          </a>
        )}
        {props.right}
      </dd>
    </div>
  );
}
