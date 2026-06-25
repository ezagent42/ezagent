# Leftover task triage — 2026-06-24 (self-driven, @林懿伦 AFK)

> Per "tasks 列表中遗留的任务也开独立 PR 进行修复." Each pending task triaged to: **fixed via PR** / **already done** / **blocked (with reason)** / **Allen's call** / **ready but clarify-first (not blind-built at night)**. The guiding constraint is the dev-together process just ratified: core / CapBAC / plugin-isolation / north-star changes are **clarify-first**, not unsupervised 1am refactors.

| # | Task | Disposition | Detail |
|---|---|---|---|
| **#55** | Code comment-coverage audit + moduledoc/fn-doc **enforcement test** | ✅ **DONE** (no PR) | The enforcement already exists on `main`: `mix ezagent.doc.scan` + `apps/ezagent_core/test/architecture/doc_coverage_test.exs` + arch baseline caps (`undocumented_public_modules: 0`, `undocumented_public_defs: 392`). The durable deliverable (the gate) is in place; the comment-coverage **burn-down** is the ongoing codex off-plan batch. Mark complete. |
| **#88** | Inbound email channel (ezagent.chat) via external-adapter #82 | ⛔ **BLOCKED → next cycle** | A whole feature, depends on the #82 external-adapter family + a public inbound MX/route design. Not a 1am PR. Needs a clarify-first cycle (research the inbound path + DoD) — flagged, not blind-built. |
| **#93** | Cap-gate agent-config **READS** when the world `agents.config.read` action is wired | ⛔ **BLOCKED on wiring** | The read cap-gate backend is DONE (#943). The remaining half fires only when the **console→facade `agents.config.*` action is wired** — and the #938 audit confirmed that wiring is NOT open on `main` yet (it's #958/agent-console territory). Blocked until that lands; nothing to PR now. |
| **#96** | Decide Protocol API naming/split | 🧑‍⚖️ **Allen's** | "Allen to analyze gaga's evaluation in #952." A decision, not a build. Left for Allen. |
| **#97** | Decide/implement sidecar lifecycle governance | 🧑‍⚖️ **Allen's** | "Allen to analyze gaga's plan in #952." Decision-first. Left for Allen. |
| **#99** | Migrate hello/protocol_api/world plugins onto `LocalRuntime` | 📋 **READY (inventory done) — clarify-first, not built tonight** | Call-site inventory complete (below). It's a clean URI-only migration BUT touches core/owner-gating + plugin-isolation (a north-star) → **discuss-first trigger** → per the new process it is clarify-first, not an unsupervised night refactor of agent-spawning (high blast radius: protocol_api spawns agents for the HTTP API). Ready to execute next cycle; shares the LocalRuntime-args decision with #918. |

## #99 — ready-to-execute call-site inventory (origin/main)
All are **URI-only** spawn/lookup (no args/behaviors threading — unlike echo/#918), so they map cleanly:
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/template/hello_session.ex:41` — `KindRegistry.lookup(session_uri) == :error` → `not LocalRuntime.kind_alive?(session_uri)`.
- `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex:53,90` — `SpawnRegistry.spawn(session_uri)` → `LocalRuntime.ensure_started(session_uri)`.
- `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/openai_chat_plug.ex:109` — `KindRegistry.lookup(agent_uri)` → `kind_alive?`/`ensure_started` (check exact usage).
- `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/openai_chat_plug.ex:195` — `SpawnRegistry.spawn(agent)` → `LocalRuntime.ensure_started(agent)`.
- `apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_data.ex:122,164` — `KindRegistry.lookup(ws.uri)` → `kind_alive?`.

**Then:** lower the arch caps (`spawn_registry_call_sites` / `off_chokepoint_modules` etc.) to the new actuals (lowering is free), and confirm `LocalRuntime`'s sanctioned-files coverage. **Open question (shared with #918):** the only blocker to a fully-mechanical sweep is whether any consumer needs args-threading; these six are URI-only, so #99 itself is mechanical — the args question is #918's (echo). In single-node the `WorkspaceOwnerGate` is a no-op, so the migration is behavior-preserving; CI (full test + arch) gates it.

## Net
- Tonight's only safe build: **#966** (#938 delete_path fix).
- Genuinely actionable-by-PR-now but deferred-by-discipline: **#99** (clarify-first; inventory ready).
- Already done: **#55**.
- Blocked: **#88** (needs #82 + cycle), **#93** (needs agents.config.* wiring).
- Allen's: **#96**, **#97**.
- New backlog from the audit: **F9 / F10 / F12** (zyli's product-UI gaps).
