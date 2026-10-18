# Arman Tunnel — Admin Panel (Cloudflare Worker + React UI)

Full admin backend for the Arman Tunnel Android app (delivered separately).
One Cloudflare Worker hosts: the JSON API, the React admin UI (static assets),
public privacy/terms pages, the VIP endpoint resolver and the per-device trial
system. The panel publishes two **encrypted** config bundles (`.enc`) into a
private GitHub repo; the app downloads them straight from a static host (CDN /
GitHub Pages) — the app never talks to the Worker for configs.

Layout:

```
src/            Worker (ES modules)
  index.js        routing, auth gate, all /api/* handlers, device/trial/VIP logic
  session.js      httpOnly-cookie sessions + CSRF double-submit
  crypto.js       bundle encryption (v2 shared key / v3 cert-bound) + VIP tickets
  github.js       publish to the configs repo (content sha race-retry)
  config-schema.js  CANONICAL wire format (mirrored by ui/src/types.ts and the
                    app's lib/models/server_config.dart) — run its tests after edits
  legal.js        privacy/terms HTML
ui/             React + Vite admin UI (builds to ui/dist, served at /Arman-tunnel/admin)
tools/v2rayinject.py   server-side reference of the payload-inject protocol
```

## 1. Requirements

- Node 20+ and `npm`.
- A Cloudflare account (free tier works; KV + Workers + static assets).
- A **private GitHub repo** for the two `.enc` files (+ recommended: enable
  GitHub Pages on it or put a CDN in front — that host becomes
  `CONFIG_RAW_BASE`, the URL the app downloads from).
- `npx wrangler` (v4) logged into your Cloudflare (`wrangler login`).

## 2. Quick start

```bash
cd ui && npm install && npm run build && cd ..   # produces ui/dist
node src/config-schema.test.mjs                  # 71 tests
node src/crypto.test.mjs
npx wrangler deploy
```

## 3. Configure `wrangler.toml` — every placeholder marked there MUST be filled

| Field | What to set |
|---|---|
| `account_id` | `npx wrangler whoami` |
| `routes` (commented) | optional custom domain (`custom_domain = true`) |
| `[[kv_namespaces]].id` | `npx wrangler kv namespace create SENSEI_KV`, paste the id |
| `ADMIN_USER` (var) | your login username (`admin` default) |
| `GITHUB_REPO` (var) | `your-org/your-configs-repo` |
| `GITHUB_BRANCH/FILE/SETTINGS_FILE/MANIFEST_FILE` | leave defaults unless you know why |
| `CONFIG_RAW_BASE` (var) | public base URL the app downloads the `.enc` files from — **required**, no default |
| `SITE_REDIRECT` (var) | optional: bare Worker URL 302s here (your site); unset → 404 |
| `APP_CERT_SHA256` (var) | signing-cert SHA-256 of your release APK (app package §4). Empty = v2 encryption; set it (and enable the app gate) for v3 cert-bound bundles. |

Keep `[assets] run_worker_first = true` — it is what keeps the whole panel
hidden behind `/Arman-tunnel/admin` (without it the SPA fallback serves the
panel at the origin root for every URL).

## 4. Secrets (`npx wrangler secret put <NAME>`)

| Secret | Purpose / advice |
|---|---|
| `ADMIN_PASSWORD` | primary admin login password alongside `ADMIN_USER`. Pick a long one; it is checked with `timingSafeEqual`. |
| `JWT_SECRET` | session-token signing. Generate: `node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"` |
| `GITHUB_TOKEN` | GitHub **fine-grained** PAT scoped ONLY to the configs repo, Contents: read+write. |
| `DEV_ACCOUNTS` | optional dev-role logins: `user:pass,user2:pass2`. Devs can delete nodes / manage admins. Omit if you don't need it. |
| `CONFIG_V3_PEPPER` | optional override of the v3 pepper baked into `crypto.js` (rotate = coordinate with the app, republish bundles in the same release). |
| `VIP_SEED` | optional override of the VIP-ticket seed (must match the app's native `OB_VIP_SEED` — see app README §7). |

## 5. First run checklist

1. `npx wrangler deploy` (after §3/§4).
2. Open `https://<your-worker-or-domain>/Arman-tunnel/admin` and log in with
   `ADMIN_USER` + `ADMIN_PASSWORD`.
3. Settings tab → create at least one **server**, then publish; check the
   panel shows both files green (it re-publishes both bundles per mutation).
4. Smoke tests:
   `curl https://<host>/api/backend` → public branding JSON (must NOT contain
   any secret), `curl https://<host>/` → 404/redirect, `/Arman-tunnel/admin`
   → 200 HTML.
5. The app side must be pointed at you: `obf.dart`
   (`githubConfigUrl/githubSettingsUrl/githubConfigBase` = URLs under your
   `CONFIG_RAW_BASE`; `adminUrl` = this Worker's base URL) — see the app
   package README §7.

## 6. How the pieces fit (= architecture to maintain)

- **Auth**: cookie session (`SENSEI_SESSION` httpOnly) + CSRF double-submit;
  every mutation requires both. Logins rate-limit per IP. Admins are stored
  PBKDF2-hashed in KV; Dev accounts come from the `DEV_ACCOUNTS` secret.
- **Config pipeline**: panel mutations → `validate()` (`config-schema.js`,
  server-side dry-run powers the UI's live error badges) → encrypt both
  bundles → commit to the GitHub repo. The app fetches from
  `CONFIG_RAW_BASE` only.
- **Wire format**: `config-schema.js` is canonical. When you change a field
  you MUST mirror it in `ui/src/types.ts` AND the app's
  `lib/models/server_config.dart` (three-way sync), then run the schema tests.
- **Devices/trial**: the app registers (`/api/device/register`); status is
  mirrored to `<deviceId>.json` in the configs repo so the app reads trial
  state from the CDN (keeps KV writes under the free limit). VIP: see the
  ticket/`/api/vip/resolve` block in `index.js` (tickets are minted/verified
  natively by the app; Vault-guarded endpoints resolve wrapped in the cert
  bundle and never ride the public feed).
- **UI**: pages under `ui/src/pages`, forms in `ui/src/components/` and
  `EntityForms.tsx`. `npm run lint` = `tsc --noEmit`, keep it clean; the
  deploy step is just `npm run build` before `wrangler deploy`.

## 7. Termux helper (optional)

`deploy.sh` is a convenience script that installs a Termux-shimmed wrangler
and reads Cloudflare credentials from a local `cf.env`
(CF_API_TOKEN/CF_ACCOUNT_ID) — it is NOT required; on your PC, plain
`npx wrangler deploy` after `npm run build` in `ui/` does the same. Copy
`cf.env.example` → `cf.env` and fill it in if you use the script — the real
`cf.env` is intentionally not included.

## 8. Security notes for the new owner

- Rotate EVERYTHING you received; nothing in packages here contains the
  author's live credentials: login/dev passwords are env/secret-driven, the
  keystore is not included, and all URLs/seeds ship empty or placeholder.
- Keep `wrangler.toml` free of secret values — only `wrangler Secret put`.
- Back up the KV (`admins`, `devices`, `logs`) — `wrangler kv key list/get`
  or the dashboard; the device/trial ledger lives there.
