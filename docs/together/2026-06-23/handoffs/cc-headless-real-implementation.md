# Handoff: cc-headless real implementation

> Date: 2026-06-23
> Branch context: `agent-flavor-headless-protocol-api`
> Purpose: next-stage plan to replace the current `cc-headless` spawn stub with a real no-PTY Claude backend.

## Current finding

The current `cc-headless` slice registers the flavor, template, adapter, and workspace create path, but it does not start a Claude backend. `Ezagent.PluginCc.Template.CcHeadlessAgent` still marks the subprocess path as a stub and returns success after credential materialization.

That means `cc-headless` can be selected/spawned as an Agent Kind, but it is not yet a real session-capable Claude agent.

## 3A vs 3B: Feasibility verification (2026-06-23)

Two approaches were considered for the headless Claude subprocess. **Both were verified against Claude Code 2.1.186 on the actual host.**

### 3B: `server:esr-bridge` without PTY — ❌ NOT VIABLE

The idea was to reuse the same `claude ... server:esr-bridge` argv as `cc`, but launch via `Port.open/2` (or erlexec without `:pty`) instead of `Domain.Pty.start/2`.

| Test | Command | Result |
|------|---------|--------|
| `/dev/null` stdin | `claude ... server:esr-bridge < /dev/null` | ❌ `Input must be provided either through stdin or as a prompt argument when using --print` |
| pipe stdin | `echo "" \| claude ... server:esr-bridge` | ❌ `No messages returned from query` — exits immediately |
| `-p` + `server:esr-bridge` | `echo "" \| claude -p ... server:esr-bridge` | ❌ Same — exits immediately after MCP init |

**Root cause**: Claude Code 2.1 requires a TTY for non-`-p` mode. `Port.open/2` creates pipes, not PTYs. `-p` mode is designed for one-shot queries and exits after the response — it cannot keep `server:esr-bridge` alive as a persistent daemon.

### 3A: `claude -p` stdio pipe — ✅ VIABLE

Use `claude -p --input-format stream-json --output-format stream-json` with `--session-id` / `--resume` for multi-turn persistence.

| Test | Command | Result |
|------|---------|--------|
| Text mode multi-turn | Round 1: `--session-id X` "My name is Alice" → Round 2: `--resume X` "What is my name?" | ✅ "你的名字是 **Alice**" |
| stream-json mode | `--input-format stream-json --output-format stream-json --verbose` | ✅ JSON lines 正常流式输入输出 |
| stream-json multi-turn | Round 1: remember "XKCD-42" → Round 2: recall "XKCD-42" | ✅ 跨 invocation session 持久化 |
| `--session-id` UUID 要求 | `--session-id` 必须传入合法 UUID | ✅ `uuidgen` 生成即可 |

**Trade-off**: `-p` mode is one-invocation-per-message (not a persistent daemon). This means:
- Higher per-message latency (process startup ~1-3s)
- Simpler process management (no persistent subprocess to monitor/respawn)
- Session persistence via on-disk `--session-id` / `--resume`
- No esr-bridge, no WebSocket bridge, no AgentBridge transport needed

## Chosen implementation route: 3A `claude -p` stdio

The 3B route (`Port.open/2` with `server:esr-bridge`, no PTY) was the original plan but **failed feasibility verification** — Claude Code 2.1 requires a TTY for non-`-p` mode. 3A is the only viable path to a headless Claude backend.

### Architecture

```
agent.receive → AgentBridge.deliver(:in_process_sync)
  → CcHeadlessBridgeAdapter.deliver/2
    → HeadlessRunner.call(session_id, config_dir, message)
      → Port.open(claude -p --resume <sid> --input-format stream-json ...)
        → stdin: {"type":"user","message":{"role":"user","content":"..."}}
        ← stdout: {"type":"assistant",...} ... {"type":"result",...}
      → {:ok, response_text} | {:error, reason}
  → {:sync, result}
→ agent.receive 重分发 :sync_result
→ Behavior 持久化 + session.send 回复
```

### Key differences from `cc` (PTY flavor)

| Aspect | `cc` (PTY) | `cc-headless` (3A) |
|--------|-----------|---------------------|
| Transport class | `:subprocess_ws` | `:in_process_sync` |
| Subprocess lifecycle | Persistent (erlexec + PTY) | One-shot per message (`claude -p`) |
| Communication | WebSocket → esr-bridge → PTY | Port stdin/stdout (stream-json) |
| Multi-turn | Implicit (same PTY session) | Explicit (`--session-id` / `--resume`) |
| Process management | PtyServer (GenServer + erlexec monitor) | None (Port exits after each response) |
| BridgeAdapter | WebSocket-based (CcBridgeAdapter) | Sync `deliver/2` returning `{:ok, text}` |

## Implementation plan

### 1. Create `Ezagent.PluginCc.HeadlessRunner`

A module that wraps a single `claude -p` invocation:

```elixir
defmodule Ezagent.PluginCc.HeadlessRunner do
  @moduledoc """
  One-shot claude -p invocation. Not a GenServer — each call spawns a
  short-lived claude subprocess, sends the user message via stdin
  (stream-json), reads the assistant response from stdout, and returns.
  """

  @doc """
  Run claude -p for a single turn. Uses `--resume` when session_id is
  known (multi-turn continuation), `--session-id` on the first call.

  Returns `{:ok, response_text, metadata}` or `{:error, reason}`.
  """
  def call(session_id, config_dir, message_text, opts \\ []) do
    # Build argv: claude -p --resume <sid> --input-format stream-json
    #            --output-format stream-json --verbose
    # With CLAUDE_CONFIG_DIR env pointing to config_dir
    # Write stream-json user message to stdin
    # Read stream-json lines from stdout until "type":"result"
    # Parse and return the assistant text
  end
end
```

Key implementation details:
- Port mode: `:binary`, `:exit_status`, `:use_stdio` for stdin, `:stream` for stdout
- Env: `CLAUDE_CONFIG_DIR` → per-agent config dir
- stdin JSON: `{"type":"user","message":{"role":"user","content":"..."}}`
- stdout parsing: match `"type":"assistant"` for content, `"type":"result"` for completion
- Timeout: configurable (default ~60s)

### 2. Update `CcHeadlessBridgeAdapter`

```elixir
defmodule EzagentPluginCc.CcHeadlessBridgeAdapter do
  @behaviour Ezagent.AgentBridge.Adapter

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "cc-headless"

  # KEY CHANGE: use :in_process_sync instead of delegating to CcBridgeAdapter
  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: :in_process_sync

  # KEY CHANGE: custom deliver that runs claude -p
  @impl Ezagent.AgentBridge.Adapter
  def deliver(payload, _channel_pid) do
    # payload contains: text, agent_uri, session info
    # Resolve session_id + config_dir from agent state
    # Call HeadlessRunner.call/4
    # Return {:ok, %{content: ..., usage: ...}} or {:error, reason}
  end

  # These remain delegated to CcBridgeAdapter (used by LV for terminal display)
  @impl Ezagent.AgentBridge.Adapter
  defdelegate handle_client_event(event, params, socket), to: EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate socket_path, to: EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate channel_topic_prefix, to: EzagentPluginCc.BridgeAdapter

  @impl Ezagent.AgentBridge.Adapter
  defdelegate join_info(params, socket), to: EzagentPluginCc.BridgeAdapter
end
```

### 3. Replace `CcHeadlessAgent` spawn stub

In `spawn_for_headless/3`:

1. Ensure Agent Kind (already done).
2. Create config dir with grant (already done).
3. Revalidate grant before first use (already done).
4. **NEW**: Generate a UUID `session_id` and store it in the template's respawn data.
5. **NEW**: Run a BOOTSTRAP `claude -p --session-id <sid>` call to initialize the Claude session (optional first "ping" message, e.g. "You are an AI assistant. Acknowledge ready.").
6. Return metadata including `claude_session_id` for the deliver path.

```elixir
defp spawn_for_headless(agent_uri, tmpl, _workspace_uri) do
  with {:ok, started_or_adopted} <- ensure_agent_kind(agent_uri) do
    case started_or_adopted do
      :already_started ->
        {:ok, [agent_uri], %{fresh?: false}}

      :started ->
        case create_agent_config_dir_with_grant(agent_uri, tmpl) do
          {:ok, config_dir, grant_ctx} ->
            tmpl_with_dir = put_agent_config_dir(tmpl, config_dir)

            case revalidate_grant_before_launch(grant_ctx) do
              :ok ->
                # Generate persistent session ID for multi-turn
                session_id = UUID.uuid4()
                tmpl_with_sid = Map.put(tmpl_with_dir, "claude_session_id", session_id)

                # Bootstrap: initialize the Claude session with a ready check
                _bootstrap_result = HeadlessRunner.call(
                  session_id, config_dir, "You are an AI assistant. Acknowledge ready.",
                  mode: :session_init
                )

                Logger.info(
                  "cc-headless: agent #{URI.to_string(agent_uri)} " <>
                    "spawned with claude session #{session_id}"
                )

                {:ok, [agent_uri],
                 %{
                   fresh?: true,
                   config_dir_path: config_dir,
                   claude_session_id: session_id,
                   respawn_template_data: tmpl_with_sid
                 }}

              {:error, reason} ->
                _ = Ezagent.Kind.terminate(agent_uri)
                handle_spawn_failure(agent_uri, reason)
            end

          {:error, reason} ->
            _ = Ezagent.Kind.terminate(agent_uri)
            handle_spawn_failure(agent_uri, reason)
        end
    end
  end
end
```

### 4. Implement real `ensure_subprocess_alive`

Since 3A has no persistent subprocess, `ensure_subprocess_alive/2` validates that the session_id is still usable:

```elixir
@impl Ezagent.Kind.Template
def ensure_subprocess_alive(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
  # No persistent subprocess to check — validate session integrity instead.
  # If the on-disk Claude session still exists, we're ready.
  case Map.fetch(respawn_data, "claude_session_id") do
    {:ok, sid} when is_binary(sid) and sid != "" ->
      Logger.info("cc-headless: session #{sid} ready for #{URI.to_string(agent_uri)}")
      :ok
    _ ->
      {:error, {:missing_claude_session_id, agent_uri}}
  end
end
```

### 5. Add `:sync_result` behavior

The `agent.receive` handler re-dispatches to `:sync_result` on the agent Kind for `:in_process_sync` transport. The cc-headless agent needs a Behavior that handles this action.

**Option A**: Register a lightweight `CcHeadlessSyncResult` behavior on `Entity.Agent` that persists the conversation and dispatches replies (similar to `CurlAgent` but for cc-headless).

**Option B**: Reuse `CurlAgent`'s `handle_sync_result/2` — the conversation persistence and reply dispatch are generic. This requires ensuring `CurlAgent` is in the effective behavior set for cc-headless agents (via `:kind_base`).

Recommendation: **Option A** (separate behavior) for clean flavor isolation.

### 6. Verification

Focused tests:
- `HeadlessRunner.call/4` with a mock claude script
- `CcHeadlessBridgeAdapter.deliver/2` returns `{:ok, response}` shape
- `CcHeadlessAgent.instantiate/3` generates session_id + runs bootstrap
- `ensure_subprocess_alive/2` validates session_id presence
- Failure path: missing session_id → clear error

Integration evidence:
- protocol-api sends message → `agent.receive` → `deliver/2` → `claude -p` → response
- session.send reply dispatched back into the session
- multi-turn: Round 2 uses `--resume` and correctly references Round 1 context

Live/E2E evidence:
- session screenshot for `cc-headless` must show a real Claude reply (not just an ACK)
- multi-turn conversation with contextual recall

## Non-goals for this follow-up

- Do not attempt `Port.open/2` with `server:esr-bridge` (3B) — verified infeasible against Claude Code 2.1.186.
- Do not change `AgentFlavorRegistry` semantics.
- Do not change CapBAC or credential grant behavior.
- Do not rework protocol-api external adapter architecture.

## Acceptance wording

Use this wording when reporting status:

> `cc-headless` is implemented as a one-shot `claude -p` invocation per message turn, using `--input-format stream-json --output-format stream-json` with `--session-id` / `--resume` for multi-turn persistence. It uses `:in_process_sync` transport class (like curl), with the `CcHeadlessBridgeAdapter.deliver/2` running a short-lived `claude -p` subprocess that writes the user message to stdin and reads the assistant response from stdout.

Do not call the current stub implementation complete under this acceptance definition.

## Rejected alternative

**3B: `Port.open/2` with `server:esr-bridge` (no PTY)**: Rejected after feasibility verification on 2026-06-23. Claude Code 2.1.186 requires a TTY for non-`-p` mode (`"Input must be provided either through stdin or as a prompt argument when using --print"`). `Port.open/2` creates pipes, not PTYs. `-p` mode exits after response and cannot keep `server:esr-bridge` alive. This approach is fundamentally incompatible with current Claude Code behavior and is archived.
