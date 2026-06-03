# PR-1: cc-agent bridge-token isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the cc-agent bridge-token clobber by removing the per-agent identity (`EZAGENT_AGENT_URI` / `EZAGENT_AGENT_TOKEN`) from the bridge `.mcp.json` env block, so the file (which is written to SHARED locations) can no longer carry per-agent identity that a later spawn clobbers.

**Architecture:** The python bridge (`ezagent_mcp_bridge.py`) reads `EZAGENT_AGENT_URI`/`EZAGENT_AGENT_TOKEN` from `os.environ`. `CcAgent.build_claude_cmd/3` ALREADY exports these per-agent into claude's process env (`cmd_env`) — by design, "so every MCP server claude launches inherits the same per-instance identity." The `.mcp.json` env block is therefore a REDUNDANT duplicate; its shared copies (`~/.ezagent`, git-toplevel, cwd — see `McpConfigWriter.write_with_token!`) get last-writer-wins clobbered, so claude launches the bridge with the WRONG agent's identity → it joins `agent_bridge:cc:<wrong-uri>` → the real agent audits `:no_bridge` and silently drops inbound. Fix: write only the SHARED-safe `EZAGENT_BRIDGE_WS_URL` into the `.mcp.json` env; identity flows via `cmd_env` inheritance. No cwd change, no orchestrator special-case, uniform.

**Tech Stack:** Elixir, `EzagentPluginCc.McpConfigWriter`, ExUnit. Spec: `docs/superpowers/specs/2026-06-02-domain-agent-design.md` (PR-1 row of §4).

**Load-bearing assumption (verified live in Task 4):** claude passes its inherited process env to the MCP servers it launches (the existing `build_claude_cmd/3` cmd_env comment states this is the design, and the orchestrator MCP bridge already relies on it). Task 4's live check is the true gate for this.

---

### Task 1: Make the bridge `.mcp.json` env block carry NO per-agent identity

**Files:**
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/mcp_config_writer.ex` (the `env = %{...}` map inside the config builder used by `write!/1` + `write_with_token!/1`)
- Test: `apps/ezagent_plugin_cc/test/mcp_config_writer_test.exs:35-61` (rewrite the existing test, which currently asserts the BUGGY behavior)

- [ ] **Step 1: Rewrite the existing test to assert the new invariant (the failing test)**

Replace the test at `mcp_config_writer_test.exs:35-61` with:

```elixir
  test "write!/1 emits mcp.json whose env carries NO per-agent identity (clobber-safe)", %{
    out_dir: out_dir
  } do
    # Regression for the 2026-06-02 bridge-token clobber: the .mcp.json is
    # written to SHARED locations (~/.ezagent, git toplevel, cwd), so it must
    # NOT carry per-agent identity — that flows via claude's process env
    # (cmd_env) instead. See docs/superpowers/specs/2026-06-02-domain-agent-design.md.
    agent_uri = "entity://agent/team-alpha/test_writer-test-#{System.unique_integer([:positive])}"

    {:ok, path} =
      McpConfigWriter.write!(
        agent_uri: agent_uri,
        dir: out_dir,
        script_path: "/fake/path/ezagent_mcp_bridge.py",
        ws_url: "ws://127.0.0.1:10042/agent_bridge/websocket"
      )

    assert File.exists?(path)
    config = path |> File.read!() |> Jason.decode!()

    assert config["mcpServers"]["esr-bridge"]["command"] == "uv"

    assert config["mcpServers"]["esr-bridge"]["args"] ==
             ["run", "--script", "/fake/path/ezagent_mcp_bridge.py"]

    env = config["mcpServers"]["esr-bridge"]["env"]
    # Only the SHARED ws_url is written (identical for every agent → clobber-safe).
    assert env["EZAGENT_BRIDGE_WS_URL"] == "ws://127.0.0.1:10042/agent_bridge/websocket"
    # Per-agent identity must NOT be in the (shared) file:
    refute Map.has_key?(env, "EZAGENT_AGENT_URI")
    refute Map.has_key?(env, "EZAGENT_AGENT_TOKEN")
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd apps/ezagent_plugin_cc && mix test test/mcp_config_writer_test.exs -k "carries NO per-agent identity"`
Expected: FAIL — current code writes `EZAGENT_AGENT_URI`/`EZAGENT_AGENT_TOKEN` into `env`, so the two `refute`s fail.

- [ ] **Step 3: Implement — drop per-agent identity from the env map**

In `mcp_config_writer.ex`, the env map currently reads:

```elixir
    env = %{
      "EZAGENT_BRIDGE_WS_URL" => ws_url,
      "EZAGENT_AGENT_URI" => agent_uri_str,
      "EZAGENT_AGENT_TOKEN" => token
    }
```

Replace it with (keep the `token` mint + the return value `{:ok, path, token}` UNCHANGED — the token is still needed for the WS-auth mint and for `CcAgent.build_claude_cmd/3` to put into `cmd_env`):

```elixir
    # Per-agent identity (URI + token) is intentionally NOT written here.
    # This config is written to THREE locations including a SHARED dir + the
    # cwd; a later agent's write would clobber a per-agent token and claude
    # would launch the bridge MCP server under the WRONG agent's identity
    # (→ agent_bridge:cc:<wrong-uri> → real agent audits :no_bridge and drops
    # inbound). Identity instead flows via claude's PROCESS env (cmd_env, set
    # per-agent in `CcAgent.build_claude_cmd/3`), which every MCP server claude
    # launches inherits. Only the SHARED ws_url (same for every agent) is safe
    # to bake into this shared file.
    env = %{"EZAGENT_BRIDGE_WS_URL" => ws_url}
```

Note: `agent_uri_str` is still used (token mint + log) and `token` is still minted + returned, so no unused-variable warnings. Do NOT change the `{:ok, path, token}` return.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd apps/ezagent_plugin_cc && mix test test/mcp_config_writer_test.exs -k "carries NO per-agent identity"`
Expected: PASS.

- [ ] **Step 5: Run the full McpConfigWriter test file (catch the idempotency test, which may assert the token in the file)**

Run: `cd apps/ezagent_plugin_cc && mix test test/mcp_config_writer_test.exs`
Expected: PASS. If `"write!/1 is token-idempotent — re-write returns the same token"` (≈line 63) asserts the token via the written FILE's env, update it to assert idempotency via the RETURN value instead (`{:ok, _path, token}` equal across two calls) — the token is returned, just no longer written into the env block.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/mcp_config_writer.ex apps/ezagent_plugin_cc/test/mcp_config_writer_test.exs
git commit -m "fix(cc/bridge): stop writing per-agent identity into the shared bridge .mcp.json (clobber fix); identity flows via cmd_env"
```

---

### Task 2: Guard the inheritance path — `build_claude_cmd/3` cmd_env MUST carry the per-agent identity

**Files:**
- Test: `apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_build_cmd_test.exs` (create, OR add to an existing `cc_agent` test file if one already exercises `build_claude_cmd/3` — grep first: `grep -rl "build_claude_cmd" apps/ezagent_plugin_cc/test`)

This protects the OTHER half of the fix: now that identity is removed from the file, it MUST be present in `cmd_env` (the existing behavior). A future refactor dropping it from `cmd_env` would silently re-break all agents — this test fails loudly if so.

- [ ] **Step 1: Write the guard test**

```elixir
defmodule Ezagent.PluginCc.Template.CcAgentBuildCmdTest do
  use ExUnit.Case, async: false

  alias Ezagent.PluginCc.Template.CcAgent

  @moduletag :tmp_dir

  test "build_claude_cmd/3 puts per-agent URI + token into cmd_env (the bridge's identity source)",
       %{tmp_dir: tmp_dir} do
    # Skip if `claude` isn't on PATH in this environment (build_claude_cmd
    # resolves the absolute claude binary; without it the call returns
    # {:error, :claude_not_found} and there is nothing to assert).
    if System.find_executable("claude") == nil do
      :ok
    else
      agent_uri = Ezagent.URI.new!("entity://agent/team-alpha/cc_test-buildcmd-#{System.unique_integer([:positive])}")
      tmpl = %{"agent_config_dir" => tmp_dir, "cwd" => tmp_dir}

      {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(agent_uri, tmp_dir, tmpl)

      assert cmd_env["EZAGENT_AGENT_URI"] == URI.to_string(agent_uri)
      assert is_binary(cmd_env["EZAGENT_AGENT_TOKEN"])
    end
  end
end
```

- [ ] **Step 2: Run it**

Run: `cd apps/ezagent_plugin_cc && mix test test/ezagent/template/cc_agent_build_cmd_test.exs`
Expected: PASS (this is existing behavior — `build_claude_cmd/3` already sets `base_env` with both keys). It is a GUARD, not a change. If `claude` is absent the test no-ops (returns `:ok`).

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_build_cmd_test.exs
git commit -m "test(cc): guard that build_claude_cmd cmd_env carries per-agent bridge identity"
```

---

### Task 3: Run the full plugin_cc suite + format

- [ ] **Step 1: Full suite**

Run: `cd apps/ezagent_plugin_cc && mix test`
Expected: PASS (watch for any other test asserting per-agent identity in a written `.mcp.json` — update it the same way as Task 1 Step 5).

- [ ] **Step 2: Format check**

Run: `cd apps/ezagent_plugin_cc && mix format && mix format --check-formatted`
Expected: clean.

- [ ] **Step 3: Commit any formatting**

```bash
git add -A && git commit -m "chore(cc): mix format" || echo "nothing to format"
```

---

### Task 4: LIVE verification (the true gate — validates the cmd_env-inheritance assumption)

This is operator-assisted (needs the running phx server + real claude). It is the regression test for today's actual bug and confirms identity now flows via `cmd_env` (not the file).

- [ ] **Step 1: Start the server** with the merged fix (the canonical run command, e.g. `iex -S mix phx.server`), reachable at `http://100.64.0.27:10042`.

- [ ] **Step 2: Spawn TWO cc agents in one session** (e.g. via the orchestrator `add_managed_member` from `cc-worker` twice, or two operator `create_agent` calls). Both spawn through `Agent.spawn_from_template_content/4 → CcAgent`, so both go through the fixed writer.

- [ ] **Step 3: Assert BOTH bridges register to their OWN URI** — in-node (rpc) or iex:

```elixir
# For each of the two agent URIs:
{:ok, _pid} = Ezagent.AgentBridge.Registry.lookup(agent_uri_1)
{:ok, _pid} = Ezagent.AgentBridge.Registry.lookup(agent_uri_2)
```

Expected: BOTH return `{:ok, pid}` (pre-fix, only the last-spawned agent registered; the other was `:error` → `:no_bridge`). If EITHER is `:error`, the cmd_env-inheritance assumption failed — STOP and reassess (contingency: claude may REPLACE rather than MERGE the MCP-server env; then identity must be re-introduced per-agent another way, e.g. a per-agent `.mcp.json` path — escalate to Allen).

- [ ] **Step 4: Trigger a real message to each agent** and confirm both reply (no `:no_bridge` drop in the phx log). For the scenario-34 relay specifically: `@传话游戏 苹果` should now route cc→codex→curl without an `AgentBridge deliver dropped: :no_bridge` for relay-cc.

- [ ] **Step 5: agent-browser screenshot** of the round-trip per `feedback_esr_e2e_standards` (Standard 3) — the live-tier evidence.

---

## Self-review

- **Spec coverage:** PR-1 row of spec §4 = "domain-allocated bridge config, no cwd change, no orchestrator special-case." This plan achieves the no-clobber outcome via the simpler cmd_env route (pinned 2026-06-02) — same outcome, smaller change. The broader sandbox-consolidation (§3.1 item 2b) is explicitly PR-3, not here.
- **Placeholder scan:** none — every code/test/command block is concrete. The one runtime unknown (claude env merge-vs-replace) is named and gated by Task 4 Step 3 with an explicit contingency.
- **Type/name consistency:** `write!/1`, `write_with_token!/1`, `build_claude_cmd/3`, `AgentBridge.Registry.lookup/1`, the env keys `EZAGENT_AGENT_URI`/`EZAGENT_AGENT_TOKEN`/`EZAGENT_BRIDGE_WS_URL` — all match the code read on 2026-06-02.
