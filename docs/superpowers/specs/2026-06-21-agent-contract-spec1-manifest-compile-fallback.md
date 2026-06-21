# spec-1 — AgentManifest + flavor.compile + executor fallback

- **Date:** 2026-06-21
- **Status:** Draft (for codex adversarial review → plan/handoff)
- **Parent design:** `2026-06-21-agent-definition-contract-design.md`
- **Lands on:** `main` (framework layer). Generalizes existing main machinery; autoservice `SoulRenderer`/`CR` are downstream consumers/fixtures.
- **Gates owned:** G1 (manifest re-expression), G2 (backend fallback), G5 (one-field swap).

---

## 1. Scope

**In:**
1. `Ezagent.AgentManifest` — the data schema (author fields + `executor`) + an Elixir validation struct + loader (YAML/map → validated struct).
2. Shared flavor-agnostic **slot render** (`soul + slots → resolved instructions`) at spawn.
3. `flavor.compile(resolved_manifest, params) → {:ok, derived_config} | {:error, _}` callback on each flavor Template Class — generalizes today's `template_data_extra/1` + the rendering inside `instantiate/3`.
4. `executor` = ordered flavor candidate list + author-configurable **fallback policy**; spawn-time try-in-order; `on_exhausted` → notify orchestrator/operator (fail-closed, no orphan).
5. Wire into the **live spawn path** (`Ezagent.Entity.Agent.spawn_from_template_content/4`), replacing ad-hoc flavor-specific slice handling.
6. **Delete `Ezagent.Role.Materialize`** (prototype). **Keep `Ezagent.Role`** until `AgentManifest` replaces `OrchestratorRole.recipe` + bootstrap role install (split — codex P2-6).

**Out (other specs / post-MVP):** `tools[]` + participant (spec-2); versioning/CR pipeline (spec-3); the optional Elixir code builder (post-MVP); ephemeral runtime policy (cheap manifest field here, runtime behavior tracked where `Kind.persistence` lives); orchestrator NL skill; SLA/filler.

---

## 2. Current state on `main` (what we build on)

| Concern | Module / fn | Note |
|---|---|---|
| Template content schema | `Ezagent.Entity.AgentTemplate` `:template` slice (`agent_template.ex:33+`) | the fields we fold into the manifest |
| content → flavor data | `AgentTemplate.to_template_data/2` (`:227`) → `template_class.template_data_extra/1` | the seam `flavor.compile` generalizes |
| cc flavor class | `Ezagent.PluginCc.Template.CcAgent`: `instantiate/3` (`cc_agent.ex:369`), `template_data_extra/1` (`:238`), `ensure_subprocess_alive/2` (`:841`) | reference flavor |
| flavor registry | `Ezagent.AgentFlavorRegistry` `{flavor, kind, template_class, instance_behaviors}` | add nothing structural; `compile` is on the template_class |
| live spawn | `Ezagent.Entity.Agent.spawn_from_template_content/4` (`template_spawn.ex`) | wire point |
| dead vs live | `Role.Materialize` (UNUSED → delete); `Ezagent.Role` (LIVE in `orchestrator_role.ex:1,115` + `orchestrator_bootstrap.ex:70,86` → keep until manifest replaces it) | codex P2-6 |

**Not on main (verify before/at impl):** autoservice `SoulRenderer.full_claude_md` / `Refresh` (soul→`CLAUDE.md`) live on `feat/autoservice-*`. spec-1's `flavor.compile` is the *general* callback; cc's compile body is what `SoulRenderer` becomes. **G1 byte-identity** compares cc.compile output against the autoservice `SoulRenderer` fixture.

---

## 3. Design

### 3.1 Manifest schema (data + validation struct)

Author fields + `executor` exactly as master §4. Elixir struct for validation only (not the stored form):

```elixir
%Ezagent.AgentManifest{
  name: String.t(),
  soul: String.t(),                 # ref to soul.md (or inline) — persona template
  skills: [String.t()],
  tools: [map()],                   # opaque to spec-1; validated/used in spec-2
  caps: [Ezagent.Capability.t()],   # DESIRED caps — granted to the agent's Identity at spawn via the
                                    # Identity grant path; NEVER injected into a dispatch ctx.caps (codex P1-1)
  lifecycle: :persistent | :ephemeral,
  executor: %{flavor: [atom()], params: map(), fallback: [map()] | nil, on_exhausted: atom()}
}
```

- **Loader:** `AgentManifest.load(map_or_yaml) :: {:ok, t} | {:error, reason}`. Validates: required fields; `executor.flavor` non-empty; **no flavor field inside author fields** (the CI grep-gate's runtime twin).
- **Mapping:** the existing `:template` slice fields (`flavor`, `config_dir`, `desired_skills`, `desired_caps`, curl's `provider/model/api_url`) re-home: portable → author fields; `provider/model/api_url` → `executor.params`; `config_dir`/rendered files → derived (not stored).

### 3.2 Slot render (shared, flavor-agnostic, spawn-time)

```elixir
AgentManifest.render(soul_template, slots) :: resolved_instructions   # {{brand_name}} → value
```

Runs once at spawn, **before** `flavor.compile`, because substitution is identical across flavors. Output feeds compile; never stored. (Decision: master §4.1.)

### 3.3 `flavor.compile` callback — **pure render, before the existing validate seam**

```elixir
@callback compile(resolved :: map(), params :: map()) :: {:ok, flavor_data :: map()} | {:error, term()}
```

**Design intent (the boundary decision):** `compile/2` is the **pure rendering** step that turns the resolved manifest into the flavor's **final Template-Class data** — the same data the flavor produces today via `to_template_data/2` + `template_data_extra/1`. It is **pure**: no filesystem writes, no PTY, no grants. It slots **before** the existing validation/materialization seam:

```
manifest + slots ─render(§3.2)─▶ resolved ─flavor.compile─▶ flavor_data ─[existing to_template_data validate]─▶ instantiate (materializes config_dir / PTY, unchanged)
```

So `compile` only formalizes the *render* half of `template_data_extra/1`; the **validation seam and the materialization (config-dir write, PTY launch) stay exactly where they are**. cc.compile ≈ autoservice `SoulRenderer.full_claude_md` as data.

> **Plan-time (not spec):** the exact wiring — whether `compile` returns the layers `to_template_data/2` then validates, or `instantiate`/`HomeRuntime` gains an explicit derived-config materialization hook — is a refactor decision made against the live `template_data_extra/1`/`instantiate/3` code during planning, per the design principles. The spec fixes the *boundary* (pure render → existing validate → existing materialize), not the seam mechanics.

### 3.4 `executor` fallback — wrap the EXISTING spawn path (codex P1-3)

The fallback does **not** invent a `compile → Kind.spawn` path. It loops over candidates calling the **existing** `spawn_from_template_content/4`, whose `fresh?`-gated rollback (`undo_fresh_workers` + `cleanup_partial_config_dirs` + `revoke_cascade_grant_best_effort`, `template_spawn.ex:303-331`) **already self-cleans a failed attempt to zero residue** — so the next candidate starts clean.

```
resolved = render(manifest, slots)                       # shared, pure (§3.2)
for candidate in executor.flavor:
  content = content_for(candidate, resolved)              # candidate-flavored content; instantiate calls candidate.compile
  case spawn_from_template_content(content, agent_uri, spawned_by, workspace, …):
    {:ok, %{fresh?: _}}            -> record AgentFlavorAttributes(agent_uri → candidate); RETURN {:ok, candidate}
    {:error, reason} matching cand fall-through cond -> telemetry {candidate, :fell_through, reason}; continue
                                       # spawn_from_template_content ALREADY cleaned its own residue
    {:error, reason} not matching   -> RETURN {:error, reason}     # hard error, do not mask
all exhausted -> dispatch on_exhausted (notify orchestrator/operator); RETURN {:error, :no_backend}   # fail-closed, NO orphan
```

- Bare `flavor: [cc,codex,curl]` ⇒ fall through on any spawn error. `fallback` gives per-candidate `on:` conditions. `on_exhausted` default `:notify_orchestrator`.
- **`fresh?: false` (adopted)** is a SUCCESS (a live worker already exists at the URI) — return it; the existing path runs no duplicate obligations. The fallback must not re-spawn or re-obligate.
- **Design requirement:** a candidate that falls through leaves **no cross-candidate residue**. It reuses `spawn_from_template_content`'s existing worker rollback; additionally, any per-candidate state written *before* a candidate is confirmed (e.g. the `AgentFlavorAttributes` flavor cache, a config dir) must be **write-on-success** or reset on fall-through. *(Plan-time: enumerate the full residue inventory against the live spawn path and apply the write-on-success discipline — the spec fixes the requirement, not the cleanup list.)*

### 3.5 Wire into the live spawn path

The §3.4 loop lives at the `spawn_from_template_content/4` caller (cold-spawn entry). Each iteration reuses `spawn_from_template_content/4` **as-is** (its lineage/workspace/sandbox obligations + rollback are unchanged). The only new logic is: render slots once, iterate candidates, record the chosen flavor, dispatch `on_exhausted`. The ad-hoc per-flavor branching is replaced by `content_for(candidate, resolved)` + the flavor's pure `compile` inside `instantiate`.

### 3.6 Retire Role — **split** (codex P2-6)

`Ezagent.Role` is NOT dead: it is live in orchestrator bootstrap (`orchestrator_role.ex:1,115`, `orchestrator_bootstrap.ex:70,86`). So:
- **spec-1 deletes ONLY `Ezagent.Role.Materialize`** (prototype, no live caller — confirm by grep/test before deleting).
- **`Ezagent.Role` stays** until `AgentManifest` replaces `OrchestratorRole.recipe` + the bootstrap role install. That replacement is a **follow-up within spec-1's tail** (or a small spec-1b), gated on the cc-orchestrator still spawning. No back-compat shim once replaced (SPEC §5.11).

---

## 4. Invariants / CI gates

- **G-INV-1** Author fields contain no flavor field — `mix ezagent.check_invariants` grep-gate + loader validation.
- **G-INV-2** `derived_config` is never written back into a stored manifest.
- **G-INV-3** Fallback exhaustion is fail-closed: no agent Kind left alive without a chosen flavor; `on_exhausted` always dispatched.
- **G-INV-4** Spawn still records lineage (`AgentLineage`) + `WorkspaceRegistry.bind` (invariant #4) on success **only for `fresh?: true`** (reuse `spawn_from_template_content`'s existing gate; `fresh?: false` = adopted, no obligations).
- **G-INV-5** `flavor.compile/2` is **pure** — no filesystem write, no PTY, no grant. Side effects stay in `instantiate`/`spawn_from_template_content`.
- **G-INV-6** A failed/exhausted fallback candidate leaves **no cross-candidate residue** — the worker (via the existing rollback) AND any pre-confirm per-candidate state (flavor cache, config dir) are write-on-success or reset on fall-through. (Residue inventory enumerated at plan-time.)

---

## 5. VERIFICATION

### E2E (driven via `mix ezagent`, no raw RPC)
- **G1** — re-express `seed_autoservice` fast(curl)+slow(cc) from declarative manifests; the curl `system_prompt` / cc `CLAUDE.md` produced by `compile` are **byte-identical** to autoservice `SoulRenderer`/`Refresh` output (golden fixture compare).
- **G2** — manifest `flavor:[cc,codex,curl]`; inject cc unavailable → lands codex; inject codex failure → lands curl; inject all-fail → `on_exhausted` dispatch to operator, **no orphan agent**, telemetry shows try-order.
- **G5** — flip a manifest `flavor: cc → codex`, re-spawn → equivalent agent, codex-compiled config on disk.

### Unit / integration
- `AgentManifest.load/1` — accept valid; reject flavor-in-author-fields, empty `executor.flavor`, missing required.
- `AgentManifest.render/2` — slot substitution incl. missing-slot behavior (decide: error vs leave-as-is).
- per-flavor `compile/2` golden tests (cc, curl) against fixtures.
- fallback policy eval — order, conditions, exhaustion.
- spawn integration with injected compile/spawn failures → fall-through + no orphan.

### Falsifiers (must stay red)
- a flavor field in the author bucket passes the loader; derived config persisted into the manifest; an orphan agent after fallback exhaustion; **a failed fallback candidate leaving a config dir / lineage row / grant** (residue); a `compile/2` that writes disk or launches a PTY; a `fresh?: false` adopted worker getting duplicate lineage/bind.

---

## 6. Dependencies & risks

- **autoservice fixture** for G1 byte-identity lives on `feat/autoservice-*` — pull the `SoulRenderer` golden output before G1.
- **Missing-slot policy** (error vs passthrough) — pick in impl; document.
- **`OrchestratorRole` reframe** — its current `Role`-based seeding must emit a manifest instead; verify the cc-orchestrator still spawns.
- Shared (master §15): SessionTemplate vs AgentTemplate naming.
