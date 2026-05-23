# cc-agent end-to-end smoke — operator runbook (Test B)

Companion to the deterministic CI e2e (Test A) at
`apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs`.
That test proves "admin → cc agent → reply" with a fake `claude`
stand-in; this runbook is the human-driven smoke an operator runs on a
real `claude` install to verify production cc-agent configuration
end-to-end.

**This is NOT a CI gate** — Allen V1 sign-off (Feishu 2026-05-22)
explicitly asked for both: the deterministic test for CI, and a manual
recipe for "admin 发消息后 cc agent 可以回复" against a real claude.

## What this smoke proves

The same chain as Test A, but with the real `claude` TUI:

```
admin chat.send (LV or iex)
  → Session fan-out
  → Agent chat.receive
  → BridgeRegistry.lookup (live claude has joined /cc_socket)
  → `to_claude` push on the Phoenix Channel
  → notifications/claude/channel on claude's MCP stdio
  → claude's LLM reads the channel message + calls the `reply` tool
  → `reply` event back over WS → chat.send dispatch from agent
  → session events stream gets the reply
  → admin sees the reply in /admin/sessions/:uri (LV)
```

If this smoke succeeds, the AgentTemplate sandbox config has reached
a real `claude` and the round-trip works against the real LLM.

## Preconditions

Install once:

```bash
# 1. claude on PATH (the real TUI)
claude --version

# 2. uv on PATH (runs the MCP bridge with PEP-723 inline metadata)
uv --version

# 3. authenticated claude — either via `claude login` or an API key
#    that resolves under the sandbox CLAUDE_CONFIG_DIR you'll use.

# 4. an ezagent dev DB
mix ezagent.db.reset       # only if you want a clean slate
```

## Smoke steps

### 1. Start ezagent dev server

```bash
MIX_ENV=dev iex -S mix phx.server
```

The endpoint binds `:10042` (the cc-bridge WS endpoint is at
`ws://127.0.0.1:10042/cc_socket/websocket`).

### 2. Seed an AgentTemplate with a sandbox config

In a separate shell:

```bash
mix ezagent.demo.seed_cc_agent
```

This creates an `AgentTemplate` Kind populated with
`flavor: "cc"`, `working_directory`, `claude_config_dir`,
`settings_path`, and `mcp_config_path` per the Phase-7 slice (see
`docs/runbook/cc-agent-config.md`). The seeded sandbox is the source
of truth for the spawned `claude`'s config.

Alternative — seed via the LV admin UI:

1. Open `http://127.0.0.1:10042/admin/agent_templates/new`
2. Fill in `flavor: cc`, working directory (any writable abs path),
   and (optional) the four sandbox keys.
3. Submit.

### 3. Instantiate the cc agent

```bash
mix ezagent.demo.spawn_session_with_cc_agent
```

Or, in iex:

```elixir
session_uri = URI.parse("session://default/default/smoke-#{System.unique_integer([:positive])}")
{:ok, _} = Ezagent.SpawnRegistry.spawn(session_uri)
:ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.parse("workspace://default"))

agent_uri = URI.parse("entity://agent/default/cc_smoke-#{System.unique_integer([:positive])}")
agent_template_uri = URI.parse("template://agent/default/cc-demo")  # the one seeded above

# Spawn the cc agent through the production CcAgent template path.
# (In LV: /admin/sessions/<sess_uri>/add_agent and pick the template.)
```

### 4. Watch the cc agent come up

The cc Template Class:

- spawns the `Ezagent.Entity.Agent` Kind,
- starts `Ezagent.Domain.Pty.Server` for the agent,
- which runs `claude` under a PTY with the assembled argv
  (`--permission-mode bypassPermissions --dangerously-load-development-channels
  server:esr-bridge --settings <operator?> --settings <plugin mandatory>
  --mcp-config <esr-bridge> --mcp-config <operator?>`).
- `claude` reads `--mcp-config`, spawns `ezagent_mcp_bridge.py` as an
  MCP server subprocess, which connects WS back to `/cc_socket`.

Watch the bridge land:

```elixir
EzagentPluginCc.BridgeRegistry.list_connected()
# => [{<agent_uri>, %{pid: <pid>, connected_at: ..., info: %{claude_info: %{...}, tools: [...]}}}]
```

Or watch the PTY output stream:

```bash
# Open the admin terminal LV
open http://127.0.0.1:10042/admin/agents/<url-encoded-agent-uri>/terminal
```

### 5. Admin sends a message to the cc agent

Option A (admin LV chat UI):

1. Open `http://127.0.0.1:10042/admin/sessions/<url-encoded-session-uri>`
2. Compose a message that **`@-mentions` the cc agent**. Mention-gated
   routing (#226) means an un-mentioned agent gets nothing — type
   `@<agent slot name>` in the LV composer, or pick the agent from
   the mention picker so the live message carries `mentions: [agent_uri]`.
3. Send.

Option B (iex):

```elixir
admin_uri = Ezagent.Entity.User.admin_uri()

msg =
  Ezagent.Message.new(admin_uri, %{text: "hello cc agent, echo this back", attachments: []},
    mentions: [agent_uri]
  )

:ok =
  Ezagent.Invocation.dispatch(%Ezagent.Invocation{
    target: URI.new!("#{URI.to_string(session_uri)}?action=chat.send"),
    mode: :cast,
    args: %{message: msg},
    ctx: %{
      caller: admin_uri,
      caps: Ezagent.Entity.User.admin_caps(),
      reply: :ignore
    }
  })
```

### 6. Observe the reply

The real `claude` will:

1. See the channel message rendered as
   `<channel source="esr-bridge" meta=...>hello cc agent…</channel>`.
2. Read the meta — including `session` (the session URI) and
   `message_id`.
3. Decide to reply (per the bridge's `tools/list` instructions, the
   model is told to call the `reply` tool with the inbound session
   URI from meta).
4. Call `tools/call name="reply" args={text: "...", session_uris:[<session>]}`.
5. The bridge sends a WS `"reply"` event → `EzagentPluginCc.Channel`
   dispatches a fresh `chat.send` from the agent into the session.

You should see the reply in the admin LV chat stream within a few
seconds (depending on claude's LLM latency). If the reply doesn't
appear, see Troubleshooting below.

### 7. Cleanup

```elixir
Ezagent.Domain.Pty.stop(agent_uri)
EzagentPluginCc.BridgeRegistry.unbind(agent_uri)
```

Or just stop `iex -S mix phx.server` — the PtyServer's `trap_exit`
plus the supervisor restart-strategy clean up the child claude.

## Troubleshooting

### "claude executable not found on PATH"

`CcAgent.resolve_claude_executable/1` returns `{:error, :claude_not_found}`.
Install `claude` and re-run.

### No bridge in `BridgeRegistry.list_connected()` after step 4

Tail the bridge log:

```bash
tail -F ~/.ezagent/default/logs/cc-bridge-entity-agent_default_cc_smoke-*.log
```

Common causes:

- `uv` not on PATH — claude spawned the bridge but it crashed at boot.
- WS URL mismatch — check `EZAGENT_BRIDGE_WS_URL` (default
  `ws://127.0.0.1:10042/cc_socket/websocket`).
- Token mismatch — wipe `~/.ezagent/<profile>/` and re-spawn the agent
  so `TokenStore.mint/1` re-issues.

### Bridge connected but no reply

Tail `phx.log` for the warning:

```
Chat receive dropped — no BridgeRegistry binding for entity://agent/...
```

If you see this, the bridge dropped between your subscribe + send. Most
likely the `claude` process exited (LLM crash, OOM, auth failure). Check
the terminal LV.

If you do NOT see the warning, the message reached the bridge but
claude didn't reply. Open the terminal LV — check whether claude is
sitting at a prompt waiting for input, or whether the LLM responded
without calling `reply`. The bridge's `tools/list` instructions tell
the model to call `reply` for any `<channel source="esr-bridge">`
message; if the model deviates (older models occasionally do), refine
the system prompt in the AgentTemplate sandbox's `CLAUDE.md`.

### Reply arrives but admin LV doesn't render it

Check `/admin/sessions/<sess>` is subscribed to
`esr:session:<session_uri>:events`. The LV should show the reply within
~100ms of the agent dispatching `chat.send`. If not, the LV's
subscription is stale; refresh.

## See also

- `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs`
  — the deterministic CI gate that proves this without the LLM.
- `apps/ezagent_plugin_cc/test/fixtures/fake_claude.py` — the
  deterministic `claude` stand-in the CI gate uses.
- `docs/runbook/cc-agent-config.md` — the AgentTemplate sandbox
  config reference.
- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` — the
  Template Class moduledoc with the full safety argv layout.
