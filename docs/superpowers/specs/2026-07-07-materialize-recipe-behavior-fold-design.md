# Materialize-Path Recipe Behavior Fold — Design (T1, ⑬)

**Status:** DRAFT (design; no implementation in this doc)
**Authority:** `docs/together/2026-07-06/handoffs/system-mechanism-feedback.md` item ⑬ + Appendix B (coordinator re-verified post-#1212/#1213); evidence #1191 `dealscout-refresh-v2/` probe.
**Verified against:** `origin/main` `dcabf6174` (every file:line below re-read on that commit).
**Relates to:** `2026-07-05-socialware-role-slot-model-design.md` (slot = `%{role_name, recipe, flavor}`), `2026-07-06-orchestration-as-socialware-design.md`, `2026-07-06-config-governance-unify-and-manifest-yaml.md` (crgov — untouched), #1209 HostLoginAdopt (seam preserved, §3.4).

---

## 1. The X — problem and evidence

**A socialware-declared role must be a full member — same dispatch surface — regardless of which path materialized it. Today the template-materialization path leaks into what the member can dispatch: it never captures the recipe's declared behaviors.**

The system has two ways to turn `(recipe, flavor)` into a live agent, and they are
asymmetric on exactly one axis — the behavior fold:

### 1.1 The `agent_create --role` path (correct)

`Ezagent.ActionSet.Workspace.AgentCreate.do_create_agent/4` (direct-spawn clause,
`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex:376-408`):

1. `RoleStep.resolve(role, flavor)` (`agent_create/role_step.ex:92-98`) — looks up
   the recipe, computes the flavor's per-instance behavior set
   (`instance_behaviors` thunk, else `Ezagent.Kind.nil_capture_behavior_set/1` —
   `role_step.ex:236-241`), and calls
   `Ezagent.Agent.Recipe.Compose.materialize/2`
   (`apps/ezagent_core/lib/ezagent/agent/recipe/compose.ex:56-89`), which UNIONs
   `role.behaviors ++ flavor_behaviors` (`compose.ex:66`).
2. The composed set is threaded into the spawn args as `:behaviors`
   (`agent_create.ex:495-507`, `put_role_behaviors/3`), reaching the Kind's
   `:kind_base` capture — durable across cold restart.
3. Caps are minted and granted (`role_step.ex:180-212`), durable markers recorded.

### 1.2 The socialware template path (defective)

`TemplateTeam.materialize_template_team` →
`DefinitionAgents.materialize_definition_agents` →
`materialize_fresh_agent`
(`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex:132-170`)
→ `RecipeMaterializer.create_agent_from_recipe` (`definition_agents.ex:255`)
→ `Ezagent.Entity.Agent.spawn_from_template_content/5`
(`apps/ezagent_domain_agent/lib/ezagent/agent/recipe_materializer.ex:187`)
→ `TemplateSpawn.spawn_from_template_content/5`
(`apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex:241-282`)
→ `Ezagent.Kind.Template.provision_and_instantiate/4` (`template_spawn.ex:549`)
→ the flavor plugin's `instantiate/3`.

The break is structural, at two links:

- `RecipeMaterializer.template_content/2` (`recipe_materializer.ex:45-76`) renders
  the recipe into AgentTemplate content — `skills`, `plugins`, `prompt`, `script`,
  `config` — but **never `recipe.behaviors`**. The field is dropped at the
  content boundary.
- The native flavor's Template Class then spawns with no behavior set:
  `Ezagent.PluginNative.Template.instantiate/3` calls
  `Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})`
  (`apps/ezagent_plugin_native/lib/ezagent/template/native_agent.ex:46`) — nil
  `:kind_base` → the base Agent set only. Its own moduledoc says "the role
  layers its behaviors on per-instance via RF-5a" (`native_agent.ex:16-17`) —
  but RF-5a's `RoleStep` runs **only** on the `agent_create` direct-spawn route;
  nothing on the template route performs the equivalent step.

`Recipe.Compose.materialize/2` has exactly **two** production call sites on main —
`role_step.ex:96` and the cc orchestrator's content-only use
(`apps/ezagent_plugin_cc/lib/ezagent/template/orchestrator_bootstrap.ex:125`, with
`flavor_behaviors: []`). Zero on the template-materialization path.

### 1.3 The observable failure (proven discriminator)

Dispatching a recipe-declared action at a template-materialized native member
fails at **action resolution**, not at any bridge:
`Ezagent.Kind.BehaviorSet.resolve_action/3`
(`apps/ezagent_core/lib/ezagent/kind/behavior_set.ex:262-273`) resolves
static-first via `BehaviorRegistry`, then falls back to the instance's loaded
set; a recipe-declared behavior that is neither statically registered for
`Entity.Agent` nor in the instance's `:kind_base` yields
`{:error, {:unknown_action, action}}` (`behavior_set.ex:269`). Native dispatch is
not bridge-gated (the bridge drop of ② is a separate defect on the *delivery*
side; this one fires even on a direct local dispatch). The #1191 probe confirmed
the materialized member at `:kind_base` with `behaviors: nil` and first dispatch
fail-loud `{:unknown_action, :refresh_page}`. Caps ARE granted on this path
(`definition_agents.ex:167`, `GrantRecipeCaps`) — caps without behaviors: the
member is authorized to do what it structurally cannot resolve.

In-repo witnesses of the defect class: hello's `hello.builder` /
`hello.concierge` recipes declare `behaviors:
[Ezagent.ActionSet.HelloBuilder / HelloConcierge]`
(`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:138,148`)
and their Definition role slots declare `flavor: "native"`
(`ezagent_plugin_hello/app.ex:133-134`) — behaviors that only the recipe carries
and only per-instance loading can supply (`application.ex:163-166` explicitly
retired the static `behaviors/0` rows).

### 1.4 Today's workaround

Operators patch live members with the sanctioned public API
`Ezagent.Kind.mount/3` (`apps/ezagent_core/lib/ezagent/kind.ex:516-544`) —
durable (rewrites the persisted `:kind_base` capture), idempotent,
closure-validated (`kind/mount_detach.ex:72-87,120-130`). ⑬'s verdict: "spawn 时
穿 behaviors（照 Compose）或 install 后自动 mount，任一落地即零手工." This spec
lands the fold structurally so the manual step retires.

---

## 2. Design principle — one composition seam, two consumers

The unit of symmetry is not "both paths call the same spawn function" (they
legitimately differ: direct Kind spawn vs. template/cascade spawn, and that
difference carries real machinery — #17 credential cascade, config_dir
provisioning, rollback). The unit of symmetry is the **composition**: *what a
`(recipe, flavor)` pair means as a behavior set must be computed by exactly one
function, and every materialization path must consume its output.*

```
                ┌──────────────────────────────────────────────┐
                │  ONE composition seam (ezagent_domain_agent)  │
                │  fold(recipe, flavor) :: Compose.materialized │
                │  = flavor decl lookup → flavor behavior set   │
                │    → Recipe.Compose.materialize/2             │
                └──────────────┬───────────────┬───────────────┘
                               │               │
            agent_create --role│               │ socialware Definition
            (RoleStep delegates│               │ (RecipeMaterializer consumes,
             — output shape    │               │  NEW)
             byte-identical)   │               │
                               ▼               ▼
                 spawn args `:behaviors`   behavior OVERLAY through the
                 (unchanged mechanism)     template-spawn seam (§3.2)
```

### 2.1 D1 — lift the fold into a shared function

Extract the resolve-flavor + compose core of `RoleStep.resolve/2`
(`role_step.ex:92-98` + `flavor_behavior_set/1` at `role_step.ex:236-241`) into
one shared function in `ezagent_domain_agent` (the app that already owns
`AgentFlavorRegistry` and `RecipeMaterializer`; `ezagent_domain_workspace`
already compile-depends on it — `RoleStep` aliases `Ezagent.AgentFlavorRegistry`
directly at `role_step.ex:222`).

Signature (illustrative): `fold(%Recipe{}, flavor) :: {:ok,
Recipe.Compose.materialized()} | {:error, {:unknown_flavor_for_role, flavor}}`.

It takes a **`%Recipe{}` struct, not a name**: recipe lookup scoping legitimately
differs per caller (`RoleStep` resolves system-workspace by name,
`role_step.ex:214-218`; `DefinitionAgents` resolves workspace-scoped,
`definition_agents.ex:225-230`) and stays with the caller. The fold owns only
what must be identical: flavor declaration lookup, the flavor behavior set
(`instance_behaviors` thunk else the Kind's nil-capture default), and
`Recipe.Compose.materialize/2`.

`RoleStep.resolve/2` becomes a thin delegate. Its output shape
(`Compose.materialized()` — behaviors/passive/recipe/sandbox_content) and all
downstream consumers (`put_role_behaviors`, `spawn_marker_args`, script merge,
CapMint) are untouched — this is the agent_create regression guard's anchor.

### 2.2 D2 — the template path consumes the fold as a behavior overlay

`RecipeMaterializer.create_agent_from_recipe/1` — the module whose own moduledoc
already names it "the domain-agent boundary that turns that pair into
AgentTemplate content and spawns it" (`recipe_materializer.ex:5-9`), and the
single production caller of the socialware fresh-materialization spawn
(`definition_agents.ex:255` is its only call site) — computes
`fold(recipe, flavor)` and passes the composed behavior list as an explicit
**overlay** option through the existing spawn opts
(`recipe_materializer.ex:181-185` already carries `caller`/`caps`/
`source_template_uri`).

`TemplateSpawn` applies the overlay as a **checked post-spawn step for
freshly-created workers only**, inside the existing fresh-branch obligation
chain (`template_spawn.ex:444-459`): after
`establish_post_spawn_obligations` + `record_sandbox_state`, mount each overlay
behavior not already in the worker's effective set via the same machinery as
`Ezagent.Kind.mount/3` (idempotent, closure-validated, rewrites the persisted
`:kind_base` — `mount_detach.ex:57-87`). An empty/absent overlay is a strict
no-op — **every existing caller of `spawn_from_template_content` (unified
create cc/codex at `agent_create.ex:857`, orchestrator spawn, manifest fallback,
TemplateTeam legacy members at `template_team.ex:115`) passes no overlay and is
byte-identical**.

Why this seam and not the alternatives:

- **Not inside the plugin Template Classes / spawn args.** Threading
  `:behaviors` through content → `to_template_data` → each plugin's
  `instantiate/3` → its own `Kind.spawn` call would change the Template Class
  contract for every flavor plugin (cc, cc-headless, codex, codex-remote, py,
  native, echo, hello) to fix a domain-layer omission. The Template Class owns
  *how the sandbox is loaded* (flavor); the behavior fold is *what the sandbox
  is* (role) — a domain concern. Plugins stay recipe-blind.
- **Not a recipe-aware `TemplateSpawn`.** Keying the fold off the content's
  `role` field inside `spawn_after_cascade` would make the generic spawn seam
  perform workspace-scoped recipe lookups for ALL callers — including the boot
  Loader's cascade-free replay (`template_spawn.ex:152-171`), which runs under
  boot self-authority and is subject to the flavor-registry seal barrier
  (`agent_flavor_registry.ex:135-156`). The overlay keeps `TemplateSpawn`
  recipe-blind: it applies a caller-computed module list, nothing more.
- **Not a post-return `Kind.mount` loop in `DefinitionAgents`.** That would copy
  the fold to a second consumer site outside the shared spawn machinery and
  forfeit the existing all-or-nothing rollback: inside the fresh branch, an
  overlay failure triggers the round-10 teardown (`undo_fresh_workers` +
  `cleanup_partial_config_dirs` + `revoke_cascade_grant_best_effort`,
  `template_spawn.ex:449-458`) — the materialization either yields a member
  with its full dispatch surface or no member at all. A half-surfaced member
  (spawned, joined, caps granted, behaviors missing) is precisely the ⑬ state
  this spec exists to make unrepresentable.

### 2.3 Fresh-only, by principle

The overlay applies only when `fresh?: true` — the same gate as lineage and
workspace binding (`template_spawn.ex:428`, codex round-7: an adopted worker
gets ZERO side effects). Mutating an adopted worker's behavior set would break
that invariant. Consequences accepted: pre-fix broken members are NOT
auto-healed by re-materialize (the repair path skips existing role members
anyway — `definition_agents.ex:101-105` — so there is no auto-heal opportunity
to lose); the sanctioned `Kind.mount/3` remains the operator repair for legacy
members, and `:reuse`-mode slots (`definition_agents.ex:172-189`) continue to
presume a correctly-built agent (provenance-checked at
`ensure_reuse_recipe_match`, `definition_agents.ex:191-196`).

### 2.4 Durability symmetry

Both paths now land the composed set in the same durable place: the instance's
persisted `:kind_base` capture — the agent_create path at spawn
(`put_role_behaviors` → spawn args), the template path via mount's capture
rewrite (`mount_detach.ex:5-7`). Cold restart rehydrates from that capture on
both paths; **no re-fold at revival is needed or performed**, so the
flavor-registry seal barrier and the cold-restart flavor-resolution machinery
are untouched.

---

## 3. Boundary conditions

### 3.1 Flavor matrix and the no-op invariant

**Invariant (fold benignity):** the overlay adds exactly
`composed_behaviors ∖ live_effective_set`. For any flavor whose live set already
contains the composed set, the fix is a strict no-op — mount's membership check
short-circuits per behavior (`mount_detach.ex:78-79`).

| Flavor | Live set at template spawn today | Fold effect |
|---|---|---|
| **native** | base Agent set only (nil `:kind_base`, `native_agent.ex:46`) | **The fix.** `recipe.behaviors` mount; declared actions resolve per-instance (`behavior_set.ex:268-271`). |
| **cc / cc-headless / codex / codex-remote** | flavor wiring via their own Template Classes + bridge adapters (`plugin_cc/application.ex:103-116`); recipe actions for engine-roles execute through the engine/bridge, and shipped engine-role recipes declare no Elixir `behaviors` | Composed set = flavor set ∪ ∅ ⊆ live → **no-op**. A future engine-role recipe that DOES declare Elixir behaviors gets them mounted — forward-consistent with RF-5b (role-on-file-flavor, still deferred on the agent_create side: `role_step.ex:70-76` still fails loud there; this spec does not change that gate). |
| **py** | dedicated Kind → its nil-capture default is the py behavior base; role script rides the template config channel (`agent_create.ex:336-364`) | Base already live → fold adds only role-extra behaviors, if a py recipe ever declares them. Benign. |
| **hello (adapter flavor)** | `instance_behaviors` thunk (`plugin_hello/application.ex:101-103`) — the thunk set is exactly what `fold/2` computes as flavor set | Composed ⊇ live only by the recipe's own behaviors → correct mounts, no duplication (`Enum.uniq` at `compose.ex:66` + mount idempotence). |
| **curl (no template class on the recipe path)** | n/a — `RecipeMaterializer.template_content` fails loud at `template_class_for/1` (`agent_flavor_registry.ex:122-128`) for a flavor without one | Unreachable; unchanged. |

**Adapter invariant (stated):** for adapter/bridge flavors the fix MUST be a
no-op or benign — their delivery wiring (bridge adapters, `:sync_result`
transport) is not touched by this design; the overlay only ever *adds* behaviors
already declared by the role's recipe, never removes or reorders, and never
alters bridge routing.

### 3.2 Layering

- `ezagent_core` — unchanged (`Recipe.Compose`, `Kind.mount`/`MountDetach`,
  `BehaviorSet` already provide everything).
- `ezagent_domain_agent` — gains the shared fold function; `RecipeMaterializer`
  computes + threads the overlay; `TemplateSpawn` applies it (both already live
  here — no new cross-app dependency).
- `ezagent_domain_workspace` — `RoleStep.resolve/2` delegates to the shared
  fold (dependency direction already exists).
- `ezagent_domain_session` — `DefinitionAgents` unchanged in shape (its call at
  `:255` gains nothing new to pass; the recipe and flavor it already passes are
  sufficient).
- Plugins — zero changes. `native_agent.ex` keeps its minimal spawn; its
  moduledoc's "the role layers its behaviors per-instance" finally becomes true
  on this path.

### 3.3 Security / CapBAC

The fold changes NO authorization surface. Caps continue to be minted/granted by
the existing chokepoints (`GrantRecipeCaps` on the template path,
`RoleStep.mint_and_grant_caps` on the create path); per `compose.ex:19-30` caps
are deliberately not composed by the fold. Presence of a behavior in the set
grants no privilege (`behavior_set.ex:257-259` — `authz_check` gates every
action independently). Mounting runs inside the spawn call chain under the same
materialization authority that spawned the worker.

### 3.4 The #1209 seam is preserved

`HostLoginAdopt.ensure_installer_source` runs BEFORE the spawn inside
`materialize_fresh_agent` (`definition_agents.ex:150-155`) so the #17 cascade
resolves the installer's credential source. This design adds nothing before the
spawn and nothing inside `resolve_cascade_content`
(`template_spawn.ex:258-267`) — the overlay applies strictly AFTER the cascade
and the plugin instantiate, in the fresh-branch obligation chain. Ordering of
adopt → cascade → spawn is untouched.

---

## 4. Completion gate — invariant tests

**Gate 1 (the invariant — fails today, passes after):** an integration test
that (a) registers a test recipe declaring a test Behavior with a distinct
action (registered per-instance only — NOT in `BehaviorRegistry` for
`Entity.Agent`, so static-first resolution cannot mask the result), (b) installs
a Definition with one `fill: :agent` role slot `{role_name, recipe, flavor:
"native"}`, (c) materializes via the real path
(`materialize_definition_agents/4` or full session create), and (d) dispatches
the recipe-declared action at the materialized member URI. **Pass = the dispatch
resolves and executes; fail = `{:error, {:unknown_action, _}}`.** Assert also
that the member's effective behavior set ⊇ the fold's composed set.

**Gate 2 (agent_create regression guard):** the direct-spawn role path is
unchanged — (a) `RoleStep.resolve/2`'s output for a fixed `(recipe, flavor)` is
equal before/after the delegation (shape and content), and (b) the existing
RoleStep/AgentCreate test suites stay green with zero modification.

**Gate 3 (adapter benignity):** materializing a role slot under a
template-class flavor whose recipe declares no Elixir behaviors (echo/cc test
double) yields an effective behavior set identical to pre-fix — the overlay
added nothing.

**Gate 4 (durability):** after Gate 1's materialization, a cold restart
(revival from the persisted capture) still resolves the recipe-declared action —
no re-fold, no manual mount.

**Gate 5 (all-or-nothing):** a recipe whose declared behavior fails to mount
(e.g. not a real Behavior) fails the materialization loudly with zero residue —
no live member, no lineage row, no workspace binding, no grant row (the round-10
teardown covers the overlay step).

Per the e2e-failure-earns-unit-test rule, Gate 1 is the fast regression twin of
the #1191 e2e probe.

---

## 5. Relationship to T2

T2 (caller-dispatch adoption for ②③ — native chat delivery and the hello
rebuild entry gate) **depends on this spec landing**. The interface T2 relies
on, stated as a contract:

> **A materialized member's recipe-declared actions are dispatchable at its
> member URI** — immediately after `materialize_definition_agents/4` returns,
> for every materialization path and flavor, `BehaviorSet.resolve_action/3`
> resolves every action declared by the role's recipe behaviors (no
> `{:unknown_action, _}`).

T2 may then route deliveries to role members by dispatching recipe actions
directly, without assuming a bridge adapter exists (the ② native-delivery fix
builds on members whose dispatch surface is complete; it must not have to
special-case "member exists but cannot dispatch its own role's actions").

---

## 6. Out of scope

- **RF-5b** — `--role` on file-flavors via `agent_create` stays rejected
  (`role_step.ex:70-76`). This spec fixes the *socialware template* path, which
  already accepts any flavor per slot.
- **② / ③** — bridge-drop for native chat delivery and the hello rebuild
  sender gate are T2's problem, on top of the §5 contract.
- **Durable recipe/passive slice markers on the template path** —
  `record_launch_attributes` primes volatile ETS only
  (`recipe_materializer.ex:204-211`), while the create path also threads durable
  `:sandbox`-slice markers (`spawn_marker_args`, `role_step.ex:127-134`). An
  adjacent asymmetry (same family as the py durable-flavor-resolution gap), but
  it affects provenance readers, not the dispatch surface — tracked separately,
  not folded into T1.
- **Retro-healing pre-fix members** — deliberate (§2.3); operator `Kind.mount`
  remains sanctioned for legacy repair.

---

## 7. Builder-verify notes (implementation-level; verify during build, not design findings)

1. **Mount-before-ready window.** The overlay applies microseconds after the
   plugin spawn, while the Kind may still be `:not_ready` (the exact window
   documented at `template_spawn.ex:620-640` for the `sandbox.update_config`
   dispatch). `Kind.mount/3` is a direct `GenServer.call` on the pid
   (`kind.ex:537-541`), not an Invocation dispatch, so the ReadyGate `:not_ready`
   fast-fail should not apply — verify empirically; if the mount handler is
   ready-gated after all, sequence the overlay accordingly (do NOT switch it to
   fire-and-forget: Gate 5 requires a checked step).
2. **Overlay option shape.** One opts key (e.g. `:behaviors_overlay`, list of
   modules, default `[]`) on `spawn_from_template_content/5`; assert it is
   list-of-atoms at the boundary. It must NOT ride inside the template content
   map (content is persisted/replayed by the boot Loader — the overlay is a
   spawn-call concern, never persisted content).
3. **Multi-behavior closure ordering.** `MountDetach.mount/5` validates closure
   per single behavior (`prospective = current ++ [behavior]`,
   `mount_detach.ex:120-130`). A recipe declaring two behaviors where A
   `@required_reads` B mounts fine in B→A order but fails A→B; mutually-required
   pairs fail in any single-mount order. Either mount in dependency order or add
   a batch-validate variant. All current in-repo recipe behavior lists are
   single-element (hello ×3, `application.ex:126,138,148`) — confirm before
   deciding whether the batch variant is needed now or noted as a constraint.
4. **Rollback wiring.** Overlay failure must flow through the existing fresh
   branch `else` (`template_spawn.ex:449-458`): `undo_fresh_workers` +
   `cleanup_partial_config_dirs` + `AgentFlavorAttributes.delete` +
   `revoke_cascade_grant_best_effort`. Also confirm `DefinitionAgents` surfaces
   it as `{:agent_spawn_failed, role_name, reason}` (`definition_agents.ex:271-273`)
   — no worker exists to terminate, so the join-cleanup envelope is not involved.
5. **Fold error taxonomy.** Shared fold's `{:error, {:unknown_flavor_for_role,
   flavor}}` must keep `RoleStep.resolve/2`'s existing error atoms verbatim
   (Gate 2 includes error-path parity).
6. **Engine-role recipe audit.** Verify no shipped cc/codex-role recipe declares
   Elixir `behaviors` (the §3.1 "no-op today" claim for engine flavors); if one
   exists, add it to Gate 3's fixtures as a mounted-and-benign case instead.
7. **hello double-wiring.** After the fix, hello builder/concierge (native
   flavor slots) mount `HelloBuilder`/`HelloConcierge` at materialize; the
   `"hello"` flavor's `instance_behaviors` thunk covers the orchestrator only.
   Verify no behavior appears via both channels for the same instance (dedup is
   structural — `compose.ex:66` + mount idempotence — but assert it in Gate 1's
   hello variant if hello fixtures are reused).
8. **`spawn_from_manifest` passthrough.** The manifest fallback path
   (`template_spawn.ex:199-226`) forwards opts via `spawn_fun` — an overlay
   passed by a future manifest caller must survive the passthrough unchanged;
   today no manifest caller passes one (default `[]`).
