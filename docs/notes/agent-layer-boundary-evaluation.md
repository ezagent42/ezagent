# Agent-layer boundary evaluation — should recipe+flavor extract, leaving ezagent only role?

**Date:** 2026-07-09
**Status:** Design-research (read-only analysis; no code changed). All code citations verified against `origin/main` (`3eaceeabf`) in a worktree.
**Skills loaded:** `ezagent-developer` (design-principles, three-tier-structure, capbac).
**Companion (Chinese):** [agent-layer-boundary-evaluation.zh_cn.md](agent-layer-boundary-evaluation.zh_cn.md) — parallel; keep in sync.
**Sibling doc (concurrent):** the CapBAC/RBAC boundary evaluation (auth-layer). The two together answer: **is ezagent's complexity essential or imported — in the AUTH layer and the AGENT layer?** Cross-referenced in §5.

---

## 0. The hypothesis under test

The lead's intuition, from a teammate discussion:

> "agent 这块我们可能搞复杂了 — recipe 和 flavor 切到外面单独的系统可能好一点,ezagent 内只保留 role."
> *(The agent area may have gotten too complex — cutting recipe and flavor out into a separate standalone system might be better; keep only role inside ezagent.)*

Restated: **extract `recipe` (how an agent is built) + `flavor` (cc/codex/curl execution backend) into a separate "agent system"; leave ezagent owning only `role`** — responsibility slots, `{:role,name}` routing, session / orchestration / membership (humans + agents in routed conversations).

This doc tests that honestly with code evidence. The verdict (§6) is **nuanced, not a yes/no**: the lead's *diagnosis* (pain is concentrated in the agent layer) is **confirmed**; the lead's *prescription* (a separate external system) is **over-shooting** — the right cut is an in-repo hardened boundary, because the agent *control plane* (spawn/credential-mint/cap-grant/lifecycle) is welded to ezagent's essential CapBAC + Kind machinery, while only the *delivery plane* is genuinely external today.

---

## 1. The three concepts, precisely (from code)

The taxonomy is already crisp in the codebase (GLOSSARY Decision #155, `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md`). The one-line model, in Allen's own words in `apps/ezagent_core/lib/ezagent/agent/recipe.ex:6-7`:

> **The CONTENTS of the sandbox are the RECIPE; HOW the sandbox is loaded is the FLAVOR.** (Allen 2026-06-14)

And responsibility is a third, orthogonal axis: **role_name** (axis B) — *who* fills a slot, routed by `{:role,name}`.

### 1.1 RECIPE — "how an agent is built" (config-as-data, axis A)

- **What it is:** a **flavor-agnostic** struct — `skills`, `plugins`, `prompt` (persona), optional `script`, `behaviors` subset, `requested_caps`, `session_template` ref, opaque `config` bag. Stored as a **ConfigObject** (Layer-2 data) at `config://<ws>/recipe/<name>`. `Ezagent.Agent.Recipe.new/1` **rejects** any recipe naming a flavor field (`:flavor/:kind/:bridge_adapter/:template_class`, `recipe.ex:34,94-116`) — the same recipe must compose identically across cc/codex/curl.
- **Footprint:** ~2031 LOC of dedicated modules. Split:
  - **Core (552 LOC):** the data primitive only — `recipe.ex` (336), `recipe/cap_mint.ex` (124), `recipe/compose.ex` (92). These are the flavor-agnostic struct + the recipe×flavor composition primitive.
  - **domain_agent (1305 LOC):** all *logic* — `recipe_registry.ex` (509, read-through over `Socialware.ConfigStore`), `recipe_materializer.ex` (283), `recipe_resolver.ex` (155, cold-restart read-model), `recipe_attributes.ex`, `recipe_behavior_fold.ex`, `grant_recipe_caps.ex` (234).
  - **domain_session (130 grep-matches):** almost entirely recipe-*as-a-data-field* in socialware role slots (`%{role_name, recipe, flavor}`, `socialware/definition.ex:36`), not recipe logic.
- **Weave verdict:** **Core owns the data primitive; domain_agent owns all logic.** Recipe is *already data* — a forkable, content-addressed ConfigObject. "Extracting recipe to an external store" is close to a **no-op**: the store is already external-shaped. Governance of recipe-as-data is a first-class CR concern (Decision #158, `ConfigGovernance.Agent`: stage→preview→publish-pointer-flip→rollback).

### 1.2 FLAVOR — "cc/codex/curl execution backend" (the loader)

- **What it is:** the runtime backend that loads a recipe's content into a live agent + carries messages to it. Two transport classes (`agent_bridge/adapter.ex:29-37`):
  - `:subprocess_ws` — cc, codex: a subprocess (claude TUI / codex) reached over a **Phoenix.Channel WebSocket** sidecar. Reply is **async** (→ `session.send`).
  - `:in_process_sync` — curl: no subprocess, an in-process HTTP round-trip returning `{:ok, result}` synchronously; the agent reads its **own** `:api_keys` slice (`agent_bridge.ex:72-103`, `complete/2`).
- **Footprint:**
  - **Core (119 LOC of flavor-agnostic seams):** `kind/template/flavor_hook.ex` (59), `plugin/flavor_publish_hook.ex` (60). Plus the deeper weave in §1.2.1.
  - **domain_agent (563 LOC flavor cluster):** `agent_flavor_registry.ex` (271), `agent_flavor_resolver.ex` (175, ETS + snapshot, deadlock-safe), `agent_flavor_attributes.ex` (80), the two publish/template hooks.
  - **domain_agent_bridge (1408 LOC, whole app):** the transport contract — `agent_bridge.ex`, `adapter.ex`, `adapter_registry.ex`, `channel.ex`, `socket.ex`, `payload.ex`, `token_store.ex`, `registry.ex`. This is the delivery seam.
  - **Plugins (~850 LOC of adapters):** cc `bridge_adapter.ex` (254) + `cc_headless_bridge_adapter.ex` (67), codex (174+28), curl (182), py (100), hello (45).
- **Resolution indirection:** every consumer reaches flavor via `Ezagent.UriQuery.resolve(:flavor, agent_uri)` — the `:flavor` resolver is *registered by domain_session* (`uri_query_resolvers.ex:15`) and delegates into `AgentFlavorResolver` (domain_agent). Core even ships an **enforcement scanner** (`uri_query/scan.ex`) that fails a build if code reads flavor from the URI-name prefix instead of via UriQuery.
- **Weave verdict:** **execution is behind a real seam — but flavor is NOT airtight-confined.** Backend execution (bridge + adapters) sits cleanly in plugins + domain_agent_bridge, reached only through the UriQuery indirection. **Two real leaks** remain (§1.2.1, §1.2.2).

#### 1.2.1 Flavor leaks into core — as a credential-keying field (the deepest weave)

The credential cascade (`Ezagent.Credential.*` in `ezagent_core`, task #17) is **keyed on flavor**:

- `credential/workspace_shared_source.ex:21,48` — `field(:flavor, :string)` + `validate_required([:id, :workspace_uri, :flavor, :source_uri, :set_by])`.
- `credential/user_default_source.ex:51,91` — `field(:flavor, :string)` + `validate_required([… :flavor …])`. The stored user-source pointer is keyed `(owner, workspace, flavor)`.
- `credential/resolver.ex:81,378` — the ordered layer set is **flavor-base → workspace → user → session**; `resolve_layers` reads flavor via `UriQuery.resolve(:flavor, agent_uri)` to pick the credential source.

So **credential storage and selection are structurally keyed by flavor in core.** This is the deepest agent↔core weave, and the crux of the credential-isolation question (§4).

#### 1.2.2 Flavor leaks into domain_session — as a spawn input

Session must know an agent's flavor to *materialize* it (not to *route* to it):
- `agent_module_resolver.ex` (31 matches), `session_creator/template_resolver.ex` — resolve stored flavor → Kind/Template Class via `AgentFlavorRegistry`.
- `session_creator/definition_agents.ex`, `template_team.ex` — spawn = **recipe × declared flavor**.
- `domain/agent.ex` (39 matches) — flavor-agnostic Agent lifecycle facade; `resolve(:flavor)` decides PTY-backing.

### 1.3 ROLE / RESPONSIBILITY / SESSION — "the layer to keep"

- **What it is:** the responsibility slot (`role_name`: bot/reviewer/orchestrator/supervisor), `{:role,name}` routing, and the whole session / membership / conversation / orchestration surface.
- **Footprint:**
  - **Core routing primitive (1280 LOC dedicated):** `routing/receiver.ex` (48, defines `{:role,name}`), `routing/matcher.ex` (358, `sender_role?`), `routing/resolver.ex` (618), `routing/legend.ex` (256). Whole `routing/` dir = 1834 LOC.
  - **domain_session (26,748 LOC non-test):** membership, members, member_cap, role_resolver, route_provisioner, orchestrator + tools, socialware/*.
- **Coupling to flavor/recipe:** **the routing primitive is flavor/recipe-AGNOSTIC.** Core `routing/*` has *zero* flavor/recipe references (except a cosmetic `:flavor` prompt-render var). `{:role,name}` resolves role_name → member URI purely via session-member metadata — **routing never consults an agent's flavor or recipe.** Coupling lives one layer up, at *spawn time*, where a role slot is the data triple `%{role_name, recipe, flavor}`.
- **Weave verdict:** **cleanest of the three.** Routing does not need to know how an agent is built. Recipe+flavor enter the session domain only at the moment a member is *created*, cleanly separated from the moment a message is *routed*. This layer is well-positioned to keep.

### 1.4 Is AgentBridge already the seam?

**Partly — it is the *delivery* seam, not the *control* seam.**

`Ezagent.AgentBridge` (`agent_bridge.ex`) exposes a clean adapter-mediated interface that already approximates `send(handle,msg)→reply`:
- `deliver(agent_uri, payload)` / `deliver_with_flavor/3` — send a chat payload.
- `complete(agent_uri, prompt) → {:ok, text}` — synchronous completion (curl).
- `Ezagent.AgentBridge.Adapter` behaviour — `flavor/0`, `transport_class/0`, `deliver/2`; per-flavor adapters live in plugins. This IS an external-runtime-style contract: cc/codex adapters already talk to *out-of-process* subprocesses over WebSockets.

**But the control plane leaks straight through the seam into core primitives.** `deliver_ensuring/3`'s heal path (`agent_bridge.ex:270-309`, `default_heal`) reaches into:
- `Ezagent.SpawnRegistry.spawn/1` (re-spawn the Kind),
- `Ezagent.SnapshotStore.latest/1` (read persisted Sandbox slice — a DB read),
- `Ezagent.Kind.normalize_slice_view/1`,
- `template_class.ensure_subprocess_alive/2` (relaunch the subprocess).

So the bridge can *deliver* to an external agent, but to *keep one alive* it drives ezagent's Kind/Snapshot/Spawn machinery directly. **AgentBridge is a delivery seam whose control plane is fused to core.** That distinction drives the whole verdict.

---

## 2. Where the recent pain actually lives (the honest test)

Attributing recent hard problems to a layer. **AGENT-LAYER** = recipe/flavor/spawn/provision/lifecycle/transport/credential. **ROLE/SESSION-LAYER** = routing/membership/conversation/orchestration.

**Discriminator (applied uniformly):** which layer's *code bore the hard engineering change* — not where the symptom surfaced, nor how the ticket was labeled. This is the honest test: it lets a credential ticket land in the session column if the fix was a membership gate.

### 2.1 Incident attribution

| # | Incident | Layer | Evidence |
|---|---|---|---|
| 1 | **create_session 5s timeout** — first socialware install per boot; a cold agent's `activate` provisions a heavy subprocess and holds the sync `ReadyGate.await` past the create dispatch budget. Fix = drop the await, buffered `:cast` delivery (fire-and-forget) | **AGENT** (transport/provision) | `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex:672-691`; ReadyGate saga #505 (`dc017c301`,`7b7c07b18`,`c4070cc67`); decouple spec #912 (`036ce5401`); PR #1202 (`2bded5936`) |
| 2 | **skill distribution P1–P3** — release-bundled `SkillRegistry` + seed lane + fold into config materialization; skills are declared by the recipe/definition and materialized into the agent home | **AGENT** (recipe → materialization) | research #1251 (`fb732cbe8`) → SPEC #1254 (`508dfcdc6`) → impl PR #1266 (`364ccf6ba`); "publishable unit is the socialware Definition" |
| 3 | **cc/codex/curl flavor divergence + config_schema** — wholly different per-flavor config fields; flavor logic had **leaked into core**; north star "adding a flavor = adding a plugin, zero core edits" | **AGENT** (flavor) | spec `docs/together/2026-06-25/specs/A-agent-flavor-config-unification.md` (D4 de-leak core, `no_flavor_refs_in_core` arch gate); `@callback config_schema/0` in `apps/ezagent_core/lib/ezagent/kind/template.ex`; Decision #160 |
| 4 | **#1256 agent-lifecycle complexity** — three-layer agent/entity/flavor mapping, **fresh-spawn full path with 12 chain-links**, **switch/reset six-version state machine**, transport-gated readiness, heterogeneous statelessing | **AGENT** (lifecycle/spawn) | `docs/together/2026-07-08/agent-entity-flavor-mapping-and-lifecycle.zh_cn.md` (`4108e36b8`); `stack.md:12,38` ("明日头号"); later ruled false-positive for the reuse-join branch → deferred to session admission gate #1269 (`96af00d4d`) |
| 5 | **py cold uv provisioning** — first np/py member on a fresh container runs cold `uv` (numpy/sympy ~9.6s) synchronously inside create; fix = defer provision to `activate/2` | **AGENT** (provision) | PR #1259 (`8f9b1597c`,`643cb9c74`); 9.6s corroborated `template_spawn.ex:677-681`; retry-on-adopt `fe43def94` |
| 6 | **credential isolation (GitHub #1178 / issue #161)** — cross-owner member-add routes through admission: `:pending_members`, no member-cap granted, not mounted into `:members`, until the member's owner approves ("owner's credential is not spent") | **ROLE/SESSION** (membership/admission) — *filed as credential isolation, but the engineering is a session membership gate* | PR #1178 (`90e8ee297`) `handle_join/do_join` + `:pending_members`; over-fire fix `7922ed586`; `admission_gate_test.exs`. (GitHub issue #161 ≠ GLOSSARY Decision #161) |
| 7 | **cc/np subprocess orphan-on-restart** (Decisions #127/#128) | **AGENT** (lifecycle/transport) | GLOSSARY #127/#128 — PidFile reaper + `ensure_subprocess_alive` respawn hook |
| 8 | **PTY/Python phase state machine** (Decision #126) | **AGENT** (lifecycle) | GLOSSARY #126 — `:starting/:running/:dead` phase + LV badge |
| 9 | **per-agent ApiKeys deadlock** (Decisions #123/#124) | **AGENT** (credential) | GLOSSARY #123/#124 — ApiKeys User→Agent flip + `reads_sibling_slices` deadlock fix |

**The instructive caveat (incident 6):** the credential-isolation ticket is the strongest test of a naive "credential = agent-layer" reading — and it fails that reading. The fix was engineered *entirely* as a session membership admission gate (`handle_join/do_join`, `:pending_members`, cross-owner→PENDING). Classified by where the code changed, it is a **role/session** win — and one of the cleaner, more self-contained recent pieces, which *supports* the "session layer is comparatively clean" half of the hypothesis. (This is fully consistent with §4: the credential *authority* is role-layer and stays in ezagent; only the *secret* rides the agent.)

### 2.2 Decision-Log denominator (recent, GLOSSARY #120–#161)

Same discriminator; neutrals disclosed, not folded into agent.
- **Agent-build layer — 9:** #123 (ApiKeys→Agent, credential), #126 (PTY phase), #127 (PID reaper), #128 (subprocess orphan fix), #156 (app=socialware, code via plugin), #158 (ConfigGovernance agent-config CR), #159 (`config://` retired → socialware subject), #160 (`agents[].flavor` via `Recipe.Compose`), #161 (Definition/Recipe/Manifest/Registry naming).
- **Role/session layer — 3:** #120 (routing consolidation + CI gate), #129 (session URI shape), #157 (SessionTemplate = preset).
- **Neutral / framework / cross-cutting CapBAC / UI — 8:** #121 (LV hook), #122 (ExternalMirror — deliberately *not* counted as agent-transport), #124 (`reads_sibling_slices` primitive), #125 (`Capability.normalize!`), #147–#152 (Router/Behavior/Kind rewrite), #153/#154 (CapBAC authority), #155 (carrier-layer taxonomy).

### 2.3 The split

Two independent denominators converge:
- **Incident list:** 5 of 6 → ~83% agent (but the list was pre-selected agent-flavored, so it measures the list, not the pain).
- **Decision-Log (layer-specific only):** 9 agent / 3 role-session of 12 → **75% agent / 25%** (33% floor if the 8 neutrals count as non-agent work).

**Headline: roughly 75–80% agent-layer / 20–25% role-session-layer.**

The verdict rests on **depth, not just count.** Session-layer engineering is real and nonzero (routing consolidation #120, listing dedup #1263, fan-out isolation #1252, cold-boot durable listing #1257) — "session is clean" means "session fixes are mostly one-shot," not "session has no work." The asymmetry is that **agent-layer problems are multi-revision sagas** (ReadyGate #505 ≈ 8 commits + a rev4→rev6 spec series; #1256 a 12-link chain + six-version state machine still in draft; skill-dist research→SPEC→3 codex rounds→P1-P3; flavor unification a whole "de-leak core" spec with an arch gate) while **session-layer fixes are single `fix(session)` commits with a review pass.** **The lead's diagnosis is confirmed: recent pain — measured by engineering depth — is concentrated in the agent layer.**

---

## 3. What "extract recipe+flavor, keep role" would actually look like

The advisor's decomposition is the key move: **recipe and flavor have opposite extraction profiles, and each splits into a declarative part (already separable) and a control part (fused to core).**

### 3.1 The two planes

| Plane | What it is | Where it lives today | Externalizable? |
|---|---|---|---|
| **Declarative** | recipe-as-data (ConfigObject); flavor as a queryable string tag | Layer-2 ConfigStore; `UriQuery.resolve(:flavor,…)` | **Already external-shaped.** Recipe is a forkable store; flavor is a string. Extracting = near no-op. |
| **Delivery** | send message / get completion | `AgentBridge.deliver`/`complete` + plugin adapters over WS/HTTP | **Already partly external.** cc/codex subprocesses are out-of-process today; the adapter behaviour is the interface. |
| **Control** | spawn(recipe×flavor)→live Kind; credential-mint; cap-grant; subprocess heal/lifecycle | `RecipeMaterializer` → `spawn_from_content`; `Credential.Resolver.authorize_and_mint_grant!`; `AgentBridge` heal path into `SpawnRegistry`/`SnapshotStore`/`template_class` | **Fused to core.** This is the hard part. |

The clean interface the lead imagines — `spawn(recipe)→handle`, `send(handle,msg)→reply`, `lifecycle(handle)` — **exists for delivery** (AgentBridge) and **does not exist for control**, because control is not a call to an external runtime; it is a *system-mediated authority transaction* inside ezagent (§3.3).

### 3.2 Does this reduce complexity or just relocate it?

For the **declarative + delivery** planes: extraction mostly **relocates** an already-clean seam behind a named boundary — modest genuine deletion (the recipe registry + flavor registry could move out), but the LOC is small (recipe 2031 + flavor cluster 563 + bridge 1408) relative to the 26,748-LOC session domain that stays.

For the **control** plane: extraction to a *separate system* does **not delete** the complexity — it **relocates it across a network boundary and re-imports it via callbacks**, because the control plane's every step needs ezagent's essential machinery (§3.3). This is the classic extract-a-service anti-payoff: you pay the boundary tax and keep the coupling.

### 3.3 The hard constraint: credential isolation glues control to core — but *constrains*, doesn't *veto*

The materialization transaction is the proof. `DefinitionAgents` (`session_creator/definition_agents.ex`) — a **role/session-layer** module the lead wants to keep — materializes a socialware's declared agent slots by running, per agent, a single authority-mediated transaction:

1. role_name uniqueness check (membership),
2. resolve recipe by workspace (`RecipeRegistry`),
3. **spawn = recipe × declared flavor** → `Agent.spawn_from_template_content`,
4. faceted `session.join` carrying `role_name` (membership),
5. **grant recipe caps LAST** (`GrantRecipeCaps`, fail-closed), authority **system-mediated** (spawn under session owner `granted_by`, join under genesis admin).

Steps 2-3-5 are agent-build; steps 1-4 are role/session; and the whole thing is **one transaction with cleanup-on-join-failure**. You cannot draw a network boundary between step 3 (spawn) and steps 4-5 (join + cap-grant) without fracturing the transaction — the spawn would be external, the join+grant+cleanup internal, and a partial failure would orphan a worker across the boundary.

The credential path sharpens it (advisor correction — this **constrains the interface, it does not block extraction**):
- `Credential.Resolver` is **pure** — it returns *descriptors* only, and reads flavor as a **string key** via `UriQuery`. Flavor is the lowest of four layers (flavor-base→workspace→user→session).
- The **authority** machinery — owner-check, `authorize_and_mint_grant!`, the durable `GrantRow {agent, source, approved_by, approved_scope, version}`, the CapBAC `sandbox.read` gate, "no unowned permissions" (#154) — is **workspace/user/CapBAC**, i.e. **role-layer**, which ezagent keeps.

So the boundary runs *through* the credential module: **flavor must stay a queryable metadata tag across the seam; the grant/authority stays ezagent-side.** That is an **interface requirement (flavor readable), not a veto.** Credential isolation does not forbid extraction — it forbids a *dumb* extraction that moves the authority out or that hides the flavor tag.

### 3.4 What resists extraction (the coupling enumeration)

- **Socialware `Definition.agents` materialization** (`definition_agents.ex`) — the single spawn+join+grant+cleanup transaction above. Decision #160: `agents[].flavor` routes through the flavor-generic `Recipe.Compose`. This is role-layer code that *drives* agent-build.
- **Recipe-as-data governance** (#158 `ConfigGovernance.Agent/Socialware`) — the CR stage→preview→publish→rollback pattern is shared with socialware Definition governance; splitting agent-config CR from socialware-Definition CR would fork a deliberately-unified mechanism.
- **Skill distribution** (P1-P3, just built) — skills are a *recipe field*; their delivery into the sandbox is the recipe→flavor materialization path. Extraction would move a just-stabilized mechanism.
- **Credential cascade** (§3.3) — flavor-keyed source selection in core + CapBAC-gated grant authority. The deepest weave.
- **AgentBridge heal/lifecycle** (§1.4) — `SpawnRegistry`/`SnapshotStore`/`template_class` reach. The control plane is not a network call.
- **The `app = socialware, code from plugin` model** (#156/#157) — a plugin *is* the code channel (behaviors/kinds/recipes/flavors); an app is a config-only socialware Definition. Flavor/recipe are already "plugin-contributed" in this model. An *external* agent system would be a *third* code channel competing with the plugin channel the team just committed to.

---

## 4. Credential isolation — the counter, weighed precisely

The task frames this as the decisive question: *can the boundary be drawn without ezagent reaching across it for credential/routing reasons?*

**Answer: yes for delivery, no for control — but the "no" is a constraint, not a veto.**

- **Credential isolation is achieved by construction** (#123/#124): per-agent ApiKeys, the agent reads its **own** key slice, the caller never sees it (`agent_bridge.ex` `complete/2`, "the CALLER never sees the API key"). This is *good* isolation and it lives on the Agent Kind — i.e. **inside** whatever the agent runtime is.
- **But the admission/authority side is role-layer** (#154 no-unowned-permissions, #161 admission gate, `authorize_and_mint_grant!`). Who is *allowed* to spend which creds is a membership + CapBAC question, decided at `session.join` and cap-grant time.

The credential story therefore **straddles**: the *secret* lives on the agent (extractable with the agent), the *authority to use it* lives in ezagent's CapBAC + membership (must stay). A separate external agent system would either (a) hold the secret AND re-implement the authority gate (duplicating CapBAC — the sibling auth-doc argues CapBAC is ezagent's *essential* core, so this is exactly the complexity you can't safely move), or (b) hold the secret and call back into ezagent per-spend for the authority check (chatty, re-couples). Neither deletes complexity.

**This is the meeting point with the sibling CapBAC/RBAC evaluation:** you cannot fully externalize the agent layer *because* the (essential, must-stay) auth layer reaches into spawn + credential-mint. The agent control plane is anchored in ezagent by CapBAC, not by accident.

---

## 5. Options

| Option | What leaves ezagent | What stays | Migration cost | Credential-isolation permits? |
|---|---|---|---|---|
| **A — keep as-is** | nothing | everything | zero | yes (status quo) |
| **B — in-repo hardened boundary** | nothing physically; a *module* boundary: AgentBridge becomes the *sole* agent-runtime interface (delivery **and** a control facade), recipe/flavor registries sealed behind it | all code in-repo; CapBAC/credential authority untouched | low–medium (mostly discipline + a control facade + gates) | **yes** — flavor stays a queryable tag; authority stays |
| **C — separate external system** | recipe store + flavor execution + spawn control | role/session/routing + CapBAC + credential authority | **high** — fractures the materialization transaction (§3.3), forces CapBAC duplication or per-spend callbacks | **no, cleanly** — control-plane extraction forces auth duplication or re-coupling |
| **D — hybrid** | *delivery* execution hardened as an external-style boundary (it already is: cc/codex subprocesses); *control + authority* stays in-repo | role/session + CapBAC + credential authority + the spawn/materialization transaction | low–medium | **yes** — matches reality (execution already external, control already internal) |

---

## 6. Verdict

**Recommendation: B, converging on D.** Harden the agent boundary **in-repo** — make `AgentBridge` (delivery) + a small `Recipe.Compose`/materialization facade (control) the *single* declared seam through which the role/session layer consumes agents, and seal recipe/flavor registries behind it with an arch-gate (no direct `AgentFlavorRegistry`/`RecipeRegistry` reach from outside domain_agent). This is essentially **D** describing what is already true — *execution is already out-of-process; control+authority is already in-core* — and just making the seam explicit and enforced, rather than **C** relocating control across a network boundary.

**Grounding, in three sentences:** (1) The Part-2 data confirms the lead's *diagnosis* — recent pain is heavily agent-layer (subprocess lifecycle, cold provisioning, flavor divergence, credential deadlocks; ~75–80% agent vs 20–25% role/session on two converging denominators, and far more skewed by *engineering depth* — agent problems are multi-revision sagas, session fixes are one-shot). (2) But recipe is *already data* and flavor delivery is *already out-of-process*, so the seam the lead wants mostly **exists** (AgentBridge) — the honest gain from "extraction" is small deletion + a hardened interface, not a new system. (3) The agent *control* plane (spawn→join→cap-grant materialization transaction, flavor-keyed credential cascade) is welded to ezagent's **essential** CapBAC + membership + Kind machinery — the credential-isolation constraint *permits* a hardened in-repo boundary (flavor stays a queryable tag) but *forbids* a clean external cut (it would duplicate CapBAC or re-couple per-spend). **So: the lead is right that the agent layer is where the complexity and pain are, and right to want a sharper boundary — but the boundary is a hardened in-repo module seam (B/D), not a separate external system (C); the thing that keeps the agent layer in ezagent is the same thing the sibling doc identifies as essential — CapBAC.**

### 6.1 Concrete next steps (if B/D is adopted)
- Add an arch-gate: outside `domain_agent`/`domain_agent_bridge`, no direct `AgentFlavorRegistry` / `RecipeRegistry` / `template_class` reach — everything through the AgentBridge + a materialization facade.
- Promote `RecipeMaterializer.create_agent_from_recipe` + the `DefinitionAgents` transaction into *the* named "spawn an agent" control interface; document it as the control-plane twin of `AgentBridge.deliver`.
- Keep flavor a queryable string tag at the seam (already true via `UriQuery`); do **not** move the credential-authority cascade out of core.
- Revisit only if delivery divergence (flavor config_schema) grows enough to justify a genuine external execution service — then extract *delivery* (D), never control.
