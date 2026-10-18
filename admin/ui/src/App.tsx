/**
 * Arman Tunnel admin — application shell.
 *
 * Feels like the mobile app it manages: a fixed bottom tab bar on phones, a
 * sidebar on desktop, violet/lavender surfaces everywhere. One data snapshot
 * (GET /api/bootstrap) drives every page; mutations re-fetch it so publish
 * state is always real.
 *
 * Five tabs: Servers (raw endpoints), Tweaks (tunneling methods grouped by
 * category — what the app's Configs menu shows), Controls, Logs, Settings.
 * The editors live inside their pages, not in a separate tab.
 */
import React, { useCallback, useEffect, useState } from 'react';
import {
  Globe,
  KeyRound,
  ListChecks,
  LogIn,
  LogOut,
  Server as ServerIcon,
  Shapes,
  Settings as SettingsIcon,
  ShieldCheck,
  SlidersHorizontal,
} from 'lucide-react';
import { api, ApiError, setCsrf } from './api';
import type { Bootstrap } from './types';
import { Button } from './components/ui';
import { ToastHost, ToastItem } from './components/Toast';
import { PublishStrip } from './components/PublishStrip';
import { ProxiesPage } from './pages/ProxiesPage';
import { ServersPage } from './pages/ServersPage';
import { TypesPage } from './pages/TypesPage';
import { TweaksPage } from './pages/TweaksPage';
import { AppControlPage } from './pages/AppControlPage';
import { DevicesPage } from './pages/DevicesPage';
import { LogsPage } from './pages/LogsPage';
import { SettingsPage } from './pages/SettingsPage';

export type Tab = 'proxies' | 'servers' | 'types' | 'tweaks' | 'control' | 'devices' | 'logs' | 'settings';

const TABS: Array<{ id: Tab; label: string; icon: React.ComponentType<{ className?: string }> }> = [
  // Proxies first: a proxy is what actually reaches users, and it needs no
  // tweak. Servers/Tweaks are the machinery behind the tuned variants.
  { id: 'proxies', label: 'Proxies', icon: Globe },
  { id: 'servers', label: 'Servers', icon: ServerIcon },
  { id: 'types', label: 'Types', icon: Shapes },
  { id: 'tweaks', label: 'Tweaks', icon: SlidersHorizontal },
  { id: 'control', label: 'Controls', icon: ShieldCheck },
  { id: 'devices', label: 'Devices', icon: KeyRound },
  { id: 'logs', label: 'Logs', icon: ListChecks },
  { id: 'settings', label: 'Settings', icon: SettingsIcon },
];

export default function App() {
  const [authed, setAuthed] = useState<boolean | null>(null); // null = booting
  const [data, setData] = useState<Bootstrap | null>(null);
  const [tab, setTab] = useState<Tab>('tweaks');
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  // login form
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [loginError, setLoginError] = useState('');
  const [loginBusy, setLoginBusy] = useState(false);

  const notify = useCallback((message: string, kind: 'success' | 'error' | 'info' = 'success') => {
    const id = Date.now() + Math.random();
    setToasts((prev) => [...prev.slice(-3), { id, message, kind }]);
    setTimeout(() => setToasts((prev) => prev.filter((t) => t.id !== id)), 4000);
  }, []);

  const refresh = useCallback(async () => {
    const snap = await api.bootstrap();
    setData(snap);
    if (snap.csrf) setCsrf(snap.csrf);
  }, []);

  // Boot: check the session cookie.
  useEffect(() => {
    (async () => {
      try {
        const s = await api.session();
        if (s.authenticated && s.csrf) {
          setCsrf(s.csrf);
          await refresh();
          setAuthed(true);
        } else {
          setAuthed(false);
        }
      } catch {
        setAuthed(false);
      }
    })();
  }, [refresh]);

  // A 401 anywhere means the cookie expired — drop to login.
  useEffect(() => {
    const handler = (e: PromiseRejectionEvent) => {
      if (e.reason instanceof ApiError && e.reason.status === 401) {
        setAuthed(false);
        notify('Session expired — sign in again', 'info');
      }
    };
    window.addEventListener('unhandledrejection', handler);
    return () => window.removeEventListener('unhandledrejection', handler);
  }, [notify]);

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault();
    if (!username.trim() || !password) return;
    setLoginBusy(true);
    setLoginError('');
    try {
      await api.login(username.trim(), password);
      await refresh();
      setAuthed(true);
      setPassword('');
      notify(`Welcome back, ${username.trim()}`, 'success');
    } catch (err: any) {
      setLoginError(err?.message || 'Login failed');
    } finally {
      setLoginBusy(false);
    }
  }

  async function handleLogout() {
    try {
      await api.logout();
    } finally {
      setAuthed(false);
      setData(null);
      setTab('tweaks');
    }
  }

  // ------------------------------------------------------------------ login
  if (authed === false) {
    return (
      <div className="flex min-h-dvh items-center justify-center p-4">
        <form onSubmit={handleLogin} className="anim-pop w-full max-w-sm space-y-4 rounded-3xl border border-line bg-surface p-6 shadow-2xl">
          <div className="flex flex-col items-center gap-2 text-center">
            <div className="grid h-14 w-14 place-items-center rounded-2xl border border-accent/40 bg-accent/10">
              <KeyRound className="h-6 w-6 text-accent" />
            </div>
            <h1 className="text-base font-black tracking-tight">Arman Tunnel Admin</h1>
            <p className="text-[11px] leading-relaxed text-hint">
              Encrypted config delivery · GitHub sync · app control
            </p>
          </div>
          <label className="block">
            <span className="mb-1.5 block text-[11px] font-semibold uppercase tracking-wider text-muted">Username</span>
            <input
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              autoComplete="username"
              autoFocus
              className="w-full rounded-xl border border-line bg-bg px-3 py-2.5 text-[13px] outline-none focus:border-accent"
            />
          </label>
          <label className="block">
            <span className="mb-1.5 block text-[11px] font-semibold uppercase tracking-wider text-muted">Password</span>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="current-password"
              className="w-full rounded-xl border border-line bg-bg px-3 py-2.5 text-[13px] outline-none focus:border-accent"
            />
          </label>
          {loginError && (
            <p className="rounded-lg border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-warn">{loginError}</p>
          )}
          <Button type="submit" variant="primary" full busy={loginBusy}>
            <LogIn className="h-4 w-4" /> Sign in
          </Button>
          <p className="text-center text-[10px] text-hint">
            Sessions use an httpOnly cookie — nothing is stored in the browser's JS storage.
          </p>
        </form>
        <ToastHost toasts={toasts} onDismiss={(id) => setToasts((p) => p.filter((t) => t.id !== id))} />
      </div>
    );
  }

  if (authed !== true || !data) {
    return (
      <div className="grid min-h-dvh place-items-center">
        <span className="h-6 w-6 animate-spin rounded-full border-2 border-accent border-t-transparent" />
      </div>
    );
  }

  // ------------------------------------------------------------------- main
  const activeTab = TABS.find((t) => t.id === tab)!;
  return (
    <div className="min-h-dvh lg:flex">
      {/* Desktop sidebar */}
      <aside className="sticky top-0 hidden h-dvh w-60 shrink-0 flex-col border-r border-line bg-surface/70 p-4 backdrop-blur lg:flex">
        <BrandBlock me={data.me} role={data.role} />
        <nav className="mt-4 flex-1 space-y-1">
          {TABS.map((t) => (
            <NavItem key={t.id} tab={t} active={tab === t.id} onSelect={setTab} layout="side" />
          ))}
        </nav>
        <button onClick={handleLogout} className="flex items-center gap-2 rounded-xl px-3 py-2.5 text-xs font-bold text-muted transition hover:bg-surface2 hover:text-warn">
          <LogOut className="h-4 w-4" /> Sign out
        </button>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        {/* Top bar */}
        <header className="sticky top-0 z-30 flex items-center gap-3 border-b border-line bg-bg/90 px-4 py-3 backdrop-blur">
          <div className="lg:hidden"><BrandMark /></div>
          <div className="min-w-0">
            <h1 className="truncate text-sm font-black tracking-tight">{activeTab.label}</h1>
            <p className="truncate text-[10px] text-hint">
              {data.stats.active}/{data.stats.total} tweaks live · envelope {data.crypto.version}
              {data.crypto.certBound ? ' (cert-bound)' : ''}
            </p>
          </div>
          <div className="ms-auto hidden sm:block">
            <PublishStrip lastPublish={data.lastPublish} githubConfigured={data.github.configured} onChanged={() => void refresh()} notify={notify} />
          </div>
          <button onClick={handleLogout} className="ms-auto rounded-xl p-2 text-muted transition hover:text-warn lg:hidden" aria-label="Sign out">
            <LogOut className="h-4 w-4" />
          </button>
        </header>
        <div className="px-4 pt-3 sm:hidden">
          <PublishStrip lastPublish={data.lastPublish} githubConfigured={data.github.configured} onChanged={() => void refresh()} notify={notify} />
        </div>

        <main className="mx-auto w-full max-w-5xl flex-1 px-4 pb-28 pt-4 lg:pb-8">
          {tab === 'proxies' && (
            <ProxiesPage
              data={data}
              refresh={refresh}
              notify={notify}
            />
          )}
          {tab === 'servers' && (
            <ServersPage
              data={data}
              refresh={refresh}
              notify={notify}
              onGoProxies={() => setTab('proxies')}
            />
          )}
          {tab === 'types' && (
            <TypesPage
              types={data.types}
              servers={data.servers}
              refresh={refresh}
              notify={notify}
            />
          )}
          {tab === 'tweaks' && (
            <TweaksPage
              data={data}
              refresh={refresh}
              notify={notify}
              onGoServers={() => setTab('servers')}
            />
          )}
          {tab === 'control' && <AppControlPage data={data} refresh={refresh} notify={notify} />}
          {tab === 'devices' && <DevicesPage notify={notify} />}
          {tab === 'logs' && <LogsPage logs={data.logs} refresh={refresh} notify={notify} />}
          {tab === 'settings' && <SettingsPage data={data} refresh={refresh} notify={notify} />}
        </main>
      </div>

      {/* Mobile bottom nav */}
      <nav className="fixed inset-x-0 bottom-0 z-40 isolate flex border-t border-line bg-surface pb-[env(safe-area-inset-bottom)] lg:hidden">
        {TABS.map((t) => (
          <NavItem key={t.id} tab={t} active={tab === t.id} onSelect={setTab} layout="bottom" />
        ))}
      </nav>

      <ToastHost toasts={toasts} onDismiss={(id) => setToasts((p) => p.filter((t) => t.id !== id))} />
    </div>
  );
}

function BrandMark() {
  return (
    <div className="grid h-9 w-9 place-items-center rounded-xl bg-gradient-to-br from-lime via-accent to-transparent shadow-inner">
      <ShieldCheck className="h-5 w-5 text-black" />
    </div>
  );
}

function BrandBlock(props: { me: string; role: 'dev' | 'admin' }) {
  return (
    <div className="flex items-center gap-2.5">
      <BrandMark />
      <div className="min-w-0">
        <p className="text-sm font-black leading-tight">Arman Admin</p>
        <p className="truncate text-[10px] text-hint">
          {props.me}
          {props.role === 'dev' ? ' · Dev' : ' · Admin'}
        </p>
      </div>
    </div>
  );
}

function NavItem(props: {
  tab: { id: Tab; label: string; icon: React.ComponentType<{ className?: string }> };
  active: boolean;
  onSelect: (t: Tab) => void;
  layout: 'side' | 'bottom';
}) {
  const Icon = props.tab.icon;
  if (props.layout === 'side') {
    return (
      <button
        onClick={() => props.onSelect(props.tab.id)}
        className={`flex w-full items-center gap-2.5 rounded-xl px-3 py-2.5 text-[13px] font-bold transition ${
          props.active ? 'bg-accent/15 text-accent' : 'text-muted hover:bg-surface2 hover:text-ink'
        }`}
      >
        <Icon className="h-4 w-4" /> {props.tab.label}
      </button>
    );
  }
  return (
    <button
      onClick={() => props.onSelect(props.tab.id)}
      className={`flex flex-1 flex-col items-center gap-0.5 py-2.5 text-[10px] font-bold transition ${
        props.active ? 'text-accent' : 'text-hint'
      }`}
    >
      <Icon className={`h-5 w-5 ${props.active ? '' : 'opacity-70'}`} />
      {props.tab.label}
    </button>
  );
}
