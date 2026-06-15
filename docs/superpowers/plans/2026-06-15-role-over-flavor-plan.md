# Role-over-Flavor Implementation Plan (#54)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:test-driven-development per task. Load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` before any edit. Steps use checkbox (`- [ ]`).

**Goal:** Make an agent materialize as `role × flavor` — *role* = the flavor-agnostic sandbox-content recipe (skills/plugins/prompt/behaviors/requested-caps/session-template-ref), a forkable `template://<ws>/role/<name>` Template subtype; *flavor* = the existing `AgentFlavorRegistry` loader (`config_dir` env + kind + bridge). They compose at materialization, with **fail-closed cap authorization** (role caps are *requested*, intersected with flavor/tenant policy — never copied).

**Architecture:** Per `docs/superpowers/specs/2026-06-14-role-over-flavor-design.md` (codex-reviewed, Allen-approved, no open design decisions). Decomposed into two PRs along the lane boundary:
- **PR-1 (core role-Template + composition + fail-closed caps)** — my lane (Template/flavor model, no orchestrator/session-transport dep). The spec §5 "beachhead".
- **PR-2 (orchestrator → `role orchestrator × flavor cc` migration)** — **GATED on coordination with Claude's #58 orchestrator-coupling work**, because it rewrites `orchestrator_bootstrap.ex` + `cc_orchestrator_seed.ex` and touches `Ezagent.Entity.Agent.TemplateSpawn` (`spawn_after_cascade/6`), which is the live agent-spawn/cascade path #58 is actively changing. Do NOT start PR-2 until #58 settles or its owner signs off on the shared-file edits (note them in the PR per the handoff protocol).

**Tech Stack:** Elixir umbrella; `ezagent_core` (Template/flavor registries, Capability chokepoint, Sandbox.ConfigDir), `ezagent_domain_session` (`Ezagent.Behavior.Template` `:instantiate`), `ezagent_domain_agent` (`Entity.Agent.TemplateSpawn` materialization), `ezagent_plugin_cc` (orchestrator bootstrap/seed — PR-2).

---

## Orientation (read before coding)

- **Flavor side (stays):** `apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex` — `flavor → %{kind, template_class, instance_behaviors}`; `agent_flavor_attributes.ex` (per-instance flavor attr); `agent_flavor_resolver.ex`.
- **Composition point (the crux):** `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex` `spawn_after_cascade/6` — resolves flavor → builds Class data (`AgentTemplate.to_template_data/2`) → `Kind.Template.provision_and_instantiate/4` → plugin Class. Role-fills-sandbox composes HERE (after `provision_and_instantiate` allocates the empty `config_dir`, before/around the plugin materializes). NOTE it already threads `:role_degraded` — reuse that channel.
- **Template machinery to reuse:** `apps/ezagent_core/lib/ezagent/kind/template.ex`, `template_registry.ex`, `apps/ezagent_domain_session/lib/ezagent/behavior/template.ex` (`handle_instantiate/2` @ :285). Role-Template is seeded the same way `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex` seeds the cc-orchestrator AgentTemplate (ensure_kind → ensure_sandbox_files → write_template_slice) — but as a forkable `role`-subtype Template.
- **Sandbox installer to generalize (PR-2):** `apps/ezagent_plugin_cc/lib/ezagent/template/orchestrator_bootstrap.ex` installs the orchestrator skill into a cc `config_dir`; `Ezagent.Sandbox.ConfigDir.path/2` is the core (flavor-blind) dir authority. The role's installer must write into "the config_dir" without knowing the loader env.
- **Cap chokepoint (fail-closed §2.3.1):** `Ezagent.Capability.matches?/2` / `Ezagent.Capability` — the sole authority. Role caps are `requested ∩ {flavor/runtime + tenant permit}`; a non-permitted requested cap is REJECTED, never copied.

---

## PR-1 — core role-Template + composition + fail-closed caps

### Task 1: `role` Template subtype + the role recipe

**Files:** Modify `apps/ezagent_core/lib/ezagent/template_registry.ex` (+ wherever the template-kind axis enumerates `agent`/`session` — grep `template_kind`/`:agent.*:session` first); Create `apps/ezagent_core/lib/ezagent/role.ex` (the recipe struct + validation); Test `apps/ezagent_core/test/ezagent/role_test.exs`.

- [ ] **Step 1 — failing test:** `Ezagent.Role.new/1` builds a `%Role{skills, plugins, prompt, behaviors, requested_caps, session_template}` from a content map; rejects a map naming a flavor field (the recipe MUST be flavor-agnostic — spec §2.1). Run, watch fail.
- [ ] **Step 2 — implement** the `%Role{}` struct + `new/1` (defstruct with the 6 recipe fields; `behaviors` defaults `[]`, `requested_caps` defaults `[]`; validate no `:flavor`/`:kind`/`:bridge_adapter` key). Run, watch pass.
- [ ] **Step 3 — register `role` as a Template subtype** (the `template://<ws>/role/<name>` axis) alongside `agent`/`session`; test a role Template URI round-trips. Commit.

### Task 2: `Ezagent.Role.Compose.materialize/2` — role × flavor, fail-closed caps

**Files:** Create `apps/ezagent_core/lib/ezagent/role/compose.ex`; Test `apps/ezagent_core/test/ezagent/role/compose_test.exs`.

- [ ] **Step 1 — failing test (composition):** `Compose.materialize(role, flavor_decl)` returns `%{behaviors: role.behaviors ++ flavor_behaviors, sandbox_content: %{skills, plugins, prompt}, effective_caps: ...}` — assert sandbox_content is flavor-independent (same role → same content for two flavor_decls). Watch fail.
- [ ] **Step 2 — failing test (fail-closed caps, the §2.3.1 + §6 negative test):** a role requesting a cap the flavor/tenant policy does NOT permit has that cap **rejected, not copied** — `effective_caps = requested ∩ policy`. Watch fail.
- [ ] **Step 3 — implement** `materialize/2`: compose behaviors (`role.behaviors ∪ flavor.instance_behaviors`), gather sandbox content, and resolve caps through an explicit `authorize_requested_caps/3` that keeps only caps the flavor-policy + tenant-policy permit (reuse `Ezagent.Capability.matches?/2`; NEVER blanket-copy). Watch pass.
- [ ] **Step 4 — commit.**

### Task 3: wire composition into materialization

**Files:** Modify `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex` `spawn_after_cascade/6` (compose role content into the `config_dir` after `provision_and_instantiate`, before record_sandbox_state); Test an integration test in `apps/ezagent_domain_agent/test/...`.

- [ ] **Step 1 — failing test:** materializing an agent from `(role, flavor=cc)` installs the role's skills/prompt into the allocated `config_dir` and composes its behaviors. Watch fail.
- [ ] **Step 2 — implement** the compose call at the materialization point, writing role content into the flavor-allocated `config_dir` (flavor-blind — via `Sandbox.ConfigDir.path/2`), threading `effective_caps` into the create-time cap mint. Reuse the existing `:role_degraded` meta channel for partial-content-install failures. Watch pass.
- [ ] **Step 3 — run `ezagent_domain_agent` suite; commit.**

### Task 4: completion invariant tests (spec §6)

**Files:** `apps/ezagent_domain_agent/test/ezagent/role_over_flavor_invariant_test.exs`.

- [ ] **same-role-two-flavors:** materialize the SAME role against TWO flavors; assert **sandbox CONTENTS (skills/prompt/behaviors) identical**, loader (config_dir env / kind / bridge) differs.
- [ ] **flavor-validated caps:** assert effective caps are `requested ∩ flavor/tenant policy` (may legitimately DIFFER across flavors — NOT asserted identical).
- [ ] **negative authz (§6):** the role materialized against a flavor that does NOT support a requested cap (e.g. a bridge-driving cap on a no-bridge flavor) has that cap **rejected (fail-closed), not copied**.
- [ ] **commit.**

### Task 5: PR-1 gates

- [ ] `mix compile --force` → `ezagent.arch.scan` → `check_invariants[.lifecycle]` → `doc.scan` (add `@doc`s for new public defs) → full `mix test` (baseline is now GREEN post-#788 — zero failures expected). Update any arch baseline counter the new modules shift (with `# arch-cap-bump:` only if justified). `/codex:adversarial-review` the diff. Self-merge.

---

## PR-2 — orchestrator becomes `role orchestrator × flavor cc` (GATED on #58 coordination)

> **Do NOT start until Claude's #58 orchestrator-coupling work settles or its owner OKs the shared-file edits.** This PR rewrites `orchestrator_bootstrap.ex` + `cc_orchestrator_seed.ex` and touches `TemplateSpawn.spawn_after_cascade/6` — the live agent-spawn path #58 is changing. Detailed task breakdown deferred until that coordination; the shape:

1. Seed `template://system/role/orchestrator` (code-seeded forkable role Template) = {orchestrator skill, orchestrator prompt, orchestrator behaviors/requested-caps, orchestrator session-template ref} — everything `cc_orchestrator_seed.ex` + `orchestrator_bootstrap.ex` install, minus the cc assumption.
2. Rewrite `orchestrator_bootstrap.ex` to consult the role Template + write into *whatever* the flavor's `config_dir` is (flavor-blind installer).
3. Make `Session.ensure_orchestrator` materialize `role orchestrator × flavor cc` (default) — proving "orchestrator role, codex flavor" becomes expressible by installing the same recipe into a `CODEX_HOME` sandbox.
4. Audit the team-routing + orchestrator-readiness paths that assume cc (spec §3 risk surface).
5. Gates + `/codex:adversarial-review` + self-merge; note shared-file edits for #58 rebase.

---

## Self-review

- Spec coverage: §2.1 role-Template (T1), §2.3 composition + §2.3.1 fail-closed caps (T2/T3), §3 orchestrator migration (PR-2), §6 completion invariants incl. negative authz test (T4). §2.4 naming-axis (role as queried attribute) — already served by the unified URI-query (`2026-06-05-unify-uri-query-design.md`); no new work unless a query gap surfaces.
- §2.3.1 is the load-bearing codex finding — caps are a request authorized fail-closed, never copied. T2 Step 2 + T4 negative test pin it.
- Deep-orientation gaps the implementer MUST close before T1/T3: the exact `template_kind` enumeration site (grep), `Behavior.Template.handle_instantiate/2` flow, and the `cc_orchestrator_seed` seed sequence to mirror for a `role` subtype.
- PR-2 is intentionally under-specified pending #58 coordination — not a placeholder failure, a lane-boundary gate.
