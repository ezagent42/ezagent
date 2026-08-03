# Orchestrator tool-orchestration → a general Session-Config domain API, one thin caller per surface

> **Status:** SPEC (architecture-level, pre-implementation). For lead approval, then codex
> adversarial review, then codex implementation. This doc specs the seam + phased design; it
> does **not** implement and does **not** relitigate Allen's principle.
> **Baseline:** `main`-line tree at `chore/ci-tier-fullsuite-off-pr` (post-#1294, post-R2/R3
> landing). **All file:line grounded on the checked-out tree; the code wins.**
> **Guiding principle (Allen):** the tool capabilities are **ezagent domain functions**; MCP —
> and the orchestrator LLM that speaks it — is just **ONE thin caller**. The domain API is the
> home of the capability; every surface (LLM/MCP, CLI, HTTP, UI) is a peer adapter that resolves
> its own authenticated principal's caps and calls the same domain function.
> **Design inputs (design, not re-derived here):**
> - `docs/notes/2026-06-15-live-orchestrator-mcp-registration-bug.md` (the original live registration bug + the readiness↔binding chicken-and-egg)
> - `docs/notes/2026-07-10-session-agent-coupling-and-dev-cred-seed.md` (R1–R5 coupling; PR-Q1a/Q1b/Q1d follow-ups)
> **Read before implementing:** `.claude/skills/ezagent-developer/references/capbac.md`,
> `.claude/skills/ezagent-developer/references/architecture-invariants.md` (register/lookup
> key-parity; CapCheckOnlyAtChokepoint; three-tier boundaries).

---

## 0. Problem & principle

The orchestrator "13 tools" look like a bespoke capability that lives inside the cc MCP plugin.
They are not — and Allen's principle says they must not be. A capability like "add a member",
"define a routing rule", "snapshot this session as a template", "ingest into the session KB" is
a **general Session-Config operation** that any authenticated principal (a human via UI/CLI, an
external caller via HTTP, or the orchestrator LLM via MCP) has an equal claim to invoke, gated by
the same CapBAC chokepoint. Naming that surface `Ezagent.Orchestrator.Tools` and reaching it only
through the cc MCP transport is a **misplaced home**: it hides a general domain API behind one
caller and starves the other three surfaces.

**The premise is ~80% already met — but for the wrong-looking reason, and with three real gaps.**
The good news, verified on the tree: MCP does **not** directly operate ezagent. Both LLM transports
converge on ONE flavor-agnostic executor (`SessionManager.run_tool`), and codex reaches it with **no
MCP at all**. So executor consolidation is essentially done. The gaps are (i) the domain API is
**named after the orchestrator**, hiding that it is a general session-config API; (ii) there is **~zero
CLI** for it; (iii) there is **zero HTTP/API** for it; (iv) the **UI is inconsistent** (one tool
reaches the domain facade; routing reaches the raw primitive instead); and (v) a **cold-restart
registration bug** keyed on a dead field silently breaks the orchestrator tool surface after every
BEAM restart.

This SPEC (a) states the current architecture precisely so the "one thin caller" claim is auditable,
(b) pins the registration root-cause as a **register/lookup key-parity** failure and specifies its
fix, and (c) lays out a three-phase design: unblock → rename+consolidate → first-class surfaces.

---

## 1. Current architecture — two seams and one shared executor

### 1.1 The two load-bearing seams

| Seam | What it is | Home (tier) | Authz |
|---|---|---|---|
| **S1 — raw Session-Kind dispatchable actions** | `routing.add_rule`, `session.join`/`leave`/`set_legends`/`set_prompt_templates`/`set_working_copy`, the template verbs, kb — the CapBAC-gated **primitive** operations on the Session Kind. | Session Kind (domain) | The Session **dispatch chokepoint** — the true CapBAC gate. `ctx.caps` is the authorizer; missing cap ⇒ fail-closed `:unauthorized`. |
| **S2 — the orchestrator-semantics facade** | `Ezagent.Orchestrator.Tools.*` — the cross-Kind facade that adds the *semantics* on top of S1: `role_name → URI` resolution, rule-set grouping, the spawn+join+cleanup envelope, `{body}` prompt-template validation, DefinitionSync. This is the "13 capabilities" surface. | `ezagent_domain_session` (domain) | Delegates every write to S1 dispatches carrying the caller's caps — invents **no new cap shape** (moduledoc "reuse existing authz"). |

Between the LLM transports and S2 sits a **thin adapter**, not a third seam:

- **`SessionManager.run_tool/4`** (`ezagent_domain_session`) — the flavor-agnostic executor. It
  adds exactly two things the tokenless LLM transports need: **bridge-token authentication** (the
  unforgeable Step-0 gate) and **session-side cap reconstruction** (it re-reads the orchestrator's
  delegated caps from identity, because the LLM transport cannot carry them). Then it calls S2 with
  those reconstructed caps. It is an **adapter over S2**, invents no capability, and is where a UI/CLI/
  HTTP caller does **not** go (those carry their own authenticated principal + caps and call S2
  directly).

### 1.2 Both LLM transports converge on the one executor

```
cc:    McpChannel.join("orch:bridge:…")   ← registry-GATED (fail-closed)
         → McpServer.handle_tool_call      ← decode/lookup/encode (MCP shape)
           → SessionManager.run_tool ───────┐
                                             ├─→ Orchestrator.Tools.<tool>  (S2)
codex: bridge_adapter handle_client_event    │      → Session dispatch chokepoint (S1 = the CapBAC gate)
         "run_tool" → SessionManager.run_tool ┘   (NO MCP, NO registry, bridge-token authz only)
```

The codex path is the existence proof that **MCP + McpRegistry are not authz**: codex reaches the
identical executor with no MCP server, no `McpChannel`, and no registry gate. The authz is
`run_tool`'s bridge-token check followed by the S1 chokepoint — unchanged across transports.
`McpRegistry`/`McpChannel` are **cc-only readiness/context machinery**.

### 1.3 Surface inventory — the 13 tools × the four surfaces

Source of truth for the tool set is the **ToolCatalog** (13 tools). The `Orchestrator.Tools`
moduledoc table (9 rows) and the `McpServer` "7/9 tool names" strings are **stale** and must be
corrected (P1).

| Capability (ToolCatalog) | LLM/MCP (cc + codex) | UI | CLI | HTTP/API |
|---|:--:|:--:|:--:|:--:|
| `add_managed_member` | ✅ | ✗ | ✗ | ✗ |
| `add_participant` | ✅ | ✗ | partial¹ | ✗ |
| `update_member_template` | ✅ | ✗ | ✗ | ✗ |
| `remove_member` | ✅ | ✗ | partial¹ | ✗ |
| `define_rule_set_rule` | ✅ | ⚠ raw² | ✗ | ✗ |
| `define_prompt_template` | ✅ | ✗ | ✗ | ✗ |
| `define_legend` | ✅ | ✗ | ✗ | ✗ |
| `update_template` | ✅ | ✗ | ✗ | ✗ |
| `save_template_as` | ✅ | ✅³ | ✗ | ✗ |
| `migrate_session` | ✅ | ✗ | partial¹ | ✗ |
| `list_templates` | ✅ | ✗ | ✗ | ✗ |
| `kb_query` | ✅ | ✗ | ✗ | ✗ |
| `kb_ingest` | ✅ | ✗ | ✗ | ✗ |

¹ Existing `mix ezagent.session.*` tasks (`list_participants`, `remove_participant`,
`migrate_grants`, `migrate_slice`) touch the same *area* but are ad-hoc, **do not route through S2**,
and do not cover the capability with the orchestrator semantics. `mix ezagent.routing.add_rule`
(cited in stale docs) **does not exist**.
² The routing UI reaches the **raw S1 action** (a `:add_rule` session-routing dispatch), **not** the
S2 tool — so it bypasses role_name→URI resolution + rule-set grouping. Inconsistent with ³.
³ `save_template_as` is the **only** capability the UI reaches through S2. This is the shape every
surface should follow.

**Reading of the table:** the LLM column is complete; the other three are almost empty, and the two
UI cells disagree on whether to go through S2. The work is to make S2 a first-class, named domain API
and give every surface a thin adapter to it — following the one ✅ (`save_template_as`) as the pattern.

---

## 2. Registration root-cause — a register/lookup key-parity failure

### 2.1 Symptom

After **any** BEAM restart, an orchestrator's MCP tool surface can never recover: the cc
`McpChannel.join("orch:bridge:…")` is rejected `:orchestrator_not_registered` (fail-closed), so the
13 tools are unreachable. Chat delivery still works (two-signal readiness); only the orchestrator tool
surface is dead. **Blast radius = every orchestrator on every cold restart**, not a socialware-vs-classic
edge. (The chat path and the codex path are unaffected — codex has no registry gate.)

### 2.2 Root cause — the reader was never re-keyed after the writer changed

The cc `McpServer` recovers a cold orchestrator by reading the session's **durable working copy** and
confirming it belongs to the connecting orchestrator (`rebuild_from_durable` → `resolve_session` →
`stored_orchestrator_uri`, both funnelled through a single guard predicate,
`orchestrator_working_copy/1`). That guard gates on the presence of **`:orchestrator_template_uri`**.

But `:orchestrator_template_uri` is a **dead field**:

- Its **only** writer, `Materializer.materialize_orchestrator_working_copy/3`, has **zero production
  callers** (only a test + two *stale docstrings* that still describe a long-gone "step 4" write).
- The **live** create/repair writer, `materialize_template_declaration/3`, explicitly
  `Map.drop([:orchestrator_template_uri, :orchestrator_uri])` — it never writes the field the reader
  waits for.
- The binding the rebuild path *actually consumes* is **`:orchestrator_uri`** (plus `:session_template_uri`
  + `:owner_uri`), and `:orchestrator_uri` **is** now written eagerly (see §2.3).

So the reader's guard is checking a field nobody writes, while the field it needs is present. This is
a classic **register/lookup key-parity** failure: a refactor (the chat→session baseization) swapped the
working-copy **writer** to `materialize_template_declaration/3` (which drops the field) and the R2 fix
started writing **`:orchestrator_uri`** — but **nobody re-keyed the reader's guard**. The stale
docstrings are the fingerprint that the reader side was never audited. `McpRegistry` is in-memory, so
this only manifests after a restart empties ETS and forces the durable rebuild.

### 2.3 Landed vs. remaining — do NOT re-do done work

The original follow-up plan (2026-07-10 note) prescribed three P1 changes. **Two already landed** on
this baseline; the SPEC's approved P1 is the small remaining one:

| Item | Status | Evidence |
|---|---|---|
| **R2** — write `:orchestrator_uri` eagerly with the *actual* spawned URI, before any grant | **LANDED** | `store_orchestrator_uri` is called from `maybe_after_materialize`; the orphaned writer was revived to write the real UUID URI. |
| **R3** — reorder so store + `register_orchestrator_mcp_context` run **before** the blocking grant | **LANDED** | `maybe_after_materialize` now runs store → register → grant, in that order. |
| **The reader guard** — recover from the durable binding after a cold restart | **BROKEN** | `orchestrator_working_copy/1` still gates on the dead `:orchestrator_template_uri`; the rebuild fails ⇒ `:orchestrator_not_registered`. |

### 2.4 Fix (design)

Two changes, both key-parity hygiene, plus cleanup:

1. **Re-key the reader guard** to the field that is actually written and actually consumed:
   `orchestrator_working_copy/1` must gate on **`:orchestrator_uri`** (not `:orchestrator_template_uri`).
   With R2 landed, this alone makes cold-restart recovery succeed on the nominal fresh path.
2. **Stop the live writer dropping the live binding.** `materialize_template_declaration/3` drops both
   the dead `:orchestrator_template_uri` (harmless) **and** the live `:orchestrator_uri` (hazardous).
   On the **repair** path it drops-then-relies-on-a-later-re-store within the same transaction
   (`materialize_template_team → materialize_definition_agents → maybe_after_materialize →
   store_orchestrator_uri`); a mid-transaction failure after the drop **orphans a previously-valid
   binding** — strictly worse than before. The design fix: drop only the dead field; never drop the
   live `:orchestrator_uri` (the store path overwrites it with the fresh URI when it re-runs, and
   preserving it means a failed re-materialize cannot orphan a working binding).
3. **Delete the dead field + its orphaned writers**, and correct the stale docs:
   - remove `materialize_orchestrator_working_copy/3` and `prestore_planned_orchestrator_uri/2`
     (zero production callers) and the `:orchestrator_template_uri` field concept;
   - fix the stale docstrings that describe the dead "step 4 OTU write";
   - fix the "7 / 9 tools" moduledocs to the **actual 13** (ToolCatalog is source of truth).
4. **Regression tests** (each fails when the goal is unmet):
   - **empty-`McpRegistry` cold-restart** — with only the durable snapshot present (ETS empty),
     `rebuild_from_durable` recovers the orchestrator tool surface from `:orchestrator_uri`;
   - **repair-path binding preservation** — a re-materialize/repair never orphans a previously-valid
     `:orchestrator_uri`;
   - **slow-bridge role still registers** — a role whose bridge binds late still ends up registered
     (guards against re-coupling registration to transport timing).

**`McpRegistry` is not authz** — this fix restores *readiness/context recovery*, nothing more. The
authz story (`run_tool` bridge-token → S1 chokepoint) is untouched.

---

## 3. Phased design

### P1 — Unblock (high priority)

Scope = §2.4 exactly: re-key the reader guard to `:orchestrator_uri`; stop
`materialize_template_declaration/3` dropping the live binding; delete the dead
`:orchestrator_template_uri` field + its orphaned writers; fix the stale "7/9 tools" moduledocs to 13
and the stale OTU docstrings; land the three regression tests. R2/R3 are already done — P1 does **not**
re-do them. This restores the orchestrator tool surface across restarts with the smallest possible
change and no new architecture.

### P2 — Rename + consolidate (make S2 a named domain API)

The direction: stop `Orchestrator.Tools` from *looking* like an orchestrator-owned capability.

- **Rename `Ezagent.Orchestrator.Tools` → a domain-neutral home** (candidate names in OQ-1, e.g.
  `Ezagent.Session.Config` / `Ezagent.Session.SessionOps`). This is a pure re-home + rename; the
  behavior (S2 semantics) is unchanged. `SessionManager.run_tool` **stays** — it remains the
  LLM-transport adapter (bridge-token + cap reconstruction) that calls the renamed module.
- **UI/CLI/HTTP call the renamed `SessionOps.*` directly** with their own authenticated principal's
  caps — never through `run_tool` (which is only for the tokenless LLM transports).
- **Fix the routing UI** to go through S2 (`define_rule_set_rule`), not the raw S1 `:add_rule`
  dispatch — closing the UI inconsistency (make the ⚠ cell a ✅, matching `save_template_as`).
- **Evaluate converging cc's MCP stack toward the leaner codex model.** codex proves the minimal
  shape works: direct `run_tool`, bridge-token authz, **no registry gate**. The design question
  (OQ-2) is whether to retire `McpRegistry`/`McpChannel`'s registration gate entirely — folding its
  *readiness/context* role into `LiveJoinRegistry` + the durable `:orchestrator_uri` binding (which
  P1 makes authoritative) — so cc looks like codex. If retired, the P1 reader-guard bug class
  disappears by construction (no registry gate to key wrong). P2 **specifies the evaluation +
  decision**; the retirement itself is gated on OQ-2's answer.

### P3 — First-class surfaces (CLI + HTTP) + decouple the install lane

- **CLI:** one `mix ezagent.session.<verb>` task per capability, each a thin adapter over
  `SessionOps.*`: `add_member`, `define_rule`, `define_legend`, `define_prompt_template`,
  `save_template_as`, `migrate`, `list_templates`, `kb_query`, `kb_ingest` (align the pre-existing
  `list_participants`/`remove_participant` with the same surface). The open question is the **operator
  principal + caps** these tasks run as (OQ-3).
- **HTTP:** `ezagent_plugin_protocol_api` endpoints for the 13, each resolving an **API-token →
  principal → caps** and calling `SessionOps.*`. The token→caps authz story is OQ-3. (Today
  `protocol_api` is OpenAI-chat-completions shaped — a *conversation* surface — with **no**
  session-config endpoints.)
- **Kill the blocking `:call` / `:activate_timeout` coupling (PR-Q1a).** Move recipe + orchestrator
  scoped caps into the agent's **own `create/1`** transaction, deleting the cross-transaction blocking
  `grant_recipe_caps` `:call` from the install lane (it awaits the not-yet-ready agent's `ReadyGate`
  for the 20 s activate budget vs a 50–85 s cc cold-start ⇒ `:activate_timeout` ⇒ install fails and
  `register_orchestrator_mcp_context` never runs). This makes membership + authorization one atomic
  agent transaction and removes a second, independent way the orchestrator surface fails to register.
- **Extend the arch gate to the install lane** so "a session is durable/usable even if its agent's
  transport never joins, and the failure is loud (no rollback, no hang, no unauthorized-member)" is
  non-regressable — the create-time gate does not reach the async install Task where P1/PR-Q1a live.

---

## 4. Invariants (normative)

- **I1 — One capability home.** A Session-Config capability lives **once**, in the `SessionOps`
  domain module (S2). MCP/CLI/HTTP/UI are **callers**, never alternate homes. No surface may
  reimplement a capability or invent a cap shape. *(Gate: forbid Session-Config capability logic —
  role_name→URI resolution, rule-set grouping, spawn+join envelope — outside the `SessionOps` module;
  surfaces may only call it.)*
- **I2 — MCP/LLM is one caller.** The LLM transports reach S2 only through
  `SessionManager.run_tool` (bridge-token + cap reconstruction). No LLM transport calls S1 or a Kind
  action directly; no non-LLM surface routes through `run_tool`.
- **I3 — Authz is the S1 dispatch chokepoint, unchanged.** Every write, from every surface, is CapBAC-
  gated at the Session dispatch chokepoint with the **caller's** caps; missing cap ⇒ fail-closed. No
  surface may pass ambient/system authority in lieu of the principal's caps (the `system_internal`
  marker stays confined to its existing working-copy-write site).
- **I4 — `McpRegistry` ≠ authz.** Registration is readiness/context recovery only. The codex path
  (registry-free) and the cc path must be authz-equivalent. A missing/empty registry may degrade
  *readiness*, never *authorization*.
- **I5 — Register/lookup key parity.** Any change to the durable working-copy binding must update the
  **reader** guard and the **writer** in the same change; a durable binding is read on the exact key it
  is written. *(This is the invariant the §2 bug violated; its regression tests are the gate.)*

---

## 5. Open Questions for Allen

- **OQ-1 — the domain-neutral rename target.** `Ezagent.Session.Config`, `Ezagent.Session.SessionOps`,
  or another name? (The module is the general session-config facade; the name should say "session ops",
  not "orchestrator".)
- **OQ-2 — retire cc's MCP registry gate in favor of the codex model?** Fully? Fold its readiness/
  context role into `LiveJoinRegistry` + the durable `:orchestrator_uri` binding and make cc look like
  codex (bridge-token-only, no registration gate)? Or keep the gate and only fix the key (P1)? Full
  retirement removes the P1 bug class by construction but is a larger cc-transport change.
- **OQ-3 — CLI + HTTP authz stories.** (a) What **operator principal + caps** do the `mix
  ezagent.session.*` tasks run as (a named operator identity, or the session owner)? (b) How does an
  HTTP **API-token map to a principal + caps** for the session-config endpoints? Both must resolve to a
  real caller whose caps the S1 chokepoint checks — no ambient authority.
- **OQ-4 — `:orchestrator_uri` binding lifecycle across repair.** P1 stops
  `materialize_template_declaration/3` dropping the live binding; do we also want an explicit
  invariant/tombstone policy for the binding on definitive spawn/join failure (so the durable
  `:orchestrator_uri` is never left pointing at an orchestrator that will never come up)?

---

## 6. Impl-constraints (non-normative — file:line grounded on the checked-out tree; the code wins)

These are demoted from the design body so codex reviews *architecture*, not line numbers. They anchor
the design to the tree for the implementer; verify each before editing.

- **The reader guard (P1 core):** `Ezagent.Orchestrator.McpServer.orchestrator_working_copy/1`
  (`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex:267`) gates on
  `:orchestrator_template_uri`; re-key to `:orchestrator_uri`. Consumers: `rebuild_from_durable/1`
  (`:146`), `stored_orchestrator_uri/1` (`:238`) — both funnel through this guard.
- **The live writer that drops the live binding:** `SessionCreator.Materializer.materialize_template_declaration/3`
  (`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex:29`)
  does `Map.drop([:orchestrator_template_uri, :orchestrator_uri])` — drop only the dead field. Call
  sites: `session_creator.ex:573` (`do_repair_orchestrator/2`, the hazardous re-store window) and
  `:852` (`finalize_fresh_session`, fresh path — async install re-stores).
- **Orphaned writers to delete:** `materialize_orchestrator_working_copy/3`
  (`materializer.ex:10`, zero prod callers — test + stale docstrings only) and
  `prestore_planned_orchestrator_uri/2` (`materializer.ex:93`).
- **The eager `:orchestrator_uri` writer (R2, LANDED — keep):** `store_session_orchestrator_uri/2`
  (`materializer.ex:53`) called via `DefinitionAgents.store_orchestrator_uri/2`
  (`definition_agents.ex:318/345`).
- **The reorder (R3, LANDED — keep):** `DefinitionAgents.maybe_after_materialize/5`
  (`definition_agents.ex:310`) runs store → `register_orchestrator_mcp_context` → grant.
- **Stale docs to fix:** the "7/9 tools" strings in `mcp_server.ex` (moduledoc `:4`/`:12`, `tool_names`
  doc `:307`) and the `Orchestrator.Tools` moduledoc 9-row table
  (`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex`) — actual set is the 13-entry
  ToolCatalog (`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex`); plus the
  stale OTU docstrings at `config_actions.ex:105-120` and `session_creator.ex:485-495`.
- **The executor + authz (S2 adapter):** `SessionManager.run_tool/4`
  (`apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex:258` → `run/4` `:285`:
  Step-0 bridge-token verify → structural check → `load_orchestrator_caps` → `run_tool_op`).
- **The codex existence proof:** `plugin_codex/bridge_adapter.ex` `handle_client_event("run_tool", …)`
  (`:50`) → `call_session_manager` (`:153`) → `SessionManager.run_tool` — no MCP, no registry.
- **The UI callers:** `save_template_as` → `Ezagent.Orchestrator.Tools.Templates.save_template_as`
  (`apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex:396`, the ✅ pattern); routing
  → raw `dispatch_session_routing(…, :add_rule, …)` (`conversation_actions.ex:688`, the ⚠ to fix).
- **The blocking `:call` (P3/PR-Q1a):** `DefinitionAgents.grant_recipe_caps/2`
  (`definition_agents.ex:252/550`) — the cross-transaction `:call` that awaits the fresh agent's
  `ReadyGate` (20 s activate budget) and can `:activate_timeout` before `register_orchestrator_mcp_context`.

---

## 7. Staged PR plan

| PR | Phase | Scope | Gate / acceptance |
|---|---|---|---|
| **PR-1** | P1 | Re-key the reader guard to `:orchestrator_uri`; stop `materialize_template_declaration/3` dropping the live binding; delete `:orchestrator_template_uri` + its orphaned writers; fix the 7/9→13 moduledocs + stale OTU docstrings. | The three §2.4 regression tests (empty-registry cold-restart recovers; repair never orphans; slow-bridge role registers). |
| **PR-2a** | P2 | Rename `Orchestrator.Tools` → `SessionOps` (domain-neutral); keep `run_tool` as the LLM adapter; fix the routing UI to call S2. | I1/I2/I3 gates green; UI routing goes through S2 (parity with `save_template_as`). |
| **PR-2b** | P2 | *(Gated on OQ-2)* Converge cc MCP toward the codex model — fold registry readiness into `LiveJoinRegistry` + durable binding; retire the registration gate if approved. | I4 gate: cc and codex authz-equivalent; readiness recovery preserved. |
| **PR-3a** | P3 | CLI `mix ezagent.session.<verb>` tasks over `SessionOps.*`. | *(OQ-3a)* operator-principal + caps resolved; each task CapBAC-gated at S1. |
| **PR-3b** | P3 | HTTP `protocol_api` session-config endpoints over `SessionOps.*`. | *(OQ-3b)* API-token → principal → caps; S1-gated. |
| **PR-3c** | P3 | PR-Q1a — move recipe/orchestrator caps into the agent's own `create/1`; delete the blocking install-lane `:call`; extend the arch gate to the install lane. | Install-lane invariant: session durable/usable even if the agent transport never joins; failure loud, no rollback/hang/unauthorized-member. |

P1 → P2 → P3, sequentially; P2b is conditional on OQ-2, PR-3a/3b on OQ-3.
