#!/bin/bash
# ============================================================================
# ezagent_plugin_protocol_api — E2E Test Data Initialization (PostgreSQL)
# ============================================================================
# One-shot script: echo + curl (DeepSeek) + cc + codex — 2 rounds per agent.
# Prerequisites: PG on 127.0.0.1:55432, mix deps.get, mix compile.
# Usage:
#   DEEPSEEK_API_KEY=sk-... bash scripts/e2e_init_protocol_api.sh
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PORT="${PORT:-10066}"
export MIX_ENV=dev
export POSTGRES_DB="protocol_api_e2e_$$"
export EZAGENT_HOME="$(mktemp -d /tmp/protocol-api-e2e.XXXXXX)"
export PHX_HOST=localhost EZAGENT_FEISHU_WS=0
SERVER_PID=""
RECORDINGS_DIR="$PROJECT_DIR/scripts/e2e_recordings"
mkdir -p "$RECORDINGS_DIR"
RESULTS_FILE="$RECORDINGS_DIR/e2e-results-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$RESULTS_FILE") 2>&1

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  MIX_ENV=dev POSTGRES_DB="$POSTGRES_DB" mix ecto.drop --quiet 2>/dev/null || true
  rm -rf "$EZAGENT_HOME" 2>/dev/null || true
}
trap cleanup EXIT

echo "============================================"
echo "  Protocol-API E2E Test Suite"
echo "  POSTGRES_DB=$POSTGRES_DB"
echo "  EZAGENT_HOME=$EZAGENT_HOME"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# ---- 1. DB Init ----
mix ezagent.home.init > /dev/null 2>&1
mix ecto.create --quiet
mix ecto.migrate --quiet
echo "[1/7] DB ready ✓"

# ---- 2. Start Server ----
mix phx.server > /tmp/protocol-api-e2e-server.log 2>&1 &
SERVER_PID=$!
echo "[2/7] Server starting (PID: $SERVER_PID)..."
for i in $(seq 1 60); do
  sleep 2
  bound=$(grep -oE "Bandit [0-9.]+ at [0-9.]+:([0-9]+)" /tmp/protocol-api-e2e-server.log 2>/dev/null | grep -oE "[0-9]+\$" | head -1) || true
  [ -n "$bound" ] && PORT="$bound"
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null) || true
  if echo "$code" | grep -qE "302|200" 2>/dev/null; then echo "       Server ready on :$PORT after $((i*2))s ✓"; break; fi
done

# ---- 3. Seed: agents + API keys ----
cat > /tmp/protocol_api_seed.exs << 'SEED'
alias EzagentCore.Repo
alias Ezagent.ProtocolApi.ApiKeyStore
alias Ezagent.TemplateRegistry

put_key = fn key_id, secret, target ->
  Repo.insert!(
    %ApiKeyStore{
      key_id: key_id, secret_hash: Bcrypt.hash_pwd_salt(secret),
      entity_uri: "entity://system/user/admin",
      workspace_uri: "workspace://system", label: "e2e",
      target_agent: target, allowed_models: [], cap_policy: %{}
    },
    on_conflict: :replace_all, conflict_target: :key_id
  )
  IO.puts("  #{key_id} → #{target}")
end

IO.puts("--- Seeding agents ---")

# ECHO — auto-seeded at boot (EzagentPluginEcho.after_boot/0)
put_key.("echo1", "epass1", "entity://system/agent/echo_default")
IO.puts("  echo_default: auto-seeded ✓")

# CURL + DeepSeek
ds_key = System.get_env("DEEPSEEK_API_KEY")
if ds_key not in [nil, ""] do
  curl_uri = Ezagent.URI.new!("entity://system/agent/curl_e2e_test")
  {:ok, cls} = TemplateRegistry.lookup("curl.agent")
  case cls.instantiate("curl.agent",
        %{"agent_uri" => URI.to_string(curl_uri),
          "provider" => "deepseek",
          "api_url" => "https://api.deepseek.com/chat/completions",
          "model" => "deepseek-chat"},
        Ezagent.URI.new!("workspace://system")) do
    {:ok, _, _} ->
      cap = Ezagent.Capability.cap(:any, Ezagent.ActionSet.ApiKeys, :put_api_key,
             Ezagent.URI.instance(curl_uri), Ezagent.Capability.workspace_of(curl_uri))
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: Ezagent.URI.with_action(curl_uri, :api_keys, :put_api_key),
        mode: :call, args: %{provider: "deepseek", key: ds_key},
        ctx: %{caller: curl_uri, caps: [cap], reply: {:caller_inbox, self()}}
      })
      IO.puts("  curl_e2e_test: created + DeepSeek key set ✓")
      put_key.("curl1", "curlpass1", URI.to_string(curl_uri))
    {:error, r} -> IO.puts("  curl_e2e_test: FAILED — #{inspect(r)}")
  end
else
  IO.puts("  curl: skipped (no DEEPSEEK_API_KEY)")
end

# CC
try do
  {:ok, cls} = TemplateRegistry.lookup("cc.agent")
  cc_uri = Ezagent.URI.new!("entity://system/agent/cc_e2e_test")
  cwd = System.get_env("HOME") || "/tmp"
  case cls.instantiate("cc.agent",
        %{"agent_uri" => URI.to_string(cc_uri), "cwd" => cwd},
        Ezagent.URI.new!("workspace://system")) do
    {:ok, _, _} ->
      IO.puts("  cc_e2e_test: created ✓")
      put_key.("cc1", "ccpass1", URI.to_string(cc_uri))
    {:error, r} -> IO.puts("  cc_e2e_test: #{inspect(r)}")
  end
rescue
  e -> IO.puts("  cc_e2e_test: error — #{Exception.message(e)}")
end

# CODEX
try do
  {:ok, cls} = TemplateRegistry.lookup("codex.agent")
  codex_uri = Ezagent.URI.new!("entity://system/agent/codex_e2e_test")
  cwd = System.get_env("HOME") || "/tmp"
  case cls.instantiate("codex.agent",
        %{"agent_uri" => URI.to_string(codex_uri), "cwd" => cwd},
        Ezagent.URI.new!("workspace://system")) do
    {:ok, _, _} ->
      IO.puts("  codex_e2e_test: created ✓")
      put_key.("codex1", "codexpass1", URI.to_string(codex_uri))
    {:error, r} -> IO.puts("  codex_e2e_test: #{inspect(r)}")
  end
rescue
  e -> IO.puts("  codex_e2e_test: error — #{Exception.message(e)}")
end
SEED
mix run /tmp/protocol_api_seed.exs 2>&1 | grep -E "Seeding|---|→|created|FAILED|error|skipped" || true
echo "[3/7] Agents seeded ✓"

# ---- 4. Two-round E2E tests ----
test_round() {
  local label=$1 key=$2 msg=$3
  local ack id
  ack=$(curl -s --max-time 15 -X POST "http://localhost:$PORT/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":\"$msg\"}],\"conversation_id\":\"e2e_${label}\"}" 2>/dev/null || true)
  id=$(echo "$ack" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
  if [ -z "$id" ]; then echo "     ✗ no ack — $ack"; return 1; fi
  for i in $(seq 1 30); do
    sleep 2
    local r c
    r=$(curl -s --max-time 5 "http://localhost:$PORT/v1/chat/completions/$id" -H "Authorization: Bearer $key" 2>/dev/null || true)
    c=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content',''))" 2>/dev/null || true)
    if [ -n "$c" ]; then echo "     ✓ reply ($((i*2))s): $c"; return 0; fi
    if echo "$r" | grep -q '"status":"error"'; then echo "     ✗ error: $(echo $r | python3 -c "import sys,json;print(json.load(sys.stdin))" 2>/dev/null)"; return 1; fi
  done
  echo "     ✗ timeout (60s)"; return 1
}

echo ""
echo "============================================"
echo "  Round 1 — Simple greetings"
echo "============================================"

echo "[4a/7] Echo round 1..."
test_round "echo1" "pk_echo1_epass1" "Hello from ezagent protocol API!"

if [ "${DEEPSEEK_API_KEY:-}" != "" ]; then
  echo "[4b/7] Curl+DeepSeek round 1..."
  test_round "curl1" "pk_curl1_curlpass1" "Say hello in Chinese"
fi

echo "[4c/7] CC round 1..."
test_round "cc1" "pk_cc1_ccpass1" "What is 1+1?" || echo "     (may need credential cascade)"

echo "[4d/7] Codex round 1..."
test_round "codex1" "pk_codex1_codexpass1" "What is 1+1?" || echo "     (may need credential cascade)"

echo ""
echo "============================================"
echo "  Round 2 — Richer content"
echo "============================================"

echo "[5a/7] Echo round 2..."
test_round "echo2" "pk_echo1_epass1" "Tell me a one-line programming joke"

if [ "${DEEPSEEK_API_KEY:-}" != "" ]; then
  echo "[5b/7] Curl+DeepSeek round 2..."
  test_round "curl2" "pk_curl1_curlpass1" "What is 2+2? Answer in one sentence."
fi

echo "[5c/7] CC round 2..."
test_round "cc2" "pk_cc1_ccpass1" "Explain the difference between HTTP and WebSocket in one sentence" || echo "     (may need credential cascade)"

echo "[5d/7] Codex round 2..."
test_round "codex2" "pk_codex1_codexpass1" "Explain the difference between HTTP and WebSocket in one sentence" || echo "     (may need credential cascade)"

echo ""
echo "============================================"
echo "  E2E Complete — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Results saved: $RESULTS_FILE"
echo "  Server log: /tmp/protocol-api-e2e-server.log"
echo "============================================"
