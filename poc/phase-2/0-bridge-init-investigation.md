# Phase 2.0 — Bridge-init trigger investigation

## Result: bare `\r` to PTY triggers full bridge handshake in ~500ms

Empirically verified on ezagent `f243a58` (post-agent_bridge PRs #421-432, 2026-05-27).

### Trigger contract

| Step | Action | Latency |
|---|---|---|
| 0 | Spawn cc agent via `Workspace.create_agent(flavor: "cc", ...)` | claude process alive but **no MCP children, no `BridgeRegistry` entry** |
| 1 | `Ezagent.Domain.Pty.Server.write_input(pty_pid, "\r")` | `:ok` immediately |
| 2 | claude spawns `uv run --script ezagent_mcp_bridge.py` as child | ~50-200ms |
| 3 | Python bridge opens WS to `agent_bridge/websocket?token=...&agent_uri=...&vsn=2.0.0` | ~200-400ms (HTTP 101) |
| 4 | Bridge joins topic `agent_bridge:cc:<agent_uri>` via `phx_join` | ~20ms after WS open |
| 5 | `BridgeRegistry.lookup(agent_uri)` transitions from `:error` → `{:ok, channel_pid}` | atomic with step 4 server-side |

**Total wall time from `write_input` to `{:ok, _}` binding: ~500-1000ms.**

### Verification record

```elixir
# Before trigger:
:rpc.call(runtime, EzagentPluginCc.BridgeRegistry, :lookup, [agent_uri])
#=> :error

# After: write_input(pid, "\r"); sleep 500ms:
:rpc.call(runtime, EzagentPluginCc.BridgeRegistry, :lookup, [agent_uri])
#=> {:ok, #PID<12514.1161.0>}
```

Bridge log shows full handshake:

```
INFO v2 bridge starting; ws=ws://127.0.0.1:10142/agent_bridge/websocket
INFO claude → bridge: method=initialize id=0
INFO claude → bridge: method=notifications/initialized
INFO claude → bridge: method=tools/list id=1
... [WS HTTP 101 upgrade] ...
INFO ws connected; joining agent_bridge:cc:entity://agent/acme/cc_cs_main
> TEXT '["1", "1", "agent_bridge:cc:entity://agent/acme/cc_cs_main", "phx_join", {}]'
< TEXT '["1","1",...,"status":"ok",...]'
INFO join ok; starting loops
```

## Contradicts Phase 0.5

Phase 0.5 (2026-05-26, ezagent main at `4f08a4f`) explicitly reported: *"`Ezagent.Domain.Pty.Server.write_input` of `\r`, `hi\r`, ` \r` — none triggered MCP-server spawn"*.

This investigation (2026-05-27, ezagent main at `f243a58`) finds the opposite: bare `\r` works in ~500ms. The delta is **13 commits on ezagent main**, primarily the `agent_bridge` PR series:

- PR #421 — spec: r2 AgentBridge domain extraction
- PR #424 — promote token store and registry
- PR #425 — refactor(domain_agent): detect PTY lifecycle by behavior
- PR #428 — promote socket and channel
- PR #429 — route agent chat through bridge adapters
- PR #432 — remove domain chat cc dependency

These changes evidently altered cc agent's MCP-init behavior. The user-visible topic name also changed from `cc:bridge:<uri>` (Phase 0.5) to `agent_bridge:cc:<uri>` (now), confirming this is the same refactor surface.

**Operational consequence**: Phase 0.5's design question — "should we add an `EagerBridge` primitive?" — is now even more concretely answerable. The trigger is empirically known; EagerBridge just needs to call it.

## Side finding (worth a separate issue)

`EZAGENT_BRIDGE_WS_URL` defaults to hardcoded `ws://127.0.0.1:10042/agent_bridge/websocket` ([mcp_config_writer.ex:189-197](apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/mcp_config_writer.ex#L189)). When ezagent runs on a non-default port (e.g., `PORT=10142`), the bridge spawns successfully but cannot connect (`Errno 61` retry loop). The fix at our end was setting `EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10142/agent_bridge/websocket` in the BEAM env before `mix phx.server`. Symmetric to issue #412 (default node name doesn't follow `EZAGENT_PROFILE`); **same fix shape**: derive default from `$PORT` if WS URL env unset. File as a new ezagent issue.

## Implications for Phase 2.1 EagerBridge primitive design

The primitive can be lean:

```elixir
defmodule EzagentPluginCc.EagerBridge do
  @doc "Ensures BridgeRegistry has a binding for agent_uri; trigger if needed."
  @spec ensure_bound!(URI.t(), timeout_ms :: pos_integer()) :: :ok | {:error, :timeout}
  def ensure_bound!(agent_uri, timeout_ms \\ 5_000) do
    case EzagentPluginCc.BridgeRegistry.lookup(agent_uri) do
      {:ok, _pid} -> :ok                                             # already bound
      :error -> kick_and_wait(agent_uri, timeout_ms)
    end
  end

  defp kick_and_wait(agent_uri, timeout_ms) do
    {:ok, pty_pid} = Ezagent.Domain.Pty.lookup(agent_uri)
    :ok = Ezagent.Domain.Pty.Server.write_input(pty_pid, "\r")
    wait_for_binding(agent_uri, timeout_ms)
  end

  defp wait_for_binding(agent_uri, remaining_ms) when remaining_ms <= 0,
    do: {:error, :timeout}

  defp wait_for_binding(agent_uri, remaining_ms) do
    Process.sleep(100)
    case EzagentPluginCc.BridgeRegistry.lookup(agent_uri) do
      {:ok, _pid} -> :ok
      :error -> wait_for_binding(agent_uri, remaining_ms - 100)
    end
  end
end
```

**Properties**:
- Idempotent: calling on an already-bound agent is a fast no-op
- Caller-opt-in: any channel plugin that wants a guaranteed bridge calls this before dispatching customer message
- Fail loud: `{:error, :timeout}` after 5s (default) lets caller surface a real error to the customer rather than silent silent-drop
- Zero impact on cc agents that don't need eager bridge (operator-bound agents that humans open in `/terminal` still work the same — operator's first keystroke triggers same MCP init)

**Sentinel-input semantics**: bare `\r` is the most innocuous trigger:
- Doesn't say anything claude has to interpret/respond to
- claude treats it as an empty submit at the TUI prompt — typically just shows another prompt, no expensive turn
- Could swap for a more deliberate sentinel later (e.g., `# ezagent_warmup\r` if we want it visible in PTY traces) — but no functional reason

## Open question (not blocking 2.1)

Why does bare `\r` now suffice when Phase 0.5 it didn't? The `agent_bridge` PR series clearly changed something. Could be:
- claude's startup flow restructured so MCP init runs on first input event (any input)
- ezagent's PtyServer scanner / auto_prompts now flushing differently
- some claude-internal state machine change in a recent `claude` binary version

Not blocking for our work — the trigger is reliable today. If the `agent_bridge` team eventually documents this in ARCHITECTURE.md, we can cross-reference.

## What's next

- Phase 2.1: implement `EzagentPluginCc.EagerBridge.ensure_bound!/2` per the sketch above + unit test
- File the `EZAGENT_BRIDGE_WS_URL` port-derivation issue against ezagent (separate, ~10 min)
