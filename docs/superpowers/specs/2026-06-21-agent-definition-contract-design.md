# Agent Definition Contract — Design

- **Date:** 2026-06-21
- **Status:** Design (brainstormed with Allen; awaiting spec review → writing-plans)
- **Owner:** Allen
- **Driving scenario:** the autoservice customer-service vertical (导购 / 内部流程 / OA bots)
- **References studied:** Flue (`withastro/flue`, `createAgent({...})`), Cloudflare Agents-SDK three-layer post, Databricks Omnigent (`omnigent-ai/omnigent`, YAML manifest + `executor.harness`), and the in-repo `autoservice-dev` branch (soul / slot / SoulRenderer / CR / release).

---

## 0. Review altitude (read first)

These are **design specs**, to be judged at the design level: *is it the right problem, the right method, does it fit the system's invariants and constraints?* They deliberately fix **boundaries and requirements**, not call sequences. Exact code-seam mechanics — which existing function to call, the precise cleanup inventory, the wiring of an unused API — are **resolved at plan-time against live code, per the design principles**, and are explicitly marked `Plan-time (not spec)` where they arise. Flagging a missing call sequence or a not-yet-wired seam is a planning task, not a spec defect; the spec is wrong only if it solves the wrong problem, picks an unsound method, or violates a system invariant.

---

## 1. Problem

ezagent loads agents as **role × flavor**, but offers no canonical way to *declare* an agent. The shape is fragmented across `AgentTemplate` slice, the unused `Ezagent.Role` struct, and per-plugin `agent_flavors/0`. There is no uniform developer/author surface, no clean backend (flavor) swap, and no first-class guidance for an orchestrator to mint new agents.

The `autoservice-dev` branch independently **proved the contract for one vertical, hard-coded**:

| autoservice-dev artifact | = contract concept |
|---|---|
| `soul` (persona markdown + `{{slot}}`) | portable intent (instructions) |
| slot values (YAML) / flavor config | params (content + executor) |
| `SoulRenderer` / `Refresh` → cc `CLAUDE.md` / curl `system_prompt` | **`flavor.compile`** (done per-flavor by hand) |
| `CR → release/vN → _current → rollback → Refresh` | publish + versioning + migration (already a running pipeline) |

**This design extracts that contract so the next vertical is declarative, not hand-rolled.** It does not invent a new runtime — it names a framework-layer contract over primitives ezagent already owns.

---

## 2. Positioning — what we build vs reuse

The four references stack into four layers. ezagent owns the bottom three; the **contract layer (①)** is the gap.

```
① Framework / contract  Flue createAgent · Omnigent agent.yaml      ← THE GAP (this design)
② Backend swap / flavor  Omnigent executor.harness                  ✅ flavor + AgentFlavorRegistry
③ Harness / agentic loop Flue Pi                                    ✅ cc/codex subprocess (bridge/PTY)
④ Runtime                Cloudflare Agents SDK                      ✅ Kind+Lifecycle+Sandbox+snapshot
                                                                       +dispatch+CapBAC+tenant isolation
```

**Decision (Allen):** product focus is *few well-integrated backends + thick runtime*. ④ is the moat and is never outsourced.

### 2.1 Entity-type transparency (load-bearing principle)

ezagent's core promise: **entity type is transparent.** A human (`entity://.../user/...`), a program (echo-like), and an agent (`entity://.../agent/...`) are uniform at the spine — `Invocation.dispatch/1`, `Routing.Resolver`, `chat.join`, `Kind.spawn/2`, `holds_cap?/2` never branch on type (verified in core/session domain). Therefore:

- The contract is the **agent-type *body*** of an entity — sibling to the user's `password_hash` / echo's empty body. It is **not a parallel kingdom**.
- caps → `Identity` grant; membership → `chat.join`; routing → `Resolver`; spawn → `Kind.spawn`. The contract **declares; it does not re-implement** these.

---

## 3. The contract is two layers

The driving scenario ("create a 导购 bot") is **not one agent** — it is a **team**. So the contract has two layers, and only the first is new.

| Layer | What it is | Status |
|---|---|---|
| **Agent manifest** | per-agent body: `soul`/skills/tools/caps/lifecycle + `executor`. A data manifest (YAML + soul.md) — the refactor of `AgentTemplate`'s `:template` slice. | **new (spec-1)** |
| **Team (SessionTemplate)** | "a bot" = `members:[{role_name, source_template_uri}]` + `routing_rules` (legend entry + relay chain) + `legends` + `prompt_templates`. | **reuse existing team-routing** |

### 3.1 Team layer is already built — reuse, do not reinvent

`EzagentDomainInstanceMessage.SessionCreator.TemplateTeam.materialize_template_team/4` assembles a session's team from `SessionTemplate` content: spawns members by role (`spawn_from_template_content`), installs prompt templates, legends, and routing **rule-sets**. The scenario maps exactly:

- **"导购" rule** = `mention("导购")` matching `Message.legend_triggers` (symbolic legend name, `Routing.Matcher` team-routing §3.6) → fires the rule-set **entry** rule.
- **Sequential doorman → next hop** = **relay chain**: a rule with matcher `{:from, <agent_uri>}` → receivers `[next_role_uri]`. `Ezagent.Orchestrator.Tools.MemberTemplate` already maintains relay-chain `{:from, …}` sender matchers across member swaps.
- **Ordering** = `rule_set` + `position`. **Receiver resolution** = `role_name → uri` (`role_to_uri`).
- **Matcher vocabulary** (`Routing.Matcher`): leaves `mention / from / text_contains / text_matches / in_session / always` + combinators `and / or / not`.

The new agent manifest plugs in as the **`source_template_uri`** each team member points at. **No new routing mechanism is built.**

---

## 4. The manifest — what it is and how it's expressed

**Form: data, not code.** The contract is a **data manifest (YAML/JSON) + a `soul` markdown** — *not* Elixir, *not* Python. It must persist, fork, version (in CR/release), travel over dispatch, and be edited by **non-developers in the admin UI**; only data does all of that. Elixir provides the *schema* (a validation struct), the *loader*, and `flavor.compile` — it does **not** express the contract as code. This mirrors what autoservice already ships (`souls/` + `slots/` + a manifest).

```yaml
# agent manifest (YAML) — the versioned, forkable, dispatchable artifact
name: doorman
soul: soul.md                 # persona / instructions, backend-agnostic, may carry {{slots}}
                              #   ("soul" = autoservice's house term for the persona)
skills:    [greeting, triage] # backend-agnostic
tools:     [...]              # dispatch-backed (see §7), backend-agnostic
caps:      [...]              # DEFERRED to Identity grant (same path users use)
lifecycle: persistent         # persistent | ephemeral  (manifest default, spawn may override — §8)

executor:                     # the backend binding ("executor" = Omnigent's term)
  flavor: [cc, codex, curl]   # candidate backend(s); a list ⇒ fallback policy (§6)
  params: {model: opus}       # author-chosen backend params (model / api_url / provider …)
# compiled backend config (cc CLAUDE.md / curl system_prompt / mcp_config_path) is PRODUCED
# by flavor.compile (§5) — never authored, never stored in the manifest.
```

Three groups, in plain terms (this replaces the earlier "portable / executor / derived" jargon):

- **author fields** — `soul` + `skills` + `tools` + `caps` + `lifecycle`: backend-agnostic; this is the reusable "role". `soul` reuses autoservice's house term for the persona.
- **`executor`** — the one backend-coupled group: `flavor` (+ fallback, §6) + `params`.
- **compiled config** — output of `flavor.compile`; the author never writes or sees it (NOT a peer bucket).

A backing **Elixir schema struct** validates a loaded manifest. `Role.Materialize` is **deleted** (prototype, no live caller); `Ezagent.Role` is **kept** until `AgentManifest` replaces `OrchestratorRole.recipe` + bootstrap role install (it is still live there — codex P2-6).

### 4.1 Slots — what they hold, when they render

`soul.md` is a *template*; **slots** are the per-tenant / per-instance values that fill its `{{placeholders}}` so one soul serves many bots: `brand_name`, `product_list`, `pricing`, `tone`, `escalation_keywords`, … (the autoservice slot set). They live in `slots.yaml` beside the soul.

**Render timing (decided): at spawn, in a shared flavor-agnostic step — never stored rendered.**

```
soul.md + slots.yaml ──render──▶ resolved instructions ──flavor.compile(+params)──▶ backend config
                  (flavor-agnostic, shared)                                       (cc CLAUDE.md / curl prompt)
```

Substituting `{{brand_name}}` is identical for cc/codex/curl, so slot-render is a **shared pre-compile step** feeding `flavor.compile`, not duplicated per flavor. The rendered text is a derived artifact (like the backend config) — produced at spawn, never written back into the manifest (matches autoservice's render-at-render-time).

### 4.2 Filesystem layout

The contract is files on disk (Flue convention `agents/<name>` + `skills/<name>/SKILL.md`; autoservice's tenant tree). Two nested units + the reused lifecycle wrapper:

```
# agent-manifest unit (NEW — spec-1)
agents/<name>/
  manifest.yaml          # wiring: executor{flavor,params,fallback}, skills refs, tools, caps, lifecycle
  soul.md                # persona template (with {{slots}})
  slots.yaml             # slot values
skills/<name>/SKILL.md    # shared, referenced by manifests (Flue + autoservice agree: skills are markdown)

# team unit = a SessionTemplate (REUSE team-routing)
teams/<name>/
  team.yaml              # members[role → agent ref], routing_rules, legends, prompt_templates

# tenant lifecycle wrapper (REUSE autoservice CR/release — spec-3)
tenants/<tid>/
  sandbox/               # editable working copy (agents/, teams/, skills/, kb/)
  release/v1 … vN/       # published snapshots (same shape as sandbox)
  release/_current -> vN
```

### 4.3 Authoring surfaces — data is canonical, code is an optional developer builder

The contract is **data at rest**, but data is not the only *authoring* surface. Two surfaces over one runtime form, split by **trust + lifecycle** (the Flue lesson, made safe for multi-tenant):

| Surface | Who / when | Form | Why |
|---|---|---|---|
| **Code builder** (optional, post-MVP) | developer, build-time, **trusted** | Elixir `define_agent do … end` (Flue's `defineAgent` shape) — type-checking, composition, conditional logic | Code's benefits: tooling + logic. **Builds to** the data manifest, as `flue build` turns TS into a deployable artifact. Ships plugin defaults. |
| **Data** (canonical) | admin, runtime, **per-tenant** | `manifest.yaml` + `soul.md` + `slots.yaml`, edited in the admin UI | The only safe form when the author is untrusted/non-developer: tenant-authored **code cannot be loaded/eval'd into the multi-tenant BEAM** (security — no-eval rule + tenant isolation); **dispatch carries data, never code**; non-devs edit text/forms, not Elixir. |

The **runtime always consumes the data manifest** — the code builder merely *emits* it (Flue: code → build → artifact → runtime; ezagent: builder → manifest → runtime). Code's tooling where the author is trusted (build-time); data's safety where the author is a tenant (runtime). Even Flue stores the bulky **skills as markdown files**, not code — `soul.md` follows the same instinct. The code builder is **post-MVP**; spec-1 ships the data form + schema + loader.

---

## 5. `flavor.compile` — generalize SoulRenderer

Each flavor's Template Class implements:

```elixir
@callback compile(portable :: map(), params :: map()) ::
  {:ok, derived_config :: map()} | {:error, term()}
```

- **cc**: read `instructions` + `skills` + `params.model` → render `CLAUDE.md`, write `mcp_config_path` / `settings_path`. (This is autoservice's `SoulRenderer.full_claude_md` + `Refresh`, promoted from hard-coded to a callback.)
- **curl**: read `params.provider/model/api_url` + `instructions` → its config + `system_prompt`.

**Invariant:** the manifest's author fields never contain a flavor field; `derived_config` never leaks back into the manifest. CI grep-gate enforces. Input is the **loaded data manifest** (§4), not code.

---

## 6. Backend fallback — an author-configurable rule (folds into spec-1)

The scenario step 4 ("启动 agent 时先试 cc,失败切 codex/curl,全失败 @orchestrator") is **spawn-time, not per-message**, and is **author-configurable like a rule** — not hardcoded try-order. Express it in `executor`:

```yaml
executor:
  flavor: [cc, codex, curl]        # simplest form: ordered candidates, try-in-order on ANY spawn failure
  fallback:                        # optional explicit policy — per-candidate fall-through conditions
    - {try: cc,    on: [unavailable, timeout]}
    - {try: codex, on: [error]}
    - {try: curl}                  # last resort, unconditional
  on_exhausted: notify_orchestrator
```

- Bare `flavor: [cc, codex, curl]` = default policy: try in order, fall through on any spawn error.
- `fallback` lets a developer/author say *which* failure on *which* backend falls through to *which* next backend — a declarative rule, same spirit as routing rules. A single `flavor: cc` is the one-candidate case.
- Evaluation is **spawn-time**, per candidate **via the existing `spawn_from_template_content` path** (which self-cleans a failed attempt — see spec-1 §3.4; `flavor.compile` is the pure render step *inside* `instantiate`, not a detached spawn). Per-message fallback is out of scope.
- All exhausted → `on_exhausted` (default: notify orchestrator/operator), **fail-closed, no orphan**.

---

## 7. tools[] — dispatch-backed, type-transparent

`skills[]` = instruction-injection (loaded into context), **not** callable tools.

`tools[]` = MCP tools whose body is an **authorized ezagent dispatch** (MCP is the existing universal seam; the orchestrator's MCP tools already work this way):

- `type: :action` → dispatch to a Behavior action (notify / read resource / query). Type-transparent because dispatch is.
- `type: :participant` → "add a participant", generalizing `add_managed_member`:
  - `ref = agent manifest` → spawn (`spawn_from_template_content`) then provision-join
  - `ref = existing entity URI` (human/program) → provision-join only (invite, no spawn)
  - both run the same **type-blind** `provision_join_authority → chat.join → mount_participation_caps` (cap preflight + lineage + workspace binding + compensation). A bare join is NOT enough — invited members need join-authority provisioned + session-scoped participation caps (spec-2 §3.3, codex P1-2).

**CapBAC (codex P1-1):** a tool's dispatch carries **`ctx.caps = []`** — the manifest's declared `caps` are granted to the agent's Identity at spawn and checked via `holds_cap?`; they are **never** injected into a dispatch `ctx` (the runtime trusts `ctx.caps` ahead of the Identity slice). Manifest YAML declares desire, never authorization.

**No arbitrary author-code function tools** (that is the harness's job; would risk P14). The manifest carries **no peer addressing** — peers are session members resolved by the existing routing table.

**Escalation to human (`@operator`)** is the type-transparency money case: `operator` is an existing human role member; "can't answer → @operator" routes via the same `Resolver`/`chat.join` — no agent-vs-human branch. (The `cs_orchestrator.operator_claim` **Turn takeover** is the autoservice vertical's UX, **downstream** of this contract — not part of G3; spec-2 §1.)

---

## 8. Lifecycle — reuse Kind.persistence (deprioritized)

`Kind.persistence/0` already returns `:ephemeral` (echo) or `{:snapshot, :on_change}` (agent). `lifecycle:` lets an instance pick:

- `:persistent` → `{:snapshot, :on_change}`, rehydrate on restart.
- `:ephemeral` → reuse echo's `:ephemeral`: no snapshot, `:terminate` on completion, no rehydrate.

`manifest default + spawn override`. In autoservice both fast and slow are persistent, so this is a cheap field for future short-lived helpers — **not a gating concern** for this vertical.

---

## 9. Publish / version / migration — reuse CR/release

The scenario step 5 (edit in template session → publish → new sessions adopt → existing sessions migrate manually) is **already built** in `ezagent_plugin_cr` + `Refresh` + `MemberTemplate.update_member_template`. We do **not** build a new mechanism; the **manifest (and the SessionTemplate team) becomes the versioned artifact** flowing through:

- autoservice file pipeline: `CR → release/vN → _current → rollback`. On main, the pin is the **immutable `session_template_uri@hash`** a session already holds (spec-3 §3.1, codex P1-4); a publish mints a new hash + moves a tag, never mutating an existing session.
- New sessions resolve the tag → hash at `create_session/3`; existing sessions keep their frozen hash.
- Existing sessions migrate only via the **ledger-tracked `migrate_session`** built on per-member `update_member_template` (spec-3 §3.3).

---

## 10. Orchestrator design skill (NL → SessionTemplate)

Step 3 ("tell orchestrator I want a bot needing data X, tool Y, metric Z → it decomposes into roles + routing rules") is **an orchestrator skill**, not a contract-layer feature. It teaches the orchestrator how, in the ezagent environment, to decompose a goal into **SessionTemplate content** (members + relay-chain routing rules + legend entry + prompt templates).

- Authored and tested with **skill-creator + its eval tool** (not a runtime E2E gate).
- The contract's job is only to make that output expressible (which §3–§7 do).

---

## 11. Explicitly deferred / out of scope

- **Deep NL decomposition quality** — owned by the §10 skill + eval, not contract gates.
- **SLA / filler / fast-ack (5s response)** — currently a stub in autoservice (`filler_loop` 10s/45s, `send_soothing` no-op); tested at real creation time, not now.
- Per-message backend fallback; a universal `Entity.create/4` envelope (north-star only — keep the manifest shaped to slot into it later).

---

## 12. Acceptance — behaviour-preserving re-expression

**Baseline:** `mix ezagent.demo.seed_autoservice` (workspace → role users → per-customer session with fast curl/DeepSeek (+ optional slow cc) agent, routing, greeting). autoservice's `soul`/`skill` files are **test fixtures** — we reference, not replicate.

**Target:** the contract version produces the same working sessions, declaratively.

| Gate | Observable (driven via `mix ezagent`, no raw RPC) | Spec |
|---|---|---|
| **G1 manifest re-expression** | fast/slow spawn from declarative `AgentManifest`s via `manifest → flavor.compile → Kind.spawn`; the curl `system_prompt` / cc `CLAUDE.md` produced by `compile` are **byte-identical** to today's `SoulRenderer`/`Refresh` output. | spec-1 |
| **G2 backend fallback** | `flavor: [:cc,:codex,:curl]`; simulate cc unavailable → lands on codex → simulate fail → curl; all fail → spawn error + dispatch to operator; telemetry shows try-order; no orphan. | spec-1 |
| **G3 type-transparent escalation** | `operator` (a **human** `entity://…/user/op`) sits in `slice.members` indistinguishable from agents; "can't answer → @operator" routes via the same `Resolver`/`chat.join` (no agent-vs-human branch). *(Turn takeover `operator_claim` is downstream autoservice acceptance, not gated here — spec-2 §1.)* | spec-2 |
| **G4 publish → migration** | edit a manifest's soul/slot → CR publish → `release/vN` → `_current` flips → `Refresh` re-renders; **new** sessions use `@vN`, **existing** stay pinned until `update_member_template` migration. | spec-3 |
| **G5 one-field backend swap** | flip a manifest's `flavor` `:cc → :codex`, re-spawn, equivalent behaviour, codex-compiled config. | spec-1 |

Plus the team layer is exercised by materializing a SessionTemplate whose `routing_rules` form a **legend-entry → relay chain** (the 导购 chain) and confirming an inbound customer message propagates hop-by-hop — using the **existing** team-routing, asserting the contract feeds it correctly.

**Falsifiers (must stay red):** a human member taking a different routing path than an agent; participant cap-preflight bypassed (orphan spawned); a flavor field leaking into the portable bucket (CI grep-gate). *(Deferred / non-MVP, since lifecycle is an ungated field — §8/§13: an ephemeral agent leaving a snapshot row.)*

---

## 13. Spec decomposition

- **spec-1** — data `AgentManifest` (YAML + `soul.md`; refactor `AgentTemplate`) + `flavor.compile` callback (extract `SoulRenderer`) + author-configurable `executor` fallback + wire into the live spawn path, replacing the ad-hoc slice; delete `Role.Materialize` (keep `Role` until manifest replaces bootstrap). **Gates G1, G2, G5.**
- **spec-2** — `tools[]` (dispatch-backed MCP) + type-transparent `:participant` / escalation to operator. **Gate G3.**
- **spec-3** — manifest + team as the versioned artifact in the existing CR/release/migration pipeline. **Gate G4.**
- *lifecycle ephemeral* — cheap manifest field, folded into spec-1, not gated.

---

## 14. Skill deliverables (part of this work)

The contract creates two audiences; update/ship both:

- **`ezagent-developer` (update)** — add the `AgentManifest` schema, the `flavor.compile` contract + its invariant/CI grep-gate, and the team-layer reuse pointers. Audience: people writing core/domain/plugin Elixir.
- **`ezagent-admin` (new)** — non-developer authoring workflow: write soul/slot/manifest, compose teams (SessionTemplate role-chains + routing rules + legends) with the orchestrator design skill, publish via CR, migrate existing sessions. No Elixir.

---

## 15. Open questions / risks

- **SessionTemplate vs AgentTemplate naming** — both are `template://` Kinds; confirm the manifest = AgentTemplate body and the team = SessionTemplate content, with no third concept.
- **Sibling autoservice branches** — operator escalation / customer path / cs-stage1 live on `feat/autoservice-*`; spec-1/2 must not assume autoservice-dev is the whole picture. The contract must *accommodate* what those branches hold, verified before each spec.
