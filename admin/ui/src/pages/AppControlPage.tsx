/**
 * App control — everything that reaches the app through the encrypted
 * settings bundle (sensei_app_settings.enc):
 *   · lock switch + message          → ConfigService.appLocked / lockedMessage
 *   · force update + version payload → forceUpdate dialog in the app
 *   · broadcast notice               → information.json-style payload
 */
import React, { useEffect, useRef, useState } from 'react';
import { api, publishErrorText } from '../api';
import type { AppVersionPayload, Bootstrap, BroadcastPayload, PanelImage, PublishResult } from '../types';
import {
  Button,
  Card,
  Field,
  Grid,
  Notice,
  PageHeader,
  SectionTitle,
  Switch,
  TextArea,
} from '../components/ui';

export function AppControlPage(props: {
  data: Bootstrap;
  refresh: () => Promise<void>;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  const s = props.data.settings;
  const info = props.data.backend.info || {};

  // Local form state, seeded from the server snapshot.
  const [lockMsg, setLockMsg] = useState(s.lockedMessage);
  const [forceUpdate, setForceUpdate] = useState(s.forceUpdate);
  const [latestVersion, setLatestVersion] = useState(s.latestVersion);
  const [updateUrl, setUpdateUrl] = useState(s.updateUrl);
  const [updateMessage, setUpdateMessage] = useState(s.updateMessage);
  const [versionCode, setVersionCode] = useState(String(s.vers?.versionCode ?? ''));
  const [minCode, setMinCode] = useState(String(s.vers?.minRequiredVersionCode ?? ''));
  // payload token library: one textarea, `NAME=template` per line (use [crlf]/[ua] intrinsics).
  const [payloadDefsText, setPayloadDefsText] = useState<string>(formatPayloadDefs(s.payloadDefs || {}));

  const [showDialog, setShowDialog] = useState(info.showDialog === true);
  const [dialogTitle, setDialogTitle] = useState(info.dialogTitle || '');
  const [dialogMessage, setDialogMessage] = useState(info.dialogMessage || '');
  const [actionText, setActionText] = useState(info.actionButtonText || '');
  const [actionUrl, setActionUrl] = useState(info.actionButtonUrl || '');
  const [marqueeOn, setMarqueeOn] = useState(info.showMarquee === true);
  const [marqueeText, setMarqueeText] = useState(info.marqueeNotice || '');
  const [maintenance, setMaintenance] = useState(info.maintenanceMode === true);
  const [maintenanceText, setMaintenanceText] = useState(info.maintenanceMessage || '');

  // Provider branding (shown inside the app's About / Settings / Support).
  const [brandName, setBrandName] = useState(props.data.backend.name || '');
  const [brandContact, setBrandContact] = useState(props.data.backend.contact || '');
  const [brandWhatsapp, setBrandWhatsapp] = useState(props.data.backend.whatsapp || '');
  const [brandDesc, setBrandDesc] = useState(props.data.backend.description || '');
  // Admin wallpaper gallery — titled entries; the app's Wallpaper sheet
  // shows each title (untitled ones auto-number to Wallpaper N).
  const [wallpapers, setWallpapers] = useState<{ url: string; title: string }[]>(
    (props.data.backend.wallpapers || []).map((w) =>
      typeof w === 'string' ? { url: w, title: '' } : w,
    ),
  );

  const [busy, setBusy] = useState<'settings' | 'broadcast' | 'brand' | null>(null);

  async function saveSettings(appLocked: boolean) {
    setBusy('settings');
    try {
      const vers: AppVersionPayload | null =
        latestVersion || versionCode || updateUrl
          ? {
              ...(s.vers || {}),
              versionName: latestVersion,
              versionCode: parseInt(versionCode, 10) || undefined,
              minRequiredVersionCode: parseInt(minCode, 10) || undefined,
              forceUpdate,
              apkDownloadUrl: updateUrl,
            }
          : s.vers;
      const res = await api.saveSettings({
        appLocked,
        lockedMessage: lockMsg,
        forceUpdate,
        latestVersion,
        updateUrl,
        updateMessage,
        vers,
        payloadDefs: parsePayloadDefs(payloadDefsText),
      });
      reportPublish(res.publish);
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Save failed', 'error');
    } finally {
      setBusy(null);
    }
  }

  async function saveBroadcast() {
    setBusy('broadcast');
    try {
      const payload: BroadcastPayload = {
        showDialog,
        dialogTitle,
        dialogMessage,
        actionButtonText: actionText,
        actionButtonUrl: actionUrl,
        showMarquee: marqueeOn,
        marqueeNotice: marqueeText,
        maintenanceMode: maintenance,
        maintenanceMessage: maintenanceText,
      };
      const res = await api.saveBranding({
        name: brandName || props.data.backend.name,
        contact: brandContact,
        whatsapp: brandWhatsapp,
        description: brandDesc,
        wallpapers,
        info: payload,
      });
      reportPublish(res.publish);
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Save failed', 'error');
    } finally {
      setBusy(null);
    }
  }

  async function saveBrandingOnly() {
    setBusy('brand');
    try {
      const res = await api.saveBranding({
        name: brandName || props.data.backend.name,
        contact: brandContact,
        whatsapp: brandWhatsapp,
        description: brandDesc,
        wallpapers,
        info: props.data.backend.info,
      });
      reportPublish(res.publish);
      await props.refresh();
    } catch (e: any) {
      props.notify(e?.message || 'Save failed', 'error');
    } finally {
      setBusy(null);
    }
  }

  function reportPublish(pub: PublishResult) {
    if (pub.ok) props.notify('Saved & published to GitHub', 'success');
    else
      props.notify(
        'Saved to KV but GitHub push FAILED: ' + (publishErrorText(pub) || 'unknown error'),
        'error',
      );
  }

  return (
    <div className="space-y-4">
      <PageHeader
        title="Controls"
        caption="These controls ship inside the encrypted settings bundle the app downloads with its configs."
      />

      {/* Lock */}
      <Card>
        <SectionTitle title="Remote lock" caption={props.data.settings.appLocked ? 'The app is currently LOCKED for all users.' : 'Users can connect freely.'} />
        <div className="space-y-3">
          <Switch
            danger
            label="Lock the app"
            checked={props.data.settings.appLocked}
            onChange={(v) => void saveSettings(v)}
          />
          <Field label="Lock message" value={lockMsg} onChange={setLockMsg} placeholder="Maintenance until 9 PM" />
          <Button variant="primary" busy={busy === 'settings'} onClick={() => saveSettings(props.data.settings.appLocked)}>
            Save lock message
          </Button>
        </div>
      </Card>

      {/* Force update */}
      <Card>
        <SectionTitle title="Force update" caption="Older app versions show a blocking update dialog when this is on." />
        <div className="space-y-3">
          <Switch label="Require update" checked={forceUpdate} onChange={setForceUpdate} />
          <Grid cols={2}>
            <Field label="Latest version name" value={latestVersion} onChange={setLatestVersion} placeholder="1.0.27" />
            <Field label="Latest version code" value={versionCode} onChange={(v) => setVersionCode(v.replace(/\D/g, ''))} placeholder="33" hint="Numeric build number" />
            <Field label="Minimum allowed code" value={minCode} onChange={(v) => setMinCode(v.replace(/\D/g, ''))} placeholder="32" />
            <Field label="APK download URL" value={updateUrl} onChange={setUpdateUrl} type="url" placeholder="https://github.com/…/apk-release.apk" />
          </Grid>
          <Field label="Update message shown to users" value={updateMessage} onChange={setUpdateMessage} />
          <Button variant="primary" busy={busy === 'settings'} onClick={() => saveSettings(props.data.settings.appLocked)}>
            Save &amp; publish
          </Button>
        </div>
      </Card>

      {/* Payload token library */}
      <Card>
        <SectionTitle
          title="Payload token library"
          caption="Named payload tokens you can reference as [NAME] in any config's payload/inject-payload. Intrinsics [crlf], [ua], [host] are always available. Format: NAME=template per line."
        />
        <textarea
          value={payloadDefsText}
          onChange={(e) => setPayloadDefsText(e.target.value)}
          rows={5}
          spellCheck={false}
          placeholder={'RYZE=HTTP/1.1[crlf]Host: telegram.org[crlf]User-Agent: [ua][crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf]Sec-WebSocket-Version: 13[crlf][crlf]\nROBI=HTTP/1.1[crlf]Host: viber.com[crlf][crlf]'}
          className="w-full resize-y rounded-xl border border-line bg-bg px-3 py-2.5 font-mono text-xs outline-none placeholder:text-hint focus:border-accent"
        />
        <p className="mt-1 text-[11px] text-hint">
          A config with <code className="rounded bg-surface2 px-1">payload=[RYZE]</code> will ship to the app as the full RYZE template. Saves re-publish both bundles.
        </p>
        <div className="mt-3">
          <Button variant="primary" busy={busy === 'settings'} onClick={() => saveSettings(props.data.settings.appLocked)}>
            Save tokens &amp; publish
          </Button>
        </div>
      </Card>

      {/* Branding — rides inside the settings bundle to the app */}
      <Card>
        <SectionTitle
          title="Provider branding"
          caption="Shown inside the app: About screen header, Settings and Support contact links."
        />
        <div className="space-y-3">
          <Field label="Provider name" value={brandName} onChange={setBrandName} placeholder="Arman Tunnel" />
          <Grid cols={2}>
            <Field label="Contact link" value={brandContact} onChange={setBrandContact} type="url" placeholder="https://t.me/…" />
            <Field label="WhatsApp" value={brandWhatsapp} onChange={setBrandWhatsapp} placeholder="+8801639111636" />
          </Grid>
          <Field label="Short description" value={brandDesc} onChange={setBrandDesc} placeholder="Encrypted config delivery from GitHub." />
          <WallpaperGallery
            wallpapers={wallpapers}
            onChange={setWallpapers}
            notify={props.notify}
          />
          <Button variant="primary" busy={busy === 'brand'} onClick={saveBrandingOnly}>
            Save &amp; publish branding
          </Button>
        </div>
      </Card>

      {/* Broadcast */}
      <Card>
        <SectionTitle title="Broadcast notice" caption="A one-time dialog and/or scrolling banner inside the app." />
        <div className="space-y-3">
          <Switch label="Show dialog on app start" checked={showDialog} onChange={setShowDialog} />
          {showDialog && (
            <Grid cols={2}>
              <Field label="Title" value={dialogTitle} onChange={setDialogTitle} />
              <Field label="Action button label" value={actionText} onChange={setActionText} placeholder="Join channel" />
              <Field label="Action button URL" value={actionUrl} onChange={setActionUrl} type="url" placeholder="https://t.me/…" />
            </Grid>
          )}
          {showDialog && (
            <TextArea label="Dialog message" rows={3} value={dialogMessage} onChange={setDialogMessage} />
          )}
          <Switch label="Scrolling banner" checked={marqueeOn} onChange={setMarqueeOn} />
          {marqueeOn && (
            <Field label="Banner text" value={marqueeText} onChange={setMarqueeText} placeholder="New servers added this week!" />
          )}
          <Switch danger label="Maintenance mode banner" checked={maintenance} onChange={setMaintenance} />
          {maintenance && (
            <Field label="Maintenance text" value={maintenanceText} onChange={setMaintenanceText} />
          )}
          <Button variant="primary" busy={busy === 'broadcast'} onClick={saveBroadcast}>
            Save &amp; publish
          </Button>
          <Notice kind="info">
            The broadcast rides along inside sensei_app_settings.enc — no extra file, nothing plaintext on GitHub.
          </Notice>
        </div>
      </Card>
    </div>
  );
}

function formatPayloadDefs(defs: Record<string, string>): string {
  return Object.entries(defs)
    .map(([k, v]) => `${k}=${v}`)
    .join('\n');
}

/**
 * Admin wallpaper gallery — the multiple-wallpaper manager. Each entry is an
 * imgbb-hosted URL; the app downloads the whole list and auto-applies a
 * random one on first run (until the user picks their own), and the
 * Wallpaper sheet's "Admin" source offers every entry. Wallpaper Mode is
 * dark-theme-only in the app, so suggest darker images.
 */
function WallpaperGallery(props: {
  wallpapers: { url: string; title: string }[];
  onChange: (list: { url: string; title: string }[]) => void;
  notify: (message: string, kind?: 'success' | 'error' | 'info') => void;
}) {
  const [selected, setSelected] = useState(0);
  const [library, setLibrary] = useState<PanelImage[]>([]);
  const [libraryBusy, setLibraryBusy] = useState(false);
  const [uploadBusy, setUploadBusy] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (props.wallpapers.length === 0) setSelected(0);
    else if (selected >= props.wallpapers.length) {
      setSelected(props.wallpapers.length - 1);
    }
  }, [props.wallpapers.length, selected]);

  const add = (url: string) => {
    const u = url.trim();
    if (!u) return;
    if (props.wallpapers.some((w) => w.url === u)) {
      props.notify('That wallpaper is already in the gallery', 'info');
      return;
    }
    // Untitled entries auto-number by position (the Worker renumbers on
    // save as well, so clearing a title falls back to Wallpaper N).
    props.onChange([...props.wallpapers, { url: u, title: '' }]);
    setSelected(props.wallpapers.length);
  };
  const removeAt = (i: number) => {
    props.onChange(props.wallpapers.filter((_, idx) => idx !== i));
    setSelected(Math.max(0, i - 1));
  };
  const renameAt = (i: number, title: string) =>
    props.onChange(
      props.wallpapers.map((w, idx) => (idx === i ? { ...w, title } : w)),
    );
  const setUrlAt = (i: number, url: string) =>
    props.onChange(
      props.wallpapers.map((w, idx) => (idx === i ? { ...w, url } : w)),
    );

  async function loadLibrary() {
    setLibraryBusy(true);
    try {
      const res = await api.images();
      setLibrary(res.images);
      if (res.images.length === 0) props.notify('Image library is empty', 'info');
    } catch (e: any) {
      props.notify(e?.message || 'Could not load the library', 'error');
    } finally {
      setLibraryBusy(false);
    }
  }

  async function uploadFile(file: File) {
    if (!file.type.startsWith('image/')) {
      props.notify('Only image files can be uploaded', 'error');
      return;
    }
    if (file.size > 5 * 1024 * 1024) {
      props.notify('Image too large (max 5 MB)', 'error');
      return;
    }
    setUploadBusy(true);
    try {
      const dataBase64 = await new Promise<string>((resolve, reject) => {
        const r = new FileReader();
        r.onload = () => resolve(String(r.result || ''));
        r.onerror = () => reject(new Error('Could not read the file'));
        r.readAsDataURL(file);
      });
      const res = await api.uploadImage(dataBase64, file.name, file.type);
      add(res.url);
      props.notify('Wallpaper uploaded', 'success');
    } catch (e: any) {
      props.notify(e?.message || 'Upload failed', 'error');
    } finally {
      setUploadBusy(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  }

  const autoTitle = (i: number) => `Wallpaper ${i + 1}`;
  const current = props.wallpapers[selected];

  return (
    <div className="rounded-2xl border border-line bg-bg p-3">
      <div className="mb-2 flex items-center justify-between gap-3">
        <p className="text-[11px] font-semibold uppercase tracking-wider text-hint">
          Admin wallpapers ({props.wallpapers.length})
        </p>
        <button
          type="button"
          onClick={() => fileRef.current?.click()}
          disabled={uploadBusy}
          className="rounded-lg border border-accent/50 bg-accent/10 px-3 py-1.5 text-[11px] font-bold text-accent hover:bg-accent/20 disabled:opacity-50"
        >
          {uploadBusy ? 'Uploading...' : 'Upload'}
        </button>
      </div>

      <div className="grid gap-3 lg:grid-cols-[220px_minmax(0,1fr)]">
        <div className="mx-auto w-full max-w-[220px]">
          <div className="relative aspect-[9/16] overflow-hidden rounded-[28px] border border-line bg-surface2 shadow-card">
            {current?.url ? (
              <img src={current.url} alt={current.title || autoTitle(selected)} className="h-full w-full object-cover" />
            ) : (
              <div className="flex h-full items-center justify-center px-5 text-center text-xs text-hint">
                Upload or pick a wallpaper to preview the app background.
              </div>
            )}
            <div className="absolute inset-x-3 top-3 rounded-2xl border border-white/15 bg-black/45 px-3 py-2 text-white backdrop-blur">
              <div className="text-[10px] uppercase tracking-wider text-white/70">Wallpaper Mode</div>
              <div className="truncate text-sm font-bold">{current?.title || autoTitle(selected)}</div>
            </div>
            <div className="absolute inset-x-4 bottom-4 grid grid-cols-2 gap-2">
              <div className="rounded-2xl border border-white/10 bg-black/40 p-3 backdrop-blur">
                <div className="h-2 w-10 rounded-full bg-accent" />
                <div className="mt-2 h-1.5 rounded-full bg-white/35" />
                <div className="mt-1 h-1.5 w-2/3 rounded-full bg-white/25" />
              </div>
              <div className="rounded-2xl border border-white/10 bg-black/40 p-3 backdrop-blur">
                <div className="h-2 w-8 rounded-full bg-lime" />
                <div className="mt-2 h-1.5 rounded-full bg-white/35" />
                <div className="mt-1 h-1.5 w-1/2 rounded-full bg-white/25" />
              </div>
            </div>
          </div>
        </div>

        <div className="min-w-0 space-y-3">
          {props.wallpapers.length > 0 ? (
            <label className="block">
              <span className="mb-1.5 block text-[11px] font-semibold uppercase tracking-wider text-muted">
                Pick wallpaper
              </span>
              <select
                value={selected}
                onChange={(e) => setSelected(Number(e.target.value))}
                className="w-full rounded-xl border border-line bg-bg px-3 py-2.5 text-sm outline-none focus:border-accent"
              >
                {props.wallpapers.map((w, i) => (
                  <option key={`${w.url}-${i}`} value={i} className="bg-surface text-ink">
                    {w.title || autoTitle(i)}
                  </option>
                ))}
              </select>
            </label>
          ) : (
            <p className="rounded-xl border border-dashed border-line p-3 text-sm text-hint">
              No wallpapers yet. Upload one or load the image library.
            </p>
          )}

          {current && (
            <>
              <Field
                label="Title shown in the app"
                value={current.title}
                onChange={(v) => renameAt(selected, v)}
                placeholder={autoTitle(selected)}
              />
              <Field
                label="Wallpaper URL"
                value={current.url}
                onChange={(v) => setUrlAt(selected, v)}
                placeholder="https://i.ibb.co/..."
              />
              <button
                type="button"
                onClick={() => removeAt(selected)}
                className="rounded-lg border border-warn/60 px-3 py-1.5 text-[11px] font-bold text-warn hover:bg-warn/10"
              >
                Remove selected
              </button>
            </>
          )}

          <div className="rounded-xl border border-line bg-surface2 p-3">
            <div className="mb-2 flex items-center justify-between gap-2">
              <p className="text-[11px] font-semibold uppercase tracking-wider text-hint">
                Image library dropdown
              </p>
              <button
                type="button"
                onClick={() => void loadLibrary()}
                disabled={libraryBusy}
                className="rounded-lg border border-line px-2.5 py-1 text-[11px] font-bold text-muted hover:border-accent hover:text-accent disabled:opacity-50"
              >
                {libraryBusy ? 'Loading...' : 'Load library'}
              </button>
            </div>
            <select
              value=""
              onChange={(e) => add(e.target.value)}
              className="w-full rounded-xl border border-line bg-bg px-3 py-2.5 text-sm outline-none focus:border-accent"
            >
              <option value="" className="bg-surface text-ink">
                {library.length ? 'Pick an uploaded image...' : 'Load library first'}
              </option>
              {library.map((img) => (
                <option key={img.url} value={img.url} className="bg-surface text-ink">
                  {img.filename || img.url}
                </option>
              ))}
            </select>
          </div>
        </div>
      </div>

      <input
        ref={fileRef}
        type="file"
        accept="image/*"
        className="hidden"
        onChange={(e) => {
          const f = e.target.files && e.target.files[0];
          if (f) void uploadFile(f);
        }}
      />
    </div>
  );
}

function parsePayloadDefs(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of String(text || '').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const eq = t.indexOf('=');
    if (eq <= 0) continue;
    const key = t.slice(0, eq).trim().toUpperCase();
    const val = t.slice(eq + 1).trim();
    if (key && val) out[key] = val;
  }
  return out;
}
