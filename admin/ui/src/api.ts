/**
 * Real API client for the Arman admin Worker.
 *
 * Sessions live in an httpOnly cookie (set by /api/login); this client only
 * needs to echo the CSRF token back in the X-CSRF-Token header on every
 * mutation. No credential is ever stored in JS-accessible storage.
 */

import type {
  ActivityLog,
  AdminAccount,
  AppSettings,
  BackendMeta,
  BackupSnapshot,
  Bootstrap,
  CapabilityType,
  CategoryEntity,
  DryRun,
  LicenseKey,
  PanelImage,
  PublishResult,
  RestoreResult,
  ServerConfig,
  ServerEntity,
  TrialDevice,
  VerifyResult,
} from './types';

let csrfToken = '';

export function setCsrf(token: string) {
  csrfToken = token;
}

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const mutating = method !== 'GET' && method !== 'HEAD';
  if (mutating && csrfToken) headers['X-CSRF-Token'] = csrfToken;

  const res = await fetch(path, {
    method,
    headers,
    credentials: 'same-origin',
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  let data: any = null;
  try {
    data = await res.json();
  } catch {
    /* empty body */
  }

  if (!res.ok || (data && data.ok === false)) {
    const message =
      (data && (data.error || data.message)) || `Request failed (HTTP ${res.status})`;
    throw new ApiError(message, res.status);
  }
  return data as T;
}

const get = <T,>(path: string) => request<T>('GET', path);
const post = <T,>(path: string, body?: unknown) => request<T>('POST', path, body);
const put = <T,>(path: string, body?: unknown) => request<T>('PUT', path, body);
const patch = <T,>(path: string, body?: unknown) => request<T>('PATCH', path, body);
const del = <T,>(path: string, body?: unknown) => request<T>('DELETE', path, body);

// ---------------------------------------------------------------------------
// API surface — mirrors the Worker routes 1:1
// ---------------------------------------------------------------------------

export interface SessionInfo {
  authenticated: boolean;
  username?: string;
  role?: 'dev' | 'admin';
  csrf?: string;
  exp?: number;
}

export const api = {
  session: () => get<SessionInfo>('/api/session'),

  login: async (username: string, password: string) => {
    const res = await post<{ ok: true; user: string; role: 'dev' | 'admin'; csrf: string }>('/api/login', {
      username,
      password,
    });
    setCsrf(res.csrf);
    return res;
  },

  logout: async () => {
    try {
      await post('/api/logout');
    } finally {
      setCsrf('');
    }
  },

  bootstrap: () => get<Bootstrap>('/api/bootstrap'),

  // Configs
  createConfig: (config: Partial<ServerConfig>) =>
    post<{ ok: true; config: ServerConfig; publish: PublishResult }>('/api/configs', config),

  updateConfig: (id: string, config: Partial<ServerConfig>) =>
    put<{ ok: true; config: ServerConfig; publish: PublishResult }>(
      `/api/configs/${encodeURIComponent(id)}`,
      config,
    ),

  patchConfig: (id: string, changes: Partial<ServerConfig>) =>
    patch<{ ok: true; config: ServerConfig; publish: PublishResult }>(
      `/api/configs/${encodeURIComponent(id)}`,
      changes,
    ),

  deleteConfig: (id: string) =>
    del<{ ok: true; publish: PublishResult }>(`/api/configs/${encodeURIComponent(id)}`),

  deleteAllConfigs: () => del<{ ok: true; publish: PublishResult }>('/api/configs'),

  // Servers (endpoint + credentials entity; configs reference them by id)
  createServer: (server: Partial<ServerEntity>) =>
    post<{ ok: true; server: ServerEntity; publish: PublishResult }>('/api/servers', server),

  updateServer: (id: string, server: Partial<ServerEntity>) =>
    put<{ ok: true; server: ServerEntity; publish: PublishResult }>(
      `/api/servers/${encodeURIComponent(id)}`,
      server,
    ),

  deleteServer: (id: string) =>
    del<{ ok: true; publish: PublishResult }>(`/api/servers/${encodeURIComponent(id)}`),

  // Categories (Tweak categories → app Configs menu sections)
  createCategory: (category: { name: string; country?: string }) =>
    post<{ ok: true; category: CategoryEntity; publish: PublishResult }>(
      '/api/categories',
      category,
    ),

  updateCategory: (id: string, category: { name?: string; country?: string }) =>
    put<{ ok: true; category: CategoryEntity; migrated: number; publish: PublishResult }>(
      `/api/categories/${encodeURIComponent(id)}`,
      category,
    ),

  deleteCategory: (id: string) =>
    del<{ ok: true; publish: PublishResult }>(`/api/categories/${encodeURIComponent(id)}`),

  // Capability types (Server ↔ Tweak compatibility markers)
  createType: (t: { name: string; description?: string }) =>
    post<{ ok: true; type: CapabilityType }>('/api/types', t),

  updateType: (id: string, t: { name?: string; description?: string; enabled?: boolean }) =>
    put<{ ok: true; type: CapabilityType; publish: PublishResult | null }>(
      `/api/types/${encodeURIComponent(id)}`,
      t,
    ),

  deleteType: (id: string) =>
    del<{ ok: true; publish: PublishResult }>(`/api/types/${encodeURIComponent(id)}`),

  // Backup (download is admin-open; restore is dev-only)
  downloadBackup: () => get<BackupSnapshot>('/api/backup'),

  restoreBackup: (snapshot: unknown) =>
    post<RestoreResult>('/api/backup', { snapshot }),

  restoreBackupFromGithub: () => post<RestoreResult>('/api/backup/restore-github'),

  bulkUpload: (configs: Array<Partial<ServerConfig>>) =>
    post<{
      ok: true;
      added: number;
      names: string[];
      skipped: string[];
      invalid: Array<{ name: string; errors: string[] }>;
      publish: PublishResult | null;
    }>('/api/bulk-upload', { configs }),

  validate: (config: Partial<ServerConfig>) => post<DryRun>('/api/validate', config),

  importSubscription: (body: {
    url?: string;
    text?: string;
    category?: string;
    country?: string;
    replace?: boolean;
    isOfficial?: boolean;
  }) =>
    post<{
      ok: true;
      added: number;
      names: string[];
      invalid: Array<{ link: string; errors: string[] }>;
      publish: PublishResult;
    }>('/api/import-subscription', body),

  subInfo: (url: string) =>
    post<{ ok: true; info: Record<string, unknown> }>('/api/sub-info', { url }),

  getConfigShareLink: async (id: string) => {
    const res = await get<{ ok: true; config: ServerConfig; shareLink: string }>(
      `/api/configs/${encodeURIComponent(id)}`,
    );
    return res.shareLink;
  },

  // Publish + verify
  publish: () => post<{ ok: boolean; publish: PublishResult }>('/api/publish'),
  verify: () => post<VerifyResult>('/api/verify'),

  exportUrl: '/api/export',

  // Settings (app lock / force update / version payload)
  saveSettings: (settings: Partial<AppSettings>) =>
    post<{ ok: true; settings: AppSettings; publish: PublishResult }>('/api/settings', settings),

  // Branding + broadcast payload
  saveBranding: (backend: Partial<BackendMeta>) =>
    post<{ ok: true; backend: BackendMeta; publish: PublishResult }>('/api/backend', backend),

  // Image DB: upload a file to imgbb, get the hosted URL back
  uploadImage: (dataBase64: string, filename: string, contentType: string) =>
    post<{ ok: true; url: string; deleteUrl: string | null }>('/api/upload-image', {
      dataBase64,
      filename,
      contentType,
    }),

  // Image library: every URL ever uploaded (for re-selecting in forms)
  images: () => get<{ ok: true; images: PanelImage[] }>('/api/images'),
  forgetImage: (url: string) =>
    post<{ ok: true; images: PanelImage[] }>('/api/images/forget', { url }),

  // Logs
  logs: () => get<{ ok: true; logs: ActivityLog[] }>('/api/logs'),
  clearLogs: () => del<{ ok: true }>('/api/logs'),

  // Extra admins
  admins: () =>
    get<{ ok: true; admins: AdminAccount[]; primary: string }>('/api/admins'),
  addAdmin: (username: string, password: string) =>
    post<{ ok: true; username: string }>('/api/admins', { username, password }),
  removeAdmin: (username: string) =>
    del<{ ok: true }>(`/api/admins/${encodeURIComponent(username)}`),
  changePassword: (current: string, next: string) =>
    put<{ ok: true }>('/api/account/password', { current, next }),

  // BDIX device trial system
  getDevices: () =>
    get<{ ok: true; devices: TrialDevice[]; keys: LicenseKey[] }>('/api/devices'),
  extendDevice: (deviceId: string, days: number) =>
    post<{ ok: true; status: Record<string, unknown> }>('/api/devices/extend', { deviceId, days }),
  revokeDevice: (deviceId: string) =>
    post<{ ok: true }>('/api/devices/revoke', { deviceId }),
  updateDevice: (deviceId: string, fields: { note?: string }) =>
    put<{ ok: true; status: Record<string, unknown> }>('/api/devices', { deviceId, ...fields }),
  addDevice: (deviceId: string, fields?: { note?: string; appVersion?: string; platform?: string }) =>
    post<{ ok: true; status: Record<string, unknown> }>('/api/devices/add', { deviceId, ...fields }),
  grantVip: (deviceId: string) =>
    post<{ ok: true; status: Record<string, unknown> }>('/api/devices/vip', { deviceId }),
  revokeVip: (deviceId: string) =>
    post<{ ok: true; status: Record<string, unknown> }>('/api/devices/unvip', { deviceId }),
  lookupDevice: (deviceId: string) =>
    get<{ ok: true; registered: boolean; status: Record<string, unknown> | null }>(
      `/api/devices/lookup?deviceId=${encodeURIComponent(deviceId)}`,
    ),
  deleteDevice: (deviceId: string) =>
    del<{ ok: true }>('/api/devices', { deviceId }),
  createKey: (days: number, deviceId?: string) =>
    post<{ ok: true; key: string; days: number; deviceId: string }>('/api/keys', { days, deviceId }),
};
