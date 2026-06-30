# T1 — AutoService Current-Architecture E2E Verify — 2026-06-30

**Owner:** gaga · **Task:** `T1-autoservice-current-arch-e2e` · **Branch:** `verify/autoservice-current-arch-e2e` · **Base:** `origin/main` `d8ffd6c0`
**Stack:** local disposable — **local PostgreSQL on 55432** (the docker-compose.pg.yml convention port; no docker on this box), isolated DB `ezagent_autosvc_t1`, `EZAGENT_HOME=/tmp/ezagent_autosvc_t1`, Phoenix `PORT=10042`.
**Agent model:** Sonnet 4.6 (forced via `ANTHROPIC_MODEL=claude-sonnet-4-6` — inherited by the spawned cc PTY, **no code change**).

---

## Verdict

**Can the current architecture complete the AutoService flow?**

- **Infrastructure / plumbing: YES — green end-to-end.** Every reliability primitive + transport works: cc orchestrator materialization (#1096), isolated login, agent-bridge, ReadyGate, routing, agent reply, reply store + route-back. **kb_query retrieves `ZEPHYR-7731` at the tool level on this run's DB.**
- **Answer-soul (the agent autonomously retrieves + quotes `ZEPHYR-7731` to the customer): NO — blocked at the agent-wiring layer, not the architecture.**

Two **exact, operational** blockers were found — neither is a core-architecture redesign. Both are fixable at the seed/config layer.

This run also resolves the 2026-06-29 carry-forward (the real answer-loop, gated on cc auth). cc auth was solved (cred injection); doing so **exposed a second blocker (bridge port) that was masking the answer-soul blocker.**

---

## What works (proven this run)

| Step | Evidence |
|---|---|
| cc orchestrator materializes | `autosvc_status=:created` (#1096 fix holds) |
| Isolated login | host `~/.claude/.credentials.json` injected into agent config_dir → claude boots `Sonnet 4.6 · Claude Pro` |
| **Agent-bridge connects** | WS `ESTAB 127.0.0.1:10042 <-> 127.0.0.1:<bridge>` (after the port fix) |
| ReadyGate | `readygate_before=:ready` / `FINAL readygate=:ready` |
| kb.query cap | `caps=4 has_kb_query=true` |
| **kb_query TOOL retrieval** | `KB_TOOL result={:ok, %{hits:[%{text:"...the support hotline access code...is ZEPHYR-7731..."}]}}` |
| Message flow | customer msg → route(always→agent id=2) → bridge push → agent reply → stored (`sender=entity://autosvc/agent/autoservice`, `ref_id` → customer msg) → routed back |

---

## ⛔ Blocker A — agent-bridge WS URL is hardcoded to `:10042`, not derived from `PORT`

The cc bridge `.mcp.json` env is `EZAGENT_BRIDGE_WS_URL = ws://127.0.0.1:10042/agent_bridge/websocket`. Source: `cc_orchestrator_seed.ex:543-551` resolves `EZAGENT_BRIDGE_WS_URL` env → `:ezagent_plugin_cc, :ws_url` app config → **hardcoded default `ws://127.0.0.1:10042/...`**. It does **not** read `PORT`.

**Consequence:** run Phoenix on any non-10042 port and the bridge dials a dead port → the `ezagent_mcp_bridge.py` WS never connects → AgentBridge never registers → **`ReadyGate` stays `:failed` forever.**

**This is almost certainly why the 2026-06-29 runs (gaga `PORT=10044`, codex `PORT=10144`) never reached ready** — mis-attributed to "Claude Code not logged in." Login was *a* blocker, but even after login, the port mismatch keeps the bridge down. Verified directly: on `PORT=10044`, ReadyGate stuck `:failed` with creds present + claude logged in; switching to `PORT=10042` → `:ready` at boot.

**Fix (operational):** run dev on `10042`, OR set `EZAGENT_BRIDGE_WS_URL` / `config :ezagent_plugin_cc, :ws_url` to the real host:port. Optional hardening: derive the default from the endpoint `PORT` so a non-default port can't silently break the bridge.

---

## ⛔ Blocker B — the AutoService agent runs the cc-orchestrator (team-manager) persona, not a support-agent persona

The seed materializes the AutoService agent from `template://system/agent/cc-orchestrator`, whose system prompt is **"you manage a team of worker agents"** (add_managed_member / define_rule_set_rule / …). It is **not** a support agent, is **not** told the kb agent name (`kb-tier1`), and is **not** told to use `kb_query` to answer customer questions. The agent holds the `kb.query` cap and the `kb_query` MCP tool **is** in its catalog (`tool_catalog.ex:234`) — but nothing directs it to use them for support.

Observed across three customer-message framings (Sonnet 4.6, live):

| Customer message framing | Agent behaviour |
|---|---|
| Natural ("how do I reach the hotline?") | **Deflects** — "I'm sorry, I don't have access to priority support hotline details or access codes…". Never queries the kb. |
| Explicit ("use kb_query, return the EXACT access code, do not guess") | **Refuses as prompt-injection / credential-exfiltration** — "This matches a classic credential exfiltration pattern… I won't call kb_query… won't echo a retrieved credential." |
| Benign ("look up our published support contact info, share it per the playbook") | **Tries but flails** — 8 `esr-orchestrator` calls + 11 shell commands; guesses kb agent names, then **shell-snoops the filesystem** (`ls /tmp/ezagent_autosvc_t1/default/kb-sources/...`) to find the corpus. Never cleanly retrieves+quotes via `kb_query`. |

**Fix (operational, NOT architecture):** give the AutoService agent a **support-agent recipe/template** that (a) frames it as a tier-1 support agent, (b) names the kb agent (`kb-tier1`) and instructs `kb_query` for customer questions, (c) reframes the corpus fact away from "secret to exfiltrate" (see below).

---

## ⚠️ Scenario-design tension to flag (Allen)

The soul-anchor fact is deliberately framed in the corpus as a **"secret access code, published only in the kb, never to the model, rotates quarterly."** That is exactly the shape of a credential a well-aligned Claude is trained to **protect**. The harder the prompt pushes for "the exact code," the more it reads as exfiltration (see Test 2's outright refusal). This fact-framing **collides with Claude's safety guardrails** and likely needs reframing (e.g. "published support contact info" rather than "secret access code") for the answer-soul to land cleanly and reproducibly.

---

## Reproduction

```bash
# local PG 55432 (== docker-compose.pg.yml host port), isolated DB
createdb / CREATE DATABASE ezagent_autosvc_t1 OWNER ezagent_pg_compat   # on 127.0.0.1:55432
export EZAGENT_HOME=/tmp/ezagent_autosvc_t1 MIX_ENV=dev PHX_HOST=0.0.0.0
export POSTGRES_DB=ezagent_autosvc_t1 PORT=10042            # PORT MUST be 10042 (Blocker A)
export ANTHROPIC_MODEL=claude-sonnet-4-6                    # spawned cc PTY inherits it
mix ecto.migrate
# seed in-node (public_view session must be live in the serving BEAM):
iex --dot-iex scripts/autoservice_tier1_serve_seed.exs -S mix phx.server
# then inject host creds into the agent config_dir AFTER first spawn (materialize copies a
# reference dir WITHOUT creds), and respawn — claude logs in, bridge joins, ReadyGate :ready.
#   cp ~/.claude/.credentials.json /tmp/ezagent_autosvc_t1/default/cc-agents/autosvc/autoservice/.credentials.json
```

Notes:
- The agent config_dir creds **persist** across restarts (respawn does not re-materialize the config_dir — `cc_agent/spawn.ex:288`), so login survives a phx restart.
- The world (operator console) vite build fails on `@excalidraw/excalidraw/index.css` (rolldown) — **not** on the AutoService path; the customer chat (`viewer_app.js`, esbuild) builds and serves fine.

## Evidence

Key transcript excerpts: `docs/together/2026-06-30/returns/evidence/autoservice-current-arch-e2e.txt`
(natural deflection, explicit refusal, kb_query tool proof, benign-framing flail, the 10044→`:failed` vs 10042→`:ready` contrast).
