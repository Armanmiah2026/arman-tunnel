/**
 * Publish strip — the single, honest surface for "did my change reach GitHub?".
 * Shows the last publish result per file and offers Publish (force) and
 * Verify (download + decrypt through the public CDN).
 */
import React, { useState } from 'react';
import { api, publishErrorText } from '../api';
import type { LastPublish, VerifyResult } from '../types';
import { Badge, Button } from './ui';

export function PublishStrip(props: {
  lastPublish: LastPublish | null;
  githubConfigured: boolean;
  onChanged: () => void;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  const [busy, setBusy] = useState<'publish' | 'verify' | null>(null);

  async function doPublish() {
    setBusy('publish');
    try {
      const res = await api.publish();
      if (res.publish.ok) {
        props.notify(`Published ${res.publish.nodes} node(s) to GitHub`, 'success');
      } else {
        props.notify('GitHub push FAILED — ' + (publishErrorText(res.publish) || 'see details below'), 'error');
      }
      props.onChanged();
    } catch (e: any) {
      props.notify(e?.message || 'Publish failed', 'error');
    } finally {
      setBusy(null);
    }
  }

  async function doVerify() {
    setBusy('verify');
    try {
      const res: VerifyResult = await api.verify();
      if (res.ok) {
        const n = res.configFile?.nodes ?? '?';
        props.notify(`Verified: all 3 files download, decrypt and match KV (${n} nodes)`, 'success');
      } else {
        const why =
          res.configFile && !res.configFile.fetched
            ? res.configFile.error
            : res.configFile && !res.configFile.decrypted
              ? res.configFile.error
              : res.configFile?.matchesKv === false
                ? 'published file differs from current data — publish again'
                : res.settingsFile && !res.settingsFile.decrypted
                  ? res.settingsFile.error
                  : res.backupFile && !res.backupFile.decrypted
                    ? res.backupFile.error
                    : 'unknown';
        props.notify('Verify FAILED: ' + why, 'error');
      }
    } catch (e: any) {
      props.notify(e?.message || 'Verify failed', 'error');
    } finally {
      setBusy(null);
    }
  }

  if (!props.githubConfigured) {
    return (
      <div className="rounded-xl border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-warn">
        GitHub is not configured on the Worker (GITHUB_TOKEN / GITHUB_REPO secrets) — changes are saved to KV but never reach the app.
      </div>
    );
  }

  const lp = props.lastPublish;
  return (
    <div className="flex flex-wrap items-center gap-2 rounded-xl border border-line bg-surface px-3 py-2">
      <span className="text-[11px] font-semibold uppercase tracking-wider text-hint">GitHub</span>
      {lp ? (
        <Badge tone={lp.ok ? 'accent' : 'warn'}>
          {lp.ok ? `Published ${lp.nodes ?? ''} · ${new Date(lp.time).toLocaleString()}` : 'Last publish failed'}
        </Badge>
      ) : (
        <Badge tone="warn">Never published</Badge>
      )}
      <div className="ms-auto flex gap-2">
        <Button small busy={busy === 'verify'} onClick={doVerify}>Verify</Button>
        <Button small variant="lime" busy={busy === 'publish'} onClick={doPublish}>Publish now</Button>
      </div>
    </div>
  );
}
