# T1 — AutoService Current-Architecture E2E Verify — 2026-06-30

**Owner:** gaga · **Task:** `T1-autoservice-current-arch-e2e` · **Branch:** `verify/autoservice-current-arch-e2e` · **Base:** `origin/main` `d8ffd6c0`
**Stack:** local disposable — **local PostgreSQL on 55432** (the docker-compose.pg.yml convention port; no docker on this box), isolated DB `ezagent_autosvc_t1`, `EZAGENT_HOME=/tmp/ezagent_autosvc_t1`, Phoenix `PORT=10042`.
**Agent model:** Sonnet 4.6 (forced via `ANTHROPIC_MODEL=claude-sonnet-4-6` — inherited by the spawned cc PTY, **no code change**).

---

## Verdict

**Can the current architecture complete the AutoService flow?**

- **Infrastructure / plumbing: YES — green end-to-end.** Every reliability primitive + transport works: cc orchestrator materialization (#1096), isolated login, agent-bridge, ReadyGate, routing, agent reply, reply store + route-back. **kb_query retrieves `ZEPHYR-7731` at the tool level on this run's DB.**
- **Answer-soul (the agent autonomously retrieves + quotes `ZEPHYR-7731` to the customer): NO — blocked at the agent-wiring layer, not the architecture.**

**Four** exact, operational blockers were found (A bridge-port, B persona, C registration, D session↔orchestrator binding) — none is a core-architecture redesign. B and C were fixed + verified in the seed; the chain of B→C→D shows the seed's shortcut materialization should be replaced by the real session-create orchestrator flow (see "Seed fix attempt" below).

This run also resolves the 2026-06-29 carry-forward (the real answer-loop, gated on cc auth). cc auth was solved (cred injection); doing so **exposed a chain of seed-wiring blockers (bridge port → orchestrator persona → orchestrator registration) that the "not logged in" symptom was masking.**

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

## ⛔ Blocker C — the AutoService agent is never registered as an orchestrator → `kb_query`-over-MCP fails

Surfaced by the verification below (once the agent actually *tries* to query the kb). When the agent's claude calls `kb_query` via the `esr-orchestrator` MCP server, the orchestrator MCP channel rejects the join **fail-closed**:

```
Ezagent.Orchestrator.McpChannel: entity://autosvc/agent/autoservice authenticated
but is NOT a registered orchestrator (:orchestrator_not_registered) — join rejected
```

`Orchestrator.McpRegistry.register/2` is the ETS row the channel checks. It is normally written by the **session-create orchestrator flow** (`entity/session/orchestrator.ex`, `orchestrator_admin.ex`) after the session spawns its orchestrator. The seed materializes the AutoService agent via `spawn_from_template_content` directly and **never calls `McpRegistry.register`** — so all 7 orchestrator tools (incl. `kb_query`) fail with a 500 at the channel join. (The in-node `Orchestrator.Tools.kb_query` proof above works precisely because it bypasses the MCP channel + its registration gate.)

**Fix (operational):** the seed must `McpRegistry.register(autosvc_uri, session_uri:, workspace_uri:, owner_uri:)` after spawning the agent (re-registered each boot — the registry is in-memory ETS).

---

## Verification — is it the "soul" framing or the wiring? → **wiring, decisively**

To isolate Blocker B's cause, a minimal **support-agent persona** was injected into the agent's own `CLAUDE.md` (cwd): *"you are tier-1 support; the kb agent is `kb-tier1`; call `kb_query` for support questions"* — **wiring only, no reframing of the corpus fact**. Then the **same natural question that deflected in Test 1** was sent.

| | no persona (Test 1) | with support persona |
|---|---|---|
| queries the kb? | ❌ deflects "I don't have access", never queries | ✅ "Let me look that up in the knowledge base" |
| query behaviour | — | calls `kb_query` against **`kb-tier1`** with correct terms, retries 3× |
| on tool failure | — | correctly tells the customer there's a temporary issue, **does not fabricate** a code |

**Conclusion:** the soul-framing was **not** the reason the agent doesn't query the kb — the **wiring (persona/context) was**. A natural question never reaches the safety layer. The persona fix flipped the behaviour immediately, and in doing so exposed **Blocker C** (the `:orchestrator_not_registered` 500). The full causal chain — all seed/wiring, zero core architecture:

1. **No support persona** → agent doesn't try (deflects / flails).
2. **Even with persona** → `kb_query`-over-MCP rejected (`:orchestrator_not_registered`) — Blocker C.
3. **(secondary)** the "secret access code" framing trips Claude's safety only on explicit, exfiltration-shaped phrasing.

---

## Seed fix attempt + ⛔ Blocker D (the shortcut keeps diverging from the real flow)

`scripts/autoservice_tier1_seed.exs` was patched (verified on a fresh DB+HOME run):

- **Blocker B fix — support persona:** the seed now writes a tier-1 support-agent `CLAUDE.md` (kb agent = `kb-tier1`, use `kb_query`) into the agent cwd before the PTY launches. **Verified working** — the agent reliably queries `kb-tier1` for a *natural* question (no more deflect/flail).
- **Blocker C fix — orchestrator registration:** the seed now calls `Orchestrator.McpRegistry.register/2`. **Verified working** — `:orchestrator_not_registered` errors drop to **0**; the MCP channel join is accepted.

But the answer-soul still does not complete — a **fourth** gap surfaces once the join is accepted. The agent itself reported it: *"the `kb_query` call failed with a session context error."* `McpServer.resolve_session/1` reverse-resolves the session from the orchestrator URI via `stored_orchestrator_uri/1`, which reads the **session's** chat-slice `working_copy.orchestrator_uri`. The seed creates the session and the agent **separately** and never sets the session→orchestrator pointer — so `resolve_session` returns `:error` → *"Orchestrator session context could not be resolved."*

**The pattern is the finding:** the seed materializes the orchestrator via the `spawn_from_template_content` **shortcut**, and each fix (port → persona → registration → session binding → …) just uncovers the next binding the **real session-create orchestrator flow** (`Ezagent.Entity.Session.spawn_from_template/2` + the Generator) does atomically. Piecemeal patching is whack-a-mole.

**Recommendation (discuss-first):** stop patching the shortcut and materialize the AutoService agent through the **real session-create orchestrator flow** (which spawns + registers + binds the session↔orchestrator pair + sets the chat slice in one path). The persona write stays useful either way. — **needs Allen's call.**

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
