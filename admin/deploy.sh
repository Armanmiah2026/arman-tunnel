#!/usr/bin/env bash
# Deploy the Arman Tunnel admin panel (Worker + React UI) to Cloudflare.
#
# Works straight from Termux! Uses a shimmed wrangler from .deploy/ —
# workerd's arm64 binary is unavailable on Android but `deploy` never
# spawns it. Credentials come from ~/site/cf.env.
#
# Usage:
#   ./deploy.sh                # build UI + deploy Worker
#   ./deploy.sh --skip-build   # deploy only (UI already built)
set -euo pipefail
cd "$(dirname "$0")"

echo "── Arman Tunnel Admin Panel Deploy ──────────────────"

WRANGLER=".deploy/node_modules/wrangler/bin/wrangler.js"
SHIM=".deploy/node_modules/workerd/lib/main.js"
CF_ENV="cf.env"

# First-time setup
if [ ! -f "$WRANGLER" ]; then
  echo "[0/] Installing wrangler (shimmed for Termux)…"
  mkdir -p .deploy
  npm --prefix .deploy install --ignore-scripts --legacy-peer-deps wrangler@4
fi

if grep -q "Unsupported platform" "$SHIM" 2>/dev/null; then
  cat > "$SHIM" <<'SHIMEOF'
"use strict";
var compatibilityDate = "2026-07-30";
Object.defineProperty(exports, "__esModule", { value: true });
exports.compatibilityDate = compatibilityDate;
Object.defineProperty(exports, "binPath", {
  get() { throw new Error("workerd binary unavailable on this platform (deploy-only shim)"); },
});
exports.default = { compatibilityDate };
SHIMEOF
  echo "• workerd shim applied"
fi

if [ ! -f "$CF_ENV" ]; then
  echo "ERROR: $CF_ENV not found — Cloudflare credentials required." >&2
  exit 1
fi

if [[ "${1:-}" != "--skip-build" ]]; then
  echo "[1/2] Building React UI…"
  cd ui
  if [[ ! -d node_modules ]]; then
    echo "      Installing dependencies (first time)…"
    npm install --no-audit --no-fund
  fi
  npm run build
  cd ..
  echo "      ✓ UI built → ui/dist/"
else
  echo "[1/2] Skipping UI build (--skip-build)"
fi

echo "[2/2] Deploying Cloudflare Worker…"
set -a; source "$CF_ENV"; set +a
node "$WRANGLER" deploy

echo ""
echo "✅ Deployed! Panel: https://<your-domain>/Arman-tunnel/admin"
