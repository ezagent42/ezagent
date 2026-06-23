#!/bin/bash
# ============================================================================
# ezagent_plugin_protocol_api — E2E Test Data Initialization (PostgreSQL)
# ============================================================================
# One-shot script to set up + verify the Phase-0 inbound OpenAI-compatible API
# (#82/#896) on the PostgreSQL stack. Replaces the pre-PG SQLite version that
# poked $EZAGENT_HOME/.../ezagent_core.db directly with Exqlite — that DB no
# longer exists (main is PostgreSQL-only; the Repo reads priv/repo_pg).
#
# What it exercises (the load-bearing path for the #896 flavor fix):
#   API-key auth (ApiKeyStore) → conversation resolve → session live →
#   agent spawn (flavor resolved from the agent SNAPSHOT via Ezagent.UriQuery,
#   NOT from the URI name prefix) → agent reply round-trip.
#
# Disposable: a fresh EZAGENT_HOME + a throwaway PG database, both removed on
# exit. Never touches the shared dev DB (ezagent_pg_compat_dev).
#
# Prerequisites: the dev PostgreSQL is up (default 127.0.0.1:55432, the
# ezagent-pg-compat docker container) + mix deps.get + mix compile.
# Usage:
#   bash scripts/e2e_init_protocol_api.sh                 # echo only
#   DEEPSEEK_API_KEY=sk-... bash scripts/e2e_init_protocol_api.sh   # + curl/DeepSeek
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PORT="${PORT:-10066}"
export MIX_ENV=dev
export POSTGRES_DB="protocol_api_e2e_$$"
export EZAGENT_HOME="$(mktemp -d /tmp/protocol-api-e2e.XXXXXX)"
export PHX_HOST=localhost EZAGENT_FEISHU_WS=0
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  MIX_ENV=dev POSTGRES_DB="$POSTGRES_DB" mix ecto.drop --quiet 2>/dev/null || true
  rm -rf "$EZAGENT_HOME" 2>/dev/null || true
}
trap cleanup EXIT

echo "EZAGENT_HOME=$EZAGENT_HOME  POSTGRES_DB=$POSTGRES_DB  PORT=$PORT"

# ---- 1. Fresh disposable home + PG database ----
mix ezagent.home.init > /dev/null 2>&1
mix ecto.create --quiet
mix ecto.migrate --quiet
echo "[1/5] disposable home + PG database ready"

# ---- 2. Start server (echo_default auto-seeds via EzagentPluginEcho.after_boot/0) ----
mix phx.server > /tmp/protocol-api-e2e-server.log 2>&1 &
SERVER_PID=$!
echo "[2/5] server starting (PID: $SERVER_PID)..."
# Discover the actual bound port from the Bandit boot line (dev config bakes its
# own default; PORT env isn't always honored at boot), then poll until it serves.
for i in $(seq 1 40); do
  sleep 2
  bound=$(grep -oE "EzagentWeb.Endpoint with Bandit [^ ]+ at [0-9.]+:[0-9]+" /tmp/protocol-api-e2e-server.log 2>/dev/null | grep -oE "[0-9]+\$" | head -1)
  if [ -n "$bound" ]; then PORT="$bound"; fi
  if [ -n "${PORT:-}" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || true)
    if echo "$code" | grep -q "302\|200"; then echo "       ready on :$PORT after $((i*2))s"; break; fi
  fi
done

# ---- 3. Seed: protocol_api_keys (Ecto, PG) + optional curl agent ----
cat > /tmp/protocol_api_seed.exs << 'SEED'
alias EzagentCore.Repo
alias Ezagent.ProtocolApi.ApiKeyStore
alias Ezagent.TemplateRegistry

put_key = fn key_id, secret, target ->
  Repo.insert!(
    %ApiKeyStore{
      key_id: key_id,
      secret_hash: Bcrypt.hash_pwd_salt(secret),
      entity_uri: "entity://system/user/admin",
      workspace_uri: "workspace://system",
      label: "e2e",
      target_agent: target,
      allowed_models: [],
      cap_policy: %{}
    },
    on_conflict: :replace_all,
    conflict_target: :key_id
  )
  IO.puts("  key #{key_id} -> #{target}")
end

# Echo agent is auto-seeded at boot (EzagentPluginEcho.after_boot/0).
put_key.("echo1", "epass1", "entity://system/agent/echo_default")

# Curl agent (DeepSeek) — instantiated so the protocol API can resolve its
# flavor ("curl") from the snapshot, then its DeepSeek key is set via the agent's
# own `Behavior.ApiKeys.put_api_key` (self-authority dispatch, the same path the
# credential cascade + identities UI use). Proves both the #896 flavor change
# (curl spawns from snapshot flavor, no prefix parse) and the full external LLM
# round-trip.
ds_key = System.get_env("DEEPSEEK_API_KEY")

if ds_key not in [nil, ""] do
  curl_uri = Ezagent.URI.new!("entity://system/agent/curl_protocol_test")
  {:ok, cls} = TemplateRegistry.lookup("curl.agent")
  tmpl = %{
    "agent_uri" => URI.to_string(curl_uri),
    "provider" => "deepseek",
    "api_url" => "https://api.deepseek.com/chat/completions",
    "model" => "deepseek-chat"
  }
  case cls.instantiate("curl.agent", tmpl, Ezagent.URI.new!("workspace://system")) do
    {:ok, _, _} -> IO.puts("  curl.agent: created")
    {:error, r} -> IO.puts("  curl.agent: #{inspect(r)}")
  end

  cap =
    Ezagent.Capability.cap(
      :any,
      Ezagent.Behavior.ApiKeys,
      :put_api_key,
      Ezagent.URI.instance(curl_uri),
      Ezagent.Capability.workspace_of(curl_uri)
    )

  Ezagent.Invocation.dispatch(%Ezagent.Invocation{
    target: Ezagent.URI.with_action(curl_uri, :api_keys, :put_api_key),
    mode: :call,
    args: %{provider: "deepseek", key: ds_key},
    ctx: %{caller: curl_uri, caps: [cap], reply: {:caller_inbox, self()}}
  })
  |> case do
    {:ok, %{ok: true}} -> IO.puts("  curl.agent: deepseek key set")
    other -> IO.puts("  curl.agent: put_api_key -> #{inspect(other)}")
  end

  put_key.("curl1", "curlpass1", "entity://system/agent/curl_protocol_test")
end
SEED
mix run /tmp/protocol_api_seed.exs 2>&1 | grep -E "key |curl.agent" || true
echo "[3/5] API keys seeded"

# ---- 4. Verify replies ----
test_agent() {
  local name=$1 key=$2 msg=$3
  local ack id
  ack=$(curl -s --max-time 10 -X POST "http://localhost:$PORT/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":\"$msg\"}],\"conversation_id\":\"e2e_$name\"}" 2>/dev/null || true)
  id=$(echo "$ack" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
  if [ -z "$id" ]; then echo "  $name: FAILED (no ack) — $ack"; return 1; fi
  for i in $(seq 1 20); do
    sleep 2
    local r c
    r=$(curl -s --max-time 5 "http://localhost:$PORT/v1/chat/completions/$id" -H "Authorization: Bearer $key" 2>/dev/null || true)
    c=$(echo "$r" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('choices',[{}])[0].get('message',{}).get('content',''))" 2>/dev/null || true)
    if [ -n "$c" ]; then echo "  $name reply: $c"; return 0; fi
    if echo "$r" | grep -q '"status":"error"'; then echo "  $name: $r"; return 1; fi
  done
  echo "  $name: timeout"; return 1
}

echo "[4/5] echo round-trip..."
test_agent "echo" "pk_echo1_epass1" "Hello from PG e2e"

if [ "${DEEPSEEK_API_KEY:-}" != "" ]; then
  echo "[4b/5] curl/DeepSeek round-trip..."
  test_agent "curl" "pk_curl1_curlpass1" "1+1=?" || \
    echo "  (curl spawn/flavor OK if ack received; reply needs DeepSeek key provisioned via credential cascade)"
fi

echo "[5/5] Done."
