#!/usr/bin/env bash
# =============================================================================
# ezagent AutoService dev test launcher
# =============================================================================
# Seeds test data, starts the server, and opens 3 incognito Chrome windows
# each auto-logged-in as a different role via the DevAutoLogin plug.
#
# Usage:
#   bash scripts/dev_test_start.sh              # seed + start + open windows
#   bash scripts/dev_test_start.sh --no-seed    # skip seed, just start + open
#   bash scripts/dev_test_start.sh --no-browser # don't open browser windows
#   bash scripts/dev_test_start.sh --with-slow  # seed with cc slow agents too
#
# Roles opened:
#   1. Customer (alice) → /autoservice
#   2. Operator (op)    → /autoservice/operator
#   3. Admin   (system) → /admin/autoservice
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HOST="${EZAGENT_HOST:-localhost}"
PORT="${EZAGENT_PORT:-10042}"
BASE_URL="http://${HOST}:${PORT}"
SEED=1
OPEN_BROWSER=1
WITH_SLOW=""

# --- parse args ---
for arg in "$@"; do
  case "$arg" in
    --no-seed)    SEED=0 ;;
    --no-browser) OPEN_BROWSER=0 ;;
    --with-slow)  WITH_SLOW="--with-slow" ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

cd "$PROJECT_DIR"

# --- color helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# =============================================================================
# Step 1 — Kill any running server
# =============================================================================
info "Stopping any running phx.server …"
pkill -f "mix phx.server" 2>/dev/null || true
pkill -f "beam.smp.*phx.server" 2>/dev/null || true
sleep 2

# Verify port is free
if lsof -i ":${PORT}" &>/dev/null; then
  warn "Port ${PORT} still in use; force-killing …"
  lsof -ti ":${PORT}" | xargs kill -9 2>/dev/null || true
  sleep 1
fi

# =============================================================================
# Step 2 — Seed test data (optional)
# =============================================================================
if [ "$SEED" -eq 1 ]; then
  info "Seeding autoservice demo data …"

  if [ -n "$WITH_SLOW" ]; then
    mix ezagent.demo.seed_autoservice --with-slow "$WITH_SLOW"
  else
    mix ezagent.demo.seed_autoservice
  fi || warn "Seed exited non-zero (may be ok — check output above)"

  echo ""
fi

# =============================================================================
# Step 3 — Compile & start server in background
# =============================================================================
info "Compiling …"
mix compile --warnings-as-errors=false || warn "Compile warnings (non-fatal)"

info "Starting phx.server on ${BASE_URL} …"
mix phx.server 2>&1 &
SERVER_PID=$!
echo "  Server PID: ${SERVER_PID}"

# =============================================================================
# Step 4 — Wait for server to be ready
# =============================================================================
info "Waiting for server to accept connections …"
MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  if curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/_health" 2>/dev/null | grep -q "200"; then
    info "Server ready (took ${WAITED}s)"
    break
  fi
  sleep 2
  WAITED=$((WAITED + 2))
done

if [ $WAITED -ge $MAX_WAIT ]; then
  fail "Server did not start within ${MAX_WAIT}s — check log output above"
fi

# Give it a moment to finish booting LiveView endpoints
sleep 2

# =============================================================================
# Step 5 — Open 3 incognito browser windows
# =============================================================================
if [ "$OPEN_BROWSER" -eq 1 ]; then
  info "Opening 3 incognito windows …"

  # URLs with ?as= for DevAutoLogin plug to auto-login each role.
  # The plug sets the session cookie then redirects to the clean URL.
  #
  # Admin uses a full entity URI (not bare handle + &workspace=) to
  # avoid the & being interpreted by cmd.exe / shell as a command
  # separator. Bare handles default to workspace "cinnox".
  CUSTOMER_URL="${BASE_URL}/autoservice?as=alice"
  OPERATOR_URL="${BASE_URL}/autoservice/operator?as=op"
  ADMIN_URL="${BASE_URL}/admin/autoservice?as=entity://system/user/admin"

  open_chrome_incognito() {
    local url="$1"
    local label="$2"

    echo "  → ${label}: ${url}"

    # Try multiple methods to open Chrome incognito (WSL / native Linux / macOS)
    if command -v google-chrome &>/dev/null; then
      google-chrome --incognito --new-window "$url" 2>/dev/null &
    elif command -v google-chrome-stable &>/dev/null; then
      google-chrome-stable --incognito --new-window "$url" 2>/dev/null &
    elif command -v chromium &>/dev/null; then
      chromium --incognito --new-window "$url" 2>/dev/null &
    elif command -v chromium-browser &>/dev/null; then
      chromium-browser --incognito --new-window "$url" 2>/dev/null &
    # WSL: route through Windows host
    elif command -v cmd.exe &>/dev/null; then
      cmd.exe /c start chrome --incognito --new-window "$url" 2>/dev/null &
    elif command -v powershell.exe &>/dev/null; then
      powershell.exe -Command "Start-Process 'chrome.exe' -ArgumentList '--incognito','--new-window','$url'" 2>/dev/null &
    # macOS
    elif command -v open &>/dev/null; then
      open -na "Google Chrome" --args --incognito --new-window "$url" 2>/dev/null &
    else
      warn "Could not find Chrome. Open manually: ${url}"
    fi
  }

  # Stagger the windows slightly so they don't all fight for focus at once
  open_chrome_incognito "$CUSTOMER_URL" "customer (alice)"
  sleep 1.5
  open_chrome_incognito "$OPERATOR_URL" "operator (op)"
  sleep 1.5
  open_chrome_incognito "$ADMIN_URL"   "admin (system)"

  echo ""
  info "All 3 windows launched."
  echo ""
  echo "  ┌──────────┬─────────────────────────────────────────────────┐"
  echo "  │ Role     │ URL (after auto-login redirect)                 │"
  echo "  ├──────────┼─────────────────────────────────────────────────┤"
  echo "  │ customer │ ${BASE_URL}/autoservice                          │"
  echo "  │ operator │ ${BASE_URL}/autoservice/operator                 │"
  echo "  │ admin    │ ${BASE_URL}/admin/autoservice                    │"
  echo "  └──────────┴─────────────────────────────────────────────────┘"
  echo ""
  info "Each window has its own incognito session → independent login."
  info "Server log → stdout (PID ${SERVER_PID})"
  info "Stop server: kill ${SERVER_PID}"
else
  info "Skipping browser launch (--no-browser)"
  echo ""
  echo "  Open manually in 3 incognito windows:"
  echo "    customer: ${BASE_URL}/autoservice?as=alice"
  echo "    operator: ${BASE_URL}/autoservice/operator?as=op"
  echo "    admin:    ${BASE_URL}/admin/autoservice?as=entity://system/user/admin"
fi

echo ""
info "Done."
