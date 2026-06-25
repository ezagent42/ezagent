# py-agent Implementation Plan

> **For agentic workers:** implement task-by-task; each task ends with an
> independently testable deliverable + its own PR (TDD, four-property DoD,
> precommit/check_invariants/arch.scan green, rebase, codex review, lead
> verify+merge). Based on `py-agent-flavor-spec.md` rev3 (2 adversarial rounds).
>
> **rev2 (2026-06-25)** — folds the plan's own adversarial review (against
> c4de8a62). Key changes: (HIGH-1) P2 now sweeps `echo_default` runtime deps
> (boot seed + OpenAI plug + web home), not just the narrow grep; (HIGH-2)
> Tasks 1.3/1.4 rebuilt on the canonical `Kind.Template.provision_and_instantiate`
> + `"config_dir"` reference seam (not manual allocation), which also surfaces
> the template-edit script-injection gate as P1 scope; (HIGH-3) `Entity.PyAgent`
> is named as P1-only scaffolding the native+`py`-role pattern (kanban precedent)
> supersedes in P4; (MED-1) Task 1.1 is a parametrizing refactor onto
> `Domain.Python.start_subprocess(%Spec{})`, not a pure move; (MED-2) adds the
> operator-cap-denial test.

**Goal:** `py` — a general agent flavor whose per-message logic is an
operator-supplied python script run via `Ezagent.Domain.Python`; `echo` retires
into it; `np` re-homes as a py-role (fast-follow).

**Architecture:** own-Kind `Entity.PyAgent` (mirrors np) + a per-agent
`config_dir` script file-channel built at create + a shared
`Domain.Python.AgentLifecycle` extracted from np. Operator-only authorship
(CapBAC at create); script immutable post-create.

**Tech Stack:** Elixir umbrella, `Ezagent.Domain.Python` (JSON-RPC stdio +
`ezagent_python` lib), the role-foundation (RF-1..9 on main).

## Global Constraints (verbatim from spec)

- Wire: `Domain.Python.call(handle, "receive", params, timeout)` (arity-4,
  method-named); script uses `@method`/`run()`. `configure`/`reset` stay
  BEAM-side `{:set,_}` effects (no python-side handlers).
- Security posture A: operator-only authorship (CapMint fail-closed at create);
  script set ONLY at create, immutable via configure/clone/fork/mount/template-
  edit (each must re-assert the create-cap). OS-sandbox deferred.
- own-Kind `Entity.PyAgent` for P1; native+behavior-via-role is future.
- Script delivered via per-agent `config_dir` (NOT plugin priv-dir — that would
  be "np with a different script").
- Each phase = its own PR. Lead verifies + merges; no self-merge.

---

## Phase 1 — the file-channel + the `py` flavor (the core)

**File structure (new `apps/ezagent_plugin_py/`, mirror `ezagent_plugin_np`):**
- `lib/ezagent_plugin_py/application.ex` — plugin contract (`agent_flavors/0`
  `"py"`, `behaviors/0`, `template_classes/0`, `config_surface/0`, `children/0`).
- `lib/ezagent/behavior/py_agent.ex` — `Behavior.PyAgent`.
- `lib/ezagent/entity/py_agent.ex` — `Entity.PyAgent` Kind.
- `lib/ezagent/template/py_agent.ex` — `Template.PyAgent` (instantiate →
  install script to config_dir + start subprocess).
- `priv/python/echo.py` — the P2 echo script (shipped here as the first script).
- Shared: `apps/ezagent_domain_python/lib/ezagent/domain/python/agent_lifecycle.ex`.

### Task 1.1 — Extract `Domain.Python.AgentLifecycle` (DRY, round-2 MED-1)

**Files:** Create `apps/ezagent_domain_python/lib/ezagent/domain/python/agent_lifecycle.ex`;
Test `apps/ezagent_domain_python/test/agent_lifecycle_test.exs`.

**Interfaces — Produces:** `ensure_alive(handle, %Spec{}, cwd)`,
`subscribe_phase(handle)`, `phase_from_signal(state, signal)` — built ON TOP of
the real `Domain.Python.start_subprocess(%Spec{})` (`python.ex:144`), not a new
spawn API. **This is a parametrizing refactor, NOT a pure move (round-2 plan
MED-1):**
- `ensure_subprocess_alive/2` is a `@behaviour Ezagent.Kind.Template` callback
  (`template.ex:179`) — it stays on each Template, delegating to the shared
  helper (the Template still implements the callback).
- `np_agent.ex:445-448` `do_ensure_python_alive` hard-codes
  `Ezagent.PluginNp.Template.NpAgent.ensure_subprocess_alive(...)` — a
  behavior→template **back-reference** that MUST be broken (parametrize the
  Template module / pass a builder) so py can consume the shared path.
- `start_python/2` (`template/np_agent.ex:214-260`) is np-specific (script_path
  → np_compute_server.py, `ping_timeout_ms: 120_000`, `test_mode_override/0`,
  np env). The shared helper takes a caller-built `%Spec{}` (script_path,
  command, env, timeouts) — np and py each build their own `%Spec{}`.

- [ ] Write failing test: `ensure_alive` with a py-built `%Spec{}` spawns a live
  Domain.Python child for a given script_path; idempotent; `subscribe_phase`
  returns a transient token; `phase_from_signal` maps `:starting|:running|:dead`.
- [ ] Extract phase-subscription + phase-signal + an `ensure_alive(%Spec{})`
  helper into the shared module; break the behavior→template back-ref.
- [ ] **Smaller-blast-radius default: py builds its own `%Spec{}` + consumes the
  shared helper; DEFER np's refactor onto it to P4** (np keeps its copy until
  then — avoids risking the tested np suite in P1). Choose in PR.
- [ ] new lifecycle test green (+ np suite green if np refactored now). Commit.

### Task 1.2 — `Behavior.PyAgent` (sibling of np, `"receive"` method)

**Files:** Create `lib/ezagent/behavior/py_agent.ex`; Test
`apps/ezagent_plugin_py/test/py_agent_behavior_test.exs`.
**Consumes:** `Domain.Python.AgentLifecycle` (1.1), `Domain.Python.call/4`.

- [ ] Failing test: `:receive` with a stub script handle dispatches
  `call(handle, "receive", %{text,from,session}, timeout)` and on a non-nil
  reply emits a `chat.send` `{:dispatch,%Cmd{}}`; a raising script → `last_error`
  set, no crash; `:configure` sets `timeout_ms` only (NOT script); `:reset`
  clears `last_*`.
- [ ] Implement (use `Ezagent.Lifecycle`; state = python_handle/script_path/
  timeout_ms/cwd/last_*/python_phase; transient = phase subscription via 1.1;
  `activate/2` re-spawns from script_path on every start).
- [ ] `required_caps/0` → `:py_agent` cap axis for `:receive|:reset|:configure`.
- [ ] Tests green. Commit.

### Task 1.3 — `Entity.PyAgent` Kind + `Template.PyAgent` on the canonical config_dir seam (round-2 plan HIGH-2)

**Files:** Create `lib/ezagent/entity/py_agent.ex`, `lib/ezagent/template/py_agent.ex`;
Test `apps/ezagent_plugin_py/test/py_template_test.exs`.

> **Use the canonical seam, do NOT hand-roll allocation.**
> `Ezagent.Kind.Template.provision_and_instantiate/4` (`template.ex:328`) is the
> chokepoint EVERY instantiate routes through (incl. `Workspace.Loader.invoke_template`,
> `loader.ex:184` — the non-cascade path echo uses). When a template carries a
> `"config_dir"` reference, `maybe_allocate_config_dir/2` (`template.ex:349-361`)
> calls `Ezagent.Sandbox.ConfigDir.allocate(agent_uri, config_dir_namespace())`
> and passes the realized path to `instantiate/3` as `"allocated_config_dir"`.
> So py rides this, not a manual `do_create_agent` allocation.

**Produces:** `Template.PyAgent` declares a `"config_dir"` reference +
`config_dir_namespace/0 → "py"`; `instantiate(uri, config, ctx)` reads
`"allocated_config_dir"`, writes `config.script` to `<config_dir>/agent.py`,
starts the subprocess (via 1.1's `ensure_alive(%Spec{script_path})`).

- [ ] Failing test: `provision_and_instantiate` for a py template with
  `config = %{script: "<src>", timeout_ms}` allocates a config_dir, writes
  `agent.py` == src, starts a live subprocess, records `script_path` in the
  slice. Cold-restart (terminate→reload) → `activate/2` re-spawns from the
  installed file.
- [ ] Implement Kind (mirror `Entity.NpAgent`: supervisor/0, slice) + Template
  (config_schema `script`+`timeout_ms`; `config_dir_namespace/0`; `"config_dir"`
  reference; instantiate writes script + starts subprocess via 1.1). **py is a
  NEW shape: non-credentialled (no `CredentialAdapter` → must NOT route through
  `spawn_file_flavor_via_cascade`, `agent_create.ex:870`) yet config-dir-
  allocating via the Loader/`provision_and_instantiate` path** — call this out.
- [ ] Tests green. Commit.

### Task 1.4 — `py` flavor decl + create route via the Loader seam (round-2 HIGH-C + plan HIGH-2)

**Files:** Create `lib/ezagent_plugin_py/application.ex`; Modify
`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex`
(`do_create_agent("py", ...)` → `register_and_invoke_template` like echo
`:364`, NOT the generic direct-spawn route `:467/:513/:605` which skips
`instantiate` + drops cwd; flavor whitelist `:138` + `validate_*`); Modify
`apps/ezagent_web/mix.exs` (dep) + `single_spawn_entry` allowlist if a child is
added; Test `apps/ezagent_plugin_py/test/py_create_e2e_test.exs`.

- [ ] **Failing test (closes np's gap): create a py-agent via the real create
  path (`Workspace.create_agent`, flavor "py", operator script) → assert the
  Domain.Python subprocess is LIVE after create** (not just the Kind spawned) +
  `:receive` replies end-to-end.
- [ ] Add `agent_flavors/0`→`"py"`→`{Entity.PyAgent, Template.PyAgent}` + the
  plugin decl (mirror np application.ex).
- [ ] Add `do_create_agent("py", ...)` via `register_and_invoke_template`
  (Loader path → `provision_and_instantiate` auto-allocates config_dir, 1.3) —
  the operator `script` flows through the template config. Add `"py"` to the
  whitelist `:138` + `validate_cwd_for_flavor`/`validate_flavor`.
- [ ] precommit + check_invariants + arch.scan green (`no_flavor_refs_in_core` —
  flavor logic stays in plugin/domain). Commit.

### Task 1.5 — security: create-cap denial + script-injection gate (round-2 plan HIGH-2 + MED-2)

**Files:** Test `apps/ezagent_plugin_py/test/py_security_test.exs`; possibly
Modify the template-edit / re-instantiate path.

- [ ] **Failing test (MED-2): a NON-operator caller** (lacking the recipe's
  `requested_caps`) **→ create fails fail-closed** (no subprocess, no agent) —
  proves CapMint authorship gating (`role_step.ex` `{:held_by, caller}` +
  `cap_mint.ex` fail-closed).
- [ ] **Failing test (injection gate, P1 not P4): a template-edit /
  re-`provision_and_instantiate`** that rewrites `agent.py` **MUST re-assert the
  create-cap** — a caller without it cannot mutate the installed script. (The
  script now being persisted template-data + an installed file makes
  template-edit a real injection path — round-2 plan HIGH-2; spec §5 requires
  gating it in P1.) `configure`/`reset` already cannot touch the script
  (BEAM-side `{:set}` only) — assert that too.
- [ ] Implement the re-assert gate; tests green. Commit. **PR: Phase 1.**

**P1 DoD:** create a py-agent with a custom operator script via the real create
path → subprocess live → `:receive` replies in a session; cold-restart
re-spawns; `configure` cannot mutate the script; all gates green.

---

## Phase 2 — echo → py + delete `ezagent_plugin_echo`

**Files:** ship `priv/python/echo.py` (`@method("receive")` returns the text);
Modify the full surface (regenerate mechanically, LOW-1 below); Delete
`apps/ezagent_plugin_echo/`.

> **LOW-1 — regenerate the surface mechanically, do NOT hand-list.** The §3
> list drifted (rev1 stale lines) + is incomplete. At impl time run
> `git grep -in 'echo\.agent\|Behavior.Echo\|Entity.Echo\|EchoAgent\|ezagent_plugin_echo' apps/`
> (~37 files on c4de8a62) AND the `echo_default` sweep below; migrate every hit.
> Omitted-in-§3 lib spots include `behavior_registry.ex`, `kind/server.ex`,
> `mix/tasks/ezagent.stress.ex`, `domain_instance_message/application.ex`,
> `workspace/store.ex`, `mix/tasks/ezagent.agent.create.ex`, `ezagent_plugin_cc/mix.exs`.

> **HIGH-1 (round-2 plan) — the `echo_default` RUNTIME deps the narrow gate is
> BLIND to.** Deleting echo removes a live default agent several endpoints
> depend on; the `Behavior.Echo`-pattern gate passes anyway. MUST handle:
> - `ezagent_plugin_echo/application.ex:140-167` — `after_boot/0` seeds
>   `entity://agent/system/echo_default` every boot. → **re-seed a default
>   py-agent** (`py_default` with `echo.py`) in py's `after_boot/0`.
> - `ezagent_plugin_protocol_api/.../openai_chat_plug.ex:14,126-133` —
>   `@default_agent_name "echo_default"` + `maybe_register_default_echo/1` on the
>   OpenAI `/v1/chat/completions` endpoint. → **re-point to `py_default`**.
> - `ezagent_web/.../home_live.ex:149` — `echo_uri = URI.agent(:system, :echo_default)`.
>   → **re-point to `py_default`**.
> - `api_v1_controller.ex:27`, `uri.ex:907` — doc/example strings → update.
> **Second parity sweep:** `git grep -in 'echo_default' apps/` == 0 (or each
> survivor re-pointed to `py_default`).

- [ ] Failing test: an echo-equivalent py-agent (script=echo.py) echoes a chat
  message in a session.
- [ ] Re-seed `py_default` (py's `after_boot/0`) + re-point OpenAI plug +
  home_live + doc strings (HIGH-1). World E2E seed (task #75) → py-agent.
- [ ] Migrate every `Behavior.Echo`-pattern hit (regenerated list, LOW-1) incl.
  `agent_create.ex:138` whitelist, `agent_module_resolver.ex`, `world/identity_data.ex`,
  `check_invariants` scope path (note: deletion makes its `2>/dev/null` grep a
  SILENT stale scope, not a red gate — update for hygiene).
- [ ] Re-home the 3 core teaching examples (`behavior.ex:22`, `capability.ex:9-10`,
  `plugin.ex:22-27`) to py; update the 4 core invariant tests referencing echo.
- [ ] Delete `apps/ezagent_plugin_echo/` + dep refs (mix.exs, allowlists).
- [ ] **Parity gates (BOTH):** `git grep -il 'echo\.agent\|Behavior.Echo\|
  Entity.Echo\|EchoAgent\|ezagent_plugin_echo' apps/` == 0 AND `git grep -in
  'echo_default' apps/` == 0 (modulo an explicitly-allowlisted retained role
  name). precommit/check_invariants/arch.scan green. **PR: Phase 2.**

**P2 DoD:** both parity gates == 0; `ezagent_plugin_echo` gone; the OpenAI
endpoint + web home + boot seed all point at a live `py_default`; world + core
suites green.

---

## Phase 3 — world E2E

- [ ] agent-browser E2E: create a py-agent with a custom script in world → it
  replies in a session (screenshot). The world seed's former echo agent is a
  py-agent. **PR: Phase 3** (or fold into P2 if small).

---

## Phase 4 — role-script channel + retire own-Kind → native+role + np → py-role

> **HIGH-3 (round-2 plan) — `Entity.PyAgent`/`Template.PyAgent` are P1-only
> SCAFFOLDING, not durable architecture.** The end-state (spec §0.1) is
> py-as-`native`+`py`-role, exactly the kanban-as-role precedent now on main
> (`ezagent_plugin_kanban/application.ex:47-75`: role × `native` → unified
> `Entity.Agent` + behavior per-instance; subprocess would live in the
> behavior's `activate/2` via 1.1's shared `AgentLifecycle`, runnable on the
> unified Kind). own-Kind is a defensible P1 simplification ONLY because the
> role-script channel (RF-5b) isn't built — but P1 ships a 3rd per-subprocess
> Kind (cc-pty, np, py) right as the repo consolidates onto native+role. P4
> tears it down.

- [ ] Extend `Role.Compose` `sandbox_content` with a `script`/file field +
  `RoleStep` install to config_dir (the general RF-5b content channel) — so a
  ROLE carries its script. Re-assert create-cap on clone/fork/mount/template-edit
  (spec §5 / round-2 plan HIGH-2 vectors — the same gate P1's 1.5 lands for the
  template path, extended to the role path here).
- [ ] **Retire `Entity.PyAgent`/`Template.PyAgent`**: migrate `py` to
  `native` + a `py` behavior layered per-instance via the role (kanban pattern);
  the subprocess self-heals in the behavior's `activate/2` (1.1 `AgentLifecycle`).
  Migrate py refs off the own-Kind; delete the own-Kind + Template.
- [ ] np re-homes as a `py`-role: `np_compute_server.py` verbatim (whitelist
  intact) → a `np` py-role; migrate np refs; delete `ezagent_plugin_np` with its
  own parity gate. np keeps working until this lands.
- [ ] If 1.1 deferred np's `AgentLifecycle` refactor, complete it here. **PR(s): Phase 4.**

**P4 DoD:** a py-ROLE carries its script (sandbox_content channel); `py` runs as
`native`+role (own-Kind retired — no 3rd per-subprocess Kind); np works as a
py-role (numpy/sympy suite green, whitelist intact); `ezagent_plugin_np` gone;
np parity gate == 0.

---

## Self-Review (writing-plans)

- **Spec coverage:** every spec §0.2/§1/§2/§3/§4/§5 maps to a task (file-channel
  →1.3/1.4+4; wire→1.2; lifecycle extract→1.1; create route→1.4; echo→P2;
  security→1.2/1.4 caps + P4 vectors; np→P4). ✓
- **Placeholders:** the 1.1 np-refactor-now-vs-P4 choice is an explicit
  decision flagged in the task, not a placeholder. ✓
- **Type consistency:** `Domain.Python.AgentLifecycle` signatures (1.1) are
  consumed by 1.2/1.3 as named; `instantiate/3` (1.3) consumed by 1.4. ✓
- **User-assist steps:** P3 agent-browser E2E is agent-run (no human step). ✓
