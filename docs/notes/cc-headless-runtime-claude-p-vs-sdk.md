# cc-headless runtime: `claude -p --mcp-config --resume` vs the SDK persistent sidecar

**Date:** 2026-07-10 · **Author:** Claude (measured in canary container `ezagent-nightly-ezagent-1`) · **Status:** recommendation + migration plan

## TL;DR

- **Measured per-turn penalty of `claude -p` over the SDK persistent sidecar is ~1.5s (no MCP) to ~1.9s (with the orchestrator MCP), median.** That is *process startup*; the model round-trip (2–11s, median ~2.6s warm) is shared by both runtimes and its variance alone dwarfs the fixed startup penalty.
- **`claude -p --mcp-config <orchestrator.mcp.json>` loads and fires the orchestrator tools out-of-the-box** — proven empirically: `list_templates` was selected and invoked through the on-disk config. The current SDK worker cannot do this (it hardcodes `setting_sources=[]` + `strict_mcp_config=True` and reads MCP only from inline env), so it has **no working MCP tools today**.
- **Resource:** each persistent runtime holds a resident `claude` node (~**200 MB RSS**, measured) **plus** a Python SDK worker (~15–40 MB) **per agent, at idle**. `-p` holds **0 at idle**; ~200 MB is transient, only during an active turn, and scales with *concurrency*, not fleet size.
- **Recommendation: move both the orchestrator and default cc-headless agents to `claude -p --mcp-config --resume`.** It is the shorter and more-correct path: it reuses the exact on-disk `orchestrator.mcp.json` / `.mcp.json` / settings / CLAUDE.md the PTY path already generates, needs **no SDK inline-wiring build**, and eliminates ~215 MB × M of idle memory. The SDK's only real advantage — amortizing the ~1.9s startup — is not worth the inline MCP/persona re-wiring build and the per-agent resident footprint, given startup is a small, low-variance fraction of a model turn.

---

## 1. What each runtime is

### SDK persistent sidecar (current cc-headless)
`EzagentPluginCc.SdkSidecar` (`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/sdk_sidecar.ex`) is a supervised GenServer that spawns one long-lived Python worker (`priv/python/ezagent_cc_sdk_worker.py`, `ClaudeSDKClient`) **per agent**. The worker keeps a `claude` process alive in streaming mode; each turn is a `query + receive_response` round-trip over stdin/stdout JSON lines. Process boot and MCP-server boot are paid **once** and amortized.

**The capability gap (verified in source):** the worker constructs
```python
ClaudeAgentOptions(setting_sources=[], strict_mcp_config=True, ...)
```
so it deliberately does **not** read on-disk `settings.json`, `.mcp.json`, or `CLAUDE.md`. MCP servers come only from the `EZAGENT_CC_SDK_MCP_SERVERS` env (an inline map), and the persona only from `EZAGENT_CC_SDK_SYSTEM_PROMPT`. `sdk_sidecar_params/2` in `cc_headless_agent.ex` *threads* `mcp_servers` and `system_prompt` from the template — but **nothing populates them** for the orchestrator. The orchestrator's tools live in the on-disk `orchestrator.mcp.json` (see below), which the worker ignores. **Net: cc-headless has no working MCP tools today**, which is what blocks migrating the orchestrator (and default agents) onto it.

### `claude -p` per-turn process (proposed)
Headless print mode. Each turn spawns a fresh `claude -p "<text>" --output-format json`, optionally `--resume <session_id>` for continuity and `--mcp-config <file>` for tools. It **reads on-disk config naturally** — the same `--settings` / `--mcp-config` artifacts the PTY path (`spawn_plan.ex assemble_settings_mcp_args/3`) already assembles. Trade-off: each turn re-boots the `claude` node (and re-spawns the MCP server), so startup is **not** amortized.

---

## 2. Measurement

**Environment:** canary container `ezagent-nightly-ezagent-1`, real `claude 2.1.162` at `/usr/bin/claude`, model `claude-opus` (default), via the container's `mihomo:7897` proxy. Authenticated with a throwaway `CLAUDE_CONFIG_DIR` seeded from the docker host's `~/.claude/.credentials.json` (OAuth), removed afterward. Each `claude` call is a direct in-container spawn (one `docker exec` wrapping the whole batch — no per-call harness overhead), so wall time is production-representative. n=8 per scenario (n=4 for the real orchestrator bridge). With n=8, treat min/median/p90 as **indicative**; p90 ≈ max.

**Decomposition method:** wall clock is measured with `date +%s.%N` around each spawn. `claude`'s JSON reports `duration_ms` — its *internal* measure, which excludes node process boot/teardown. So:
- **model round-trip ≈ `duration_ms`** (dominant, shared by both runtimes)
- **process startup ≈ `wall − duration_ms`** (the node boot the SDK amortizes)
- **MCP startup ≈ startup(with MCP) − startup(without MCP)**

(`duration_api_ms` is unreliable when tools are present — it exceeds `duration_ms` in the MCP scenarios — so the round-trip is taken from `duration_ms`.)

### 2.1 Per-turn latency table (milliseconds, median · min–p90)

| Scenario | wall (median) | model round-trip `dur_ms` | **process startup** `wall−dur` |
|---|---|---|---|
| **A** — `-p` cold, no resume, no MCP | 7351 · 6144–12951 | 5704 · 4389–11719 | **1703 · 1232–1951** |
| **B** — `-p --resume` warm, no MCP | 4296 · 3590–4636 | 2584 · 2140–3026 | **1542 · 1263–1891** |
| **C** — `-p` cold + stub MCP (7 tools) | 8208 · 7522–11935 | 6714 · 5435–10349 | **1902 · 1451–2161** |
| **D** — `-p --resume` warm + stub MCP | 5436 · 3610–9250 | 3250 · 2013–7203 | **1889 · 1494–2451** |
| **Real orchestrator bridge**, warm, `reply OK` (n=4) | ~4100 | ~2100 | **~1850 · 1528–2010** |
| **SDK persistent, warm per-turn** (derived) | — | ≈ round-trip only, ~2100–3000 | **~0** (amortized) |

### 2.2 The isolated quantities Allen asked for

- **Node process startup (the `-p` penalty the SDK amortizes): ~1.5–1.7 s median** (min ~1.23 s, p90 ~1.95 s), stable and low-variance.
- **MCP server spawn+handshake adds ~200–350 ms per turn** — and this holds for the **real orchestrator bridge**, not just the stub: real-bridge startup (~1.85 s median) ≈ stub startup (~1.9 s). The reason is structural: `orchestrator_bridge.py` serves `tools/list` from the local `orchestrator_tools.json` schema file, so `claude`'s init handshake does **not** block on the bridge's WebSocket backhaul to BEAM (that connect is lazy, paid only on the first `tools/call`, over loopback). **The feared "real bridge adds ~1 s to startup" did not materialize.**
- **Total `-p` per-turn overhead vs SDK persistent: ~1.5 s (no MCP) → ~1.9 s (with orchestrator MCP).**
- **Model round-trip dominates and is noisy:** warm-resume ~2.6 s median but spanning 2.0–3.4 s; cold ~5.7 s (it pays ~17 K tokens of system-prompt **cache creation**); worst observed 11.7 s. **This 2→11.7 s variance alone is ~5–7× the entire fixed startup penalty.** Warm `--resume` turns are *faster* than cold precisely because they read the prompt cache instead of creating it.

### 2.3 Capability proof (the point of the exercise)

Running `claude -p "Call the list_templates tool…" --mcp-config /home/ezagent/.ezagent/cc-orchestrator/orchestrator.mcp.json --strict-mcp-config --dangerously-skip-permissions`:
- The orchestrator MCP server **started**, `tools/list` succeeded, and `claude` **selected and invoked `list_templates`** (`num_turns=3`, `is_error:false`).
- The call reached the bridge, which returned `tool call failed: WS not connected` — i.e. the *only* failure was the bridge's WebSocket backhaul to the in-BEAM `Ezagent.Orchestrator.McpServer`, because the throwaway config dir lacked the orchestrator agent's identity/session. **That is the same `orchestrator_bridge.py` the PTY path uses; in production, launched as the real orchestrator agent, the WS connects.** It is an identity/wiring concern **independent of the runtime choice**.

This demonstrates end-to-end that `-p --mcp-config` reads the on-disk orchestrator config and dispatches its tools — the exact capability cc-headless lacks today.

---

## 3. Resource footprint (measured RSS)

| | idle (M agents) | active turn | supervision surface |
|---|---|---|---|
| **SDK persistent** | **M × ~215–240 MB** (200 MB `claude` node + 15–40 MB Python worker), held forever | same (already resident) | M supervised OS process groups (`uv → python → claude` node) to restart / reap / leak-guard |
| **`claude -p`** | **0** | ~200 MB × (concurrently active turns) — transient, freed on turn exit | stateless spawn; no long-lived supervision. Cost moves to `--resume` session-file storage + per-turn spawn latency |

Measured in-container: live PTY `claude` nodes RSS = **195 MB** (pid 259) and **203 MB** (pid 4305); py-agents = uv (~9.6 MB) + python (~6.9 MB). A cc-headless SDK sidecar is a Python SDK worker that itself keeps a `claude` node alive, so ~200 MB+ resident per agent is the dominant term. For M=10 agents, the SDK path holds **~2.1–2.4 GB resident at idle**; `-p` holds **0**, peaking at ~200 MB × (simultaneous replies).

---

## 4. Trade-off summary

| Axis | SDK persistent | `claude -p --resume [--mcp-config]` |
|---|---|---|
| **Per-turn latency** | round-trip only (~2.6 s warm) | round-trip + ~1.5–1.9 s startup |
| **MCP / persona correctness** | **broken today**; needs a build: convert on-disk `orchestrator.mcp.json` → inline `mcp_servers` map + thread persona `system_prompt` into the template (duplicating what the on-disk config already expresses) | **works out-of-the-box**; reuses on-disk `orchestrator.mcp.json` / `.mcp.json` / settings / CLAUDE.md — **proven** to load + fire tools |
| **Idle memory (M agents)** | ~215–240 MB × M, forever | 0 |
| **Peak memory** | ~215–240 MB × M | ~200 MB × concurrent active turns |
| **Lifecycle / ops** | supervise, restart, leak-reap M process groups; orphan reaper already needed | stateless spawn; must manage `--resume` session storage + accept per-turn spawn latency |
| **Amortization win** | avoids ~1.9 s startup + per-turn MCP re-spawn | pays ~1.9 s startup + lazy loopback WS re-connect per turn |

The SDK's amortization win (~1.9 s/turn) is real but small against a 2–11 s, high-variance model turn, and it is bought with (a) an inline MCP/persona re-wiring build cc-headless doesn't have, and (b) ~215 MB × M resident idle memory + M supervised process groups. `-p` trades that for a fixed, low-variance ~1.9 s and near-zero idle cost.

---

## 5. Recommendation

### (a) Orchestrator — needs the 7-tool MCP surface **now**
Use **`claude -p --mcp-config <orchestrator.mcp.json> --resume <session_id> --dangerously-skip-permissions`** (plus the mandatory `--settings` safety file and the esr-bridge `--mcp-config`, exactly as `spawn_plan.assemble_settings_mcp_args/3` already assembles for the PTY path). It reads the on-disk `orchestrator.mcp.json` the seed already generates (`cc_orchestrator_seed.ex orchestrator_mcp_json/1`) and the on-disk persona — **no SDK inline `mcp_servers`/`system_prompt` build**. Measured per-turn overhead ~1.9 s, dominated by and dwarfed by model latency. This unblocks the orchestrator migration immediately.

### (b) General default cc-headless agents
Same `-p --resume` runtime, with only their existing esr-bridge `.mcp.json` (no orchestrator MCP). Per-turn overhead ~1.5 s. Removes the need to keep the SDK worker's inline threading working, and removes ~215 MB × M idle memory. If a specific high-frequency agent ever proves startup-sensitive (many short turns/second where the fixed ~1.5 s hurts), keep the SDK path as an opt-in for *that* agent and do the inline-wiring build only then — but that is not the common case.

**Do not** invest in the SDK inline MCP-wiring build for the orchestrator: it re-expresses config that already exists on disk, and the runtime that reads that on-disk config directly is both shorter and already proven.

---

## 6. Migration plan

### Phase 0 — pin behavior with a test (before touching runtime)
1. Add a fast unit/integration test asserting the cc-headless deliver path can round-trip a turn and that, given an on-disk `--mcp-config`, an MCP tool is *available* to the model. (Reproduces the current "no MCP tools" gap as a failing test first.)

### Phase 1 — new headless runtime module (orchestrator first)
2. Add `EzagentPluginCc.HeadlessRuntime` (a new module beside `SdkSidecar`) that builds and runs `claude -p` per turn via `Ezagent.Runtime.OsProcess` (same erlexec/process-group discipline the SDK sidecar uses for clean teardown). Args: `["-p", text, "--output-format", "json", "--resume", session_id] ++ assemble_settings_mcp_args(...) ++ ["--dangerously-skip-permissions"]`, `cd: cwd`, `env: cmd_env`, `CLAUDE_CONFIG_DIR: config_dir`. Parse the JSON result (`result`, `session_id`, `usage`) — reuse `normalize_result/normalize_usage` shapes from `SdkSidecar`.
3. Session continuity: capture `session_id` from the first turn's JSON and persist it on the agent's session meta (`meta["claude_session_id"]`, already read by `CcHeadlessBridgeAdapter.session_id_from_payload/1`); pass it as `--resume` on subsequent turns. Sessions live under `CLAUDE_CONFIG_DIR/projects/...` — add a reaper/TTL for stale session files (the one genuinely new lifecycle concern).
4. Point `CcHeadlessBridgeAdapter.deliver/2` at `HeadlessRuntime.query/3` instead of `SdkSidecar.query/3` (keep the adapter's `:in_process_sync` transport class and `:sync_result` re-dispatch unchanged). Gate behind a template/flavor flag so rollout is per-agent.
5. Orchestrator wiring: ensure the orchestrator's template carries `operator_mcp_config_path = orchestrator.mcp.json` (already generated by the seed) so `assemble_settings_mcp_args/3` includes it. No inline `mcp_servers` needed.

### Phase 2 — default agents
6. Flip default cc-headless agents to `HeadlessRuntime` (esr-bridge `.mcp.json` only). Remove/retire `ensure_sdk_sidecar` from the cc-headless spawn path once no flavor depends on it; delete the now-dead inline `mcp_servers`/`system_prompt` env plumbing in `sdk_sidecar_params/2` if nothing else uses it. Keep `SdkSidecar` in-tree only if an opt-in high-frequency agent needs it.

### Test plan
- **Unit:** args assembly (settings + both `--mcp-config` + `--resume` + skip-permissions ordering), JSON result parsing (success, `is_error`, tool-attempt turns), session-id capture/reuse, stale-session reaping.
- **Integration:** deliver → `-p` spawn → `:sync_result` persistence → session reply, with a stub stdio MCP asserting a `mcp__*` tool is listed to the model.
- **Regression:** the Phase-0 "MCP tool available" test now passes.

### Canary verification (acceptance — must be demonstrated, not assumed)
- On `ezagent-nightly`, launch the **real** orchestrator agent on `HeadlessRuntime` and `@orchestrator` it with a task that requires a tool (e.g. "list the templates"). **Accept only when the orchestrator's reply reflects an actual tool result** — i.e. the `orchestrator_bridge.py` WS backhaul to `Ezagent.Orchestrator.McpServer` connects **under the real orchestrator identity** and `list_templates` returns real data (the one thing the throwaway measurement could not prove: it fired the tool but the bridge's WS wasn't connected for an unidentified caller). This is the explicit go/no-go gate.
- Confirm idle memory drop (no resident per-agent `claude` node between turns) and per-turn wall latency in line with §2 (~4–5 s warm).

---

## Appendix — raw measurements
32 timed `-p` runs (A/B/C/D, n=8 each) plus 4 real-orchestrator-bridge runs and 1 tool-firing capability run, captured 2026-07-10 in `ezagent-nightly-ezagent-1`. Startup = `wall − duration_ms`. RSS from `ps -eo rss`. Throwaway `CLAUDE_CONFIG_DIR` (host OAuth) removed after the run.
