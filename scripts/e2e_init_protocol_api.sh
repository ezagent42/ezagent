#!/bin/bash
# ============================================================================
# ezagent_plugin_protocol_api — E2E Test Data Initialization
# ============================================================================
# One-shot script to set up all test data for Phase 0 verification.
# 
# Prerequisites: mix deps.get, mix compile (umbrella)
# Usage: bash scripts/e2e_init_protocol_api.sh
#
# Creates:
#   - Disposable EZAGENT_HOME with fresh DB
#   - Admin password (admin123)
#   - Echo agent (entity://system/agent/echo_default)
#   - Curl agent with DeepSeek (entity://system/agent/curl_protocol_test)
#   - CC agent (entity://system/agent/cc_protocol_test)
#   - Codex agent (entity://system/agent/codex_protocol_test)
#   - Protocol API keys for all agents
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# ---- 1. Fresh disposable EZAGENT_HOME ----
export EZAGENT_HOME=$(mktemp -d /tmp/protocol-api-e2e.XXXXXX)
echo "EZAGENT_HOME=$EZAGENT_HOME"

mix ezagent.home.init > /dev/null 2>&1
MIX_ENV=dev mix ecto.create > /dev/null 2>&1
MIX_ENV=dev mix ecto.migrate > /dev/null 2>&1
echo "[1/6] DB initialized"

# ---- 2. Start server (background) ----
export PORT=10066 PHX_HOST=localhost EZAGENT_FEISHU_WS=0
mix phx.server > /tmp/protocol-api-e2e-server.log 2>&1 &
SERVER_PID=$!
echo "[2/6] Server starting (PID: $SERVER_PID)..."

# Wait for server
for i in $(seq 1 30); do
  sleep 2
  if curl -s -o /dev/null -w "%{http_code}" http://localhost:10066/ 2>/dev/null | grep -q "302\|200"; then
    echo "       Server ready after $((i*2))s"
    break
  fi
done

# ---- 3. Seed all data ----
cat > /tmp/protocol_api_seed.exs << 'SEED'
# Set admin password
db = System.get_env("EZAGENT_HOME") <> "/default/db/ezagent_core.db"
{:ok, conn} = Exqlite.Sqlite3.open(db)
new_hash = Bcrypt.hash_pwd_salt("admin123")
:ok = Exqlite.Sqlite3.execute(conn, "UPDATE users SET password_hash = '#{new_hash}' WHERE uri='entity://system/user/admin'")
IO.puts("  Admin password: admin123")
Exqlite.Sqlite3.close(conn)
SEED
EZAGENT_HOME=$EZAGENT_HOME elixir -pa _build/dev/lib/exqlite/ebin -pa _build/dev/lib/bcrypt_elixir/ebin -pa _build/dev/lib/elixir_make/ebin /tmp/protocol_api_seed.exs

# Instantiate agents via mix run
cat > /tmp/protocol_api_agents.exs << 'AGENTS'
alias Ezagent.TemplateRegistry
alias EzagentCore.Repo

instantiate = fn name, uri, extra ->
  {:ok, cls} = TemplateRegistry.lookup(name)
  tmpl = Map.merge(%{"agent_uri" => URI.to_string(uri)}, extra)
  case cls.instantiate(name, tmpl, Ezagent.URI.new!("workspace://system")) do
    {:ok, _, _} -> IO.puts("  #{name}: created")
    {:error, r} -> IO.puts("  #{name}: #{inspect(r)}")
  end
end

# Echo agent
echo_uri = Ezagent.URI.new!("entity://system/agent/echo_default")
instantiate.("echo.agent", echo_uri, %{})

# Curl agent with DeepSeek
curl_uri = Ezagent.URI.new!("entity://system/agent/curl_protocol_test")
instantiate.("curl.agent", curl_uri, %{
  "provider" => "deepseek", "api_url" => "https://api.deepseek.com/chat/completions", "model" => "deepseek-chat"
})

# CC agent
cc_uri = Ezagent.URI.new!("entity://system/agent/cc_protocol_test")
instantiate.("cc.agent", cc_uri, %{"cwd" => "/tmp"})

# Codex agent
codex_uri = Ezagent.URI.new!("entity://system/agent/codex_protocol_test")
instantiate.("codex.agent", codex_uri, %{})

# Set DeepSeek API key on curl agent
ds_key = System.get_env("DEEPSEEK_API_KEY", "sk-e6cdf76e1a604210ac28edd96e1619b4")
db = System.get_env("EZAGENT_HOME") <> "/default/db/ezagent_core.db"
{:ok, conn} = Exqlite.Sqlite3.open(db)
{:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT state FROM kind_snapshots WHERE uri='entity://system/agent/curl_protocol_test'")
case Exqlite.Sqlite3.step(conn, stmt) do
  {:row, [state_json]} ->
    state = state_json |> Jason.decode!()
    api_keys = Map.get(state, "api_keys", %{})
    keys = Map.get(api_keys, "keys", %{}) |> Map.put("deepseek", ds_key)
    new_state = Map.put(state, "api_keys", Map.put(api_keys, "keys", keys))
    :ok = Exqlite.Sqlite3.execute(conn, "UPDATE kind_snapshots SET state = '#{String.replace(Jason.encode!(new_state), "'", "''")}' WHERE uri='entity://system/agent/curl_protocol_test'")
    IO.puts("  curl: DeepSeek key configured")
  _ -> :ok
end
Exqlite.Sqlite3.close(conn)
AGENTS
MIX_ENV=dev mix run /tmp/protocol_api_agents.exs 2>&1 | grep -E "created|config|Error"
echo "[3/6] Agents created"

# ---- 4. Create protocol_api keys ----
cat > /tmp/protocol_api_keys.exs << 'KEYS'
db = System.get_env("EZAGENT_HOME") <> "/default/db/ezagent_core.db"
{:ok, conn} = Exqlite.Sqlite3.open(db)
now = DateTime.utc_now() |> DateTime.to_iso8601()

keys = [
  {"echo1", "epass1", "entity://system/agent/echo_default"},
  {"curl1", "curlpass1", "entity://system/agent/curl_protocol_test"},
  {"cc1", "ccpass1", "entity://system/agent/cc_protocol_test"},
  {"codex1", "codexpass1", "entity://system/agent/codex_protocol_test"},
]
Enum.each(keys, fn {kid, secret, target} ->
  hash = Bcrypt.hash_pwd_salt(secret)
  {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT OR REPLACE INTO protocol_api_keys (key_id, secret_hash, entity_uri, workspace_uri, label, target_agent, allowed_models, cap_policy, inserted_at, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)")
  :ok = Exqlite.Sqlite3.bind(stmt, [kid, hash, "entity://system/user/admin", "workspace://system", "E2E", target, "[]", "{}", now, now])
  :done = Exqlite.Sqlite3.step(conn, stmt)
  IO.puts("  #{kid} → #{target}")
end)
Exqlite.Sqlite3.close(conn)
KEYS
EZAGENT_HOME=$EZAGENT_HOME elixir -pa _build/dev/lib/exqlite/ebin -pa _build/dev/lib/bcrypt_elixir/ebin -pa _build/dev/lib/elixir_make/ebin /tmp/protocol_api_keys.exs
echo "[4/6] API keys created"

# ---- 5. Verify agents reply ----
echo "[5/6] Verifying agent replies..."

test_agent() {
  local name=$1 key=$2 msg=$3
  local ack=$(curl -s --max-time 10 -X POST "http://localhost:10066/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":\"$msg\"}],\"conversation_id\":\"e2e_$name\"}" 2>/dev/null)
  local id=$(echo "$ack" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  if [ -z "$id" ]; then echo "  $name: FAILED (no ack)"; return; fi
  for i in $(seq 1 15); do sleep 2
    local r=$(curl -s --max-time 5 "http://localhost:10066/v1/chat/completions/$id" -H "Authorization: Bearer $key" 2>/dev/null)
    local c=$(echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content',''))" 2>/dev/null)
    if [ -n "$c" ]; then echo "  $name: $c"; return; fi
  done
  echo "  $name: timeout"
}

test_agent "echo" "pk_echo1_epass1" "Hello from init script"
test_agent "curl" "pk_curl1_curlpass1" "1+1=?"

echo "[6/6] Done! Server running on :10066"
echo ""
echo "Test commands:"
echo '  curl -X POST http://localhost:10066/v1/chat/completions \'
echo '    -H "Authorization: Bearer pk_echo1_epass1" \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '"'"'{"messages":[{"role":"user","content":"hi"}],"conversation_id":"test"}'"'"
echo ""
echo '  curl -X POST http://localhost:10066/v1/chat/completions \'
echo '    -H "Authorization: Bearer pk_curl1_curlpass1" \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '"'"'{"messages":[{"role":"user","content":"hi"}],"conversation_id":"test2"}'"'"
