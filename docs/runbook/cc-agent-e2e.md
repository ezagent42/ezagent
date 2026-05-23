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
#    See "Credential-copy: avoid re-login per agent" below.

# 4. an ezagent dev DB
mix ezagent.db.reset       # only if you want a clean slate
```

## Credential-copy: avoid re-login per agent (Allen 2026-05-23)

### Why credential-copy

A cc agent in sandbox mode runs `claude` with
`CLAUDE_CONFIG_DIR=<sandbox>`. claude in sandbox mode does **NOT**
see your host `~/.claude/` — that is the whole point of the sandbox
(isolated MCP cache, isolated session history, isolated credentials).

Out of the box, this means every new sandboxed cc agent would need
its own `claude login` — and the cc agent is launched
non-interactively under a PTY, so a login prompt would just hang.

To avoid re-logging-in for every agent, copy your authenticated
`~/.claude/.credentials.json` into the sandbox **once**, before the
agent first spawns. The spawned `claude` finds the credentials at
`<sandbox>/.credentials.json` and authenticates without prompting.

### The one-liner

```bash
mix ezagent.demo.seed_cc_sandbox --name my-agent --seed-template my-agent
```

What it does:

1. Creates `~/.ezagent/cc-sandboxes/my-agent/` (chmod 700) if missing.
2. Copies `~/.claude/.credentials.json` into it as `.credentials.json`
   (chmod 600, atomic write).
3. Seeds an `AgentTemplate` at `template://agent/default/cc-my-agent`
   with `flavor: "cc"`, `working_directory` + `claude_config_dir` both
   pointing at the sandbox.

Flags:

| Flag | Effect |
|---|---|
| `--name <s>` | sandbox name (used in default paths + template URI) |
| `--sandbox-dir <p>` | override the default `~/.ezagent/cc-sandboxes/<name>` |
| `--credentials-file <p>` | non-default source (e.g. for a non-standard host setup) |
| `--force` | overwrite an existing `<sandbox>/.credentials.json` |
| `--seed-template <s>` | also seed an AgentTemplate pointing at the sandbox |

Failure modes (all loud — no silent fallthrough):

- source `~/.claude/.credentials.json` missing →
  `no host credentials to copy — claude login first, or pass --credentials-file <path>`
- dest `<sandbox>/.credentials.json` exists without `--force` → refuses to clobber.

### Manual equivalent

```bash
sandbox=~/.ezagent/cc-sandboxes/my-agent
mkdir -p "$sandbox"
chmod 700 "$sandbox"
cp -p ~/.claude/.credentials.json "$sandbox/.credentials.json"
chmod 600 "$sandbox/.credentials.json"
```

Then set `claude_config_dir = $sandbox` in your AgentTemplate (via
the LV `/admin/agent_templates/new` form or programmatically).

### macOS Keychain caveat (read this on macOS)

`claude login` on macOS may store credentials in the **system Keychain**
rather than `~/.claude/.credentials.json`. In that case
`mix ezagent.demo.seed_cc_sandbox` finds no file to copy and fails
loudly with the "no host credentials" error.

Worse, on macOS `CLAUDE_CONFIG_DIR` does NOT isolate the Keychain:
the spawned `claude` in the sandbox still shares Keychain access with
your user account, so all sandboxes effectively share credentials.

For true per-agent credential isolation on macOS, use an API key plus
an `api_key_helper` instead of OAuth + Keychain — see
`docs/runbook/cc-agent-config.md` (the `api_key_helper` field on
AgentTemplate) for the workaround.

This caveat does NOT apply on Linux, where `CLAUDE_CONFIG_DIR`
isolates everything including credentials.

### Re-seeding

The sandbox + credentials persist across agent spawns. Re-seed only:

- to start a fresh sandbox (delete the dir, re-run the one-liner);
- to update credentials after a rotation on the host (re-run with `--force`);
- to point an existing AgentTemplate at a different sandbox (edit the template).

### Where this contract is verified

- `apps/ezagent_plugin_cc/test/integration/cc_agent_sandbox_credentials_test.exs`
  — proves the file-layout + env-threading contract end-to-end:
  a credentials file placed at `<sandbox>/.credentials.json` IS visible
  to a process spawned through the cc agent stack with
  `CLAUDE_CONFIG_DIR=<sandbox>`. The fake claude reads the file back via
  the reply path so the test asserts on the OBSERVED contents (not just
  the env var).
- Cross-links the `AgentTemplate` slice details in
  `docs/runbook/cc-agent-config.md`.

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
  — the deterministic CI gate that proves the full wiring without the LLM.
- `apps/ezagent_plugin_cc/test/integration/cc_agent_sandbox_credentials_test.exs`
  — the deterministic CI gate that proves the sandbox + credential-copy
  file-layout / env-threading contract (the "avoid re-login" flow).
- `apps/ezagent_plugin_cc/test/fixtures/fake_claude.py` — the
  deterministic `claude` stand-in the CI gates use.
- `apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_sandbox.ex`
  — the one-liner mix task referenced in "Credential-copy: avoid
  re-login per agent" above.
- `docs/runbook/cc-agent-config.md` — the AgentTemplate sandbox
  config reference (slice schema, `api_key_helper` macOS workaround).
- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` — the
  Template Class moduledoc with the full safety argv layout.
