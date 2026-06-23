# Agent-contract backend slice: echo→Entity.Agent + soul-into-create Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Deliver the two *real* (consumer-backed) parts of Allen's agent-contract directive: (A) make the `echo` flavor ride the shared `Entity.Agent` (so it gains Identity → can receive caps, like cc/codex/curl), and (B) make agent **create** accept and actually apply `soul` for the **cc** flavor (rendered into CLAUDE.md at spawn). Everything else Allen named (`skills`/`tools`/`lifecycle`/`desired_caps`, codex-soul) is a documented blocker — no runtime consumer exists; adding it to create would be a silent no-op.

**Architecture:** echo copies the **curl precedent** — instead of its own `Entity.Echo` Kind, echo spawns as `Entity.Agent` with an `echo_behaviors()` instance-behavior set threaded at spawn. soul rides the **existing manifest route**: the cc create branch builds an inline `%AgentManifest{}` and goes through `AgentManifest.to_template_content/4` → `spawn_from_template_content` → cc `compile` (which already renders instructions into `claude_md`).

**Tech Stack:** Elixir/OTP umbrella (apps: ezagent_core, ezagent_domain_agent, ezagent_domain_workspace, ezagent_domain_session, ezagent_plugin_echo, ezagent_plugin_cc, ezagent_cli), CapBAC, Behavior/Kind, AgentManifest.

## Global Constraints
- Branch `agent-contract-echo-soul` (off `origin/main`). Backend-only; does NOT touch the world React UI (that's PR #905). Cross-link: this PR's body links #905 + #904; after creating it, update #905's body to link back (no PR lost).
- **No live `:echo` grants exist** (not in production) — confirmed by the owner — so the `:echo→:agent` cap-kind change needs **no migration**; just change the axis.
- **The echo persistence change `:ephemeral → {:snapshot, :on_change}` is a real semantic change** (echo agents start writing snapshots). Must be **emphasized in the PR description**.
- DB-backed tests: run with `POSTGRES_PORT=5432` (host pg; role `ezagent_pg_compat` exists). Format only touched files (`mix format <file>`). `uv run` not python; `pnpm` not npm.
- **Documented blockers (do NOT wire into create — no runtime consumer):** `skills` (`desired_skills` not read by any plugin install path — `kind/template.ex:509` writes `manifest_tools` with no reader; cc skills come from orchestrator role only), `tools`, `lifecycle` (parsed `agent_manifest.ex:264`, no runtime branch), `desired_caps` (deferred PR-5 #533), and **codex `soul`** (compile writes `"instructions"` `kind/template.ex:475` but no confirmed codex runtime reader). These are surfaced as precise blockers in the PR, not built.

---

## Phase A — echo flavor rides `Entity.Agent` (curl pattern)

### Task A1: `Entity.Agent` declares `echo_behaviors/0` + Echo in its superset

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex` (`behaviors/0` ~line 86; add `echo_behaviors/0` after `curl_behaviors/0` ~line 120)
- Test: `apps/ezagent_domain_agent/test/ezagent/entity/agent_test.exs` (create if absent)

**Interfaces:**
- Produces: `Ezagent.Entity.Agent.echo_behaviors/0 :: [module()]` = `base_behaviors() ++ [Ezagent.Behavior.Echo]`; `behaviors/0` superset now includes `Ezagent.Behavior.Echo`.

- [ ] **Step 1: Failing test**
```elixir
test "echo_behaviors is base + Echo, and behaviors/0 superset includes Echo" do
  echo = Ezagent.Entity.Agent.echo_behaviors()
  assert Ezagent.Behavior.Identity in echo
  assert Ezagent.Behavior.Echo in echo
  assert Ezagent.Behavior.Echo in Ezagent.Entity.Agent.behaviors()
  # nil-capture default must NOT include Echo (cc/codex unaffected)
  refute Ezagent.Behavior.Echo in Ezagent.Entity.Agent.nil_capture_behavior_set()
end
```
- [ ] **Step 2: Run, expect fail** — `POSTGRES_PORT=5432 mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_test.exs -k "echo_behaviors"` → FAIL (undefined `echo_behaviors`).
- [ ] **Step 3: Implement**
```elixir
# agent.ex — behaviors/0 (~line 86): add Behavior.Echo to the declared superset
def behaviors, do: base_behaviors() ++ [Ezagent.Behavior.CurlAgent, Ezagent.Behavior.Echo]

# new fn after curl_behaviors/0 (~line 120)
@spec echo_behaviors() :: [module()]
def echo_behaviors, do: base_behaviors() ++ [Ezagent.Behavior.Echo]
```
Leave `nil_capture_behavior_set/0` (~line 129) = `base_behaviors()` unchanged (echo excluded from default, same as curl).
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit** — `feat(agent): Entity.Agent.echo_behaviors + Echo in superset (echo rides Entity.Agent)`

### Task A2: `Behavior.Echo.required_caps` kind axis `:echo` → `:agent`

**Files:**
- Modify: `apps/ezagent_plugin_echo/lib/ezagent/behavior/echo.ex:81-89` (`required_caps/0`)
- Test: `apps/ezagent_plugin_echo/test/ezagent/behavior/echo_test.exs:56-57`

- [ ] **Step 1: Update the test assertion** to expect `:agent`:
```elixir
assert caps.say.kind == :agent
assert caps.receive.kind == :agent
```
- [ ] **Step 2: Run, expect fail** — `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_echo/test/ezagent/behavior/echo_test.exs` → FAIL (`:echo != :agent`).
- [ ] **Step 3: Implement** — in `required_caps/0` change the cap kind axis:
```elixir
say: Ezagent.Capability.cap(:agent, __MODULE__, :say),
receive: Ezagent.Capability.cap(:agent, __MODULE__, :receive)
```
(No grant migration needed — no live `:echo` grants per Global Constraints.)
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit** — `fix(echo): required_caps kind axis :echo -> :agent (echo is now Entity.Agent)`

### Task A3: echo plugin registers against `Entity.Agent` + threads `echo_behaviors`

**Files:**
- Modify: `apps/ezagent_plugin_echo/lib/ezagent_plugin_echo/application.ex` (`behaviors/0` ~line 88-93; `agent_flavors/0` ~line 100-108)

**Interfaces:**
- Consumes: `Ezagent.Entity.Agent.echo_behaviors/0` (A1).

- [ ] **Step 1: Change behavior registrations** — every `{Ezagent.Entity.Echo, action, Ezagent.Behavior.Echo}` (`:say`/`:receive`/`:write`) → `{Ezagent.Entity.Agent, action, Ezagent.Behavior.Echo}`.
- [ ] **Step 2: Change the flavor declaration** — in `agent_flavors/0`: `kind: Ezagent.Entity.Echo` → `kind: Ezagent.Entity.Agent`, and add `instance_behaviors: &Ezagent.Entity.Agent.echo_behaviors/0` (mirroring curl app `application.ex:131`).
- [ ] **Step 3: Verify compile** — `POSTGRES_PORT=5432 mix compile --warnings-as-errors` clean.
- [ ] **Step 4: Commit** — `feat(echo): register echo flavor against Entity.Agent + echo_behaviors thunk`

### Task A4: echo template spawn threads `:behaviors` (the silent-broken-agent fix)

**Files:**
- Modify: `apps/ezagent_plugin_echo/lib/ezagent/template/echo_agent.ex` (`ensure_agent_kind/1` ~line 193-212)
- Test: `apps/ezagent_plugin_echo/test/ezagent/template/echo_agent_test.exs`

**Why:** `ensure_agent_kind/1` spawns via `SpawnRegistry.spawn_detailed(agent_uri)` WITHOUT `:behaviors`. On `Entity.Agent` that falls to `nil_capture_behavior_set/0` (base only — NO Echo) → an echo agent with Identity but no Echo behavior. Must thread `behaviors: echo_behaviors()`.

- [ ] **Step 1: Read the current `ensure_agent_kind/1` + how `SpawnRegistry.spawn_detailed` accepts args** (`grep -n "def spawn_detailed" apps/ezagent_core/lib/ezagent/spawn_registry.ex`). Confirm the arity that accepts spawn args (`/2` with an args map, or fall back to `Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, behaviors: ...})`).
- [ ] **Step 2: Failing test** — spawn an echo agent through the template path and assert the running Kind has `Behavior.Echo` in its instance behavior set (mirror the existing echo_agent_test spawn assertion; assert a `:say` dispatch succeeds, which requires Echo behavior to be present).
- [ ] **Step 3: Run, expect fail** (echo agent missing Echo behavior → `:say` unknown_action).
- [ ] **Step 4: Implement** — thread the behavior set:
```elixir
defp ensure_agent_kind(agent_uri) do
  args = %{uri: agent_uri, behaviors: Ezagent.Entity.Agent.echo_behaviors()}
  case Ezagent.SpawnRegistry.spawn_detailed(agent_uri, args) do
    # ...existing match clauses...
  end
end
```
(If `spawn_detailed` has no args-accepting arity, use `Ezagent.Kind.spawn(Ezagent.Entity.Agent, args)` directly, matching curl's `curl_agent.ex:144,154` pattern.)
- [ ] **Step 5: Run, expect pass.**
- [ ] **Step 6: Commit** — `fix(echo): thread echo_behaviors at template spawn (avoid Echo-less agent)`

### Task A5: resolver maps `"echo"`→`Entity.Agent`; delete `Entity.Echo`

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/agent_module_resolver.ex:119`
- Delete: `apps/ezagent_plugin_echo/lib/ezagent/entity/echo.ex`

- [ ] **Step 1:** change `kind_module_from_kind_type("echo"), do: Ezagent.Entity.Echo` → `Ezagent.Entity.Agent` (defensive; echo was ephemeral so no snapshot rows, but keep the mapping correct).
- [ ] **Step 2:** `git rm apps/ezagent_plugin_echo/lib/ezagent/entity/echo.ex`.
- [ ] **Step 3: Compile + grep** — `POSTGRES_PORT=5432 mix compile --warnings-as-errors` clean, and `grep -rn "Ezagent.Entity.Echo" apps/ --include=*.ex | grep -v test` returns **nothing** (all production refs gone).
- [ ] **Step 4: Commit** — `refactor(echo): resolver -> Entity.Agent; remove Entity.Echo Kind`

### Task A6: update tests that hard-code `Entity.Echo` / `kind :echo`

**Files (per the exploration):**
- `apps/ezagent_core/test/invariants/plugin_hot_install_test.exs` (~lines 74, 78, 99)
- `apps/ezagent_plugin_echo/test/integration/plugin_contract_test.exs` (~lines 41, 45, 58-64)
- `apps/ezagent_plugin_echo/test/ezagent/template/echo_agent_test.exs` (~line 277)
- `apps/ezagent_core/test/ezagent/capability_test.exs` (~line 222 — verify whether it asserts echo-as-Kind or is a generic fixture; only change if it binds to `Entity.Echo`)

- [ ] **Step 1:** Replace `Ezagent.Entity.Echo` → `Ezagent.Entity.Agent` in the assertions above; where a test spawns echo directly via `Kind.spawn(Entity.Echo, …)`, change to `Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, behaviors: Ezagent.Entity.Agent.echo_behaviors()})`. Leave generic `kind: :echo` *fixture* atoms in identity-grant tests that aren't about the echo Kind (judge per test).
- [ ] **Step 2: Run the touched test files** — `POSTGRES_PORT=5432 mix test <each file>` → all pass.
- [ ] **Step 3: Commit** — `test(echo): align assertions to Entity.Agent`

### Task A7: E2E — echo agent is `Entity.Agent`, has Echo, and can receive caps

**Files:** none (verification); evidence note under `docs/superpowers/notes/`.

- [ ] **Step 1:** Full echo + agent test run — `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_echo apps/ezagent_domain_agent/test/ezagent/entity/agent_test.exs` → green.
- [ ] **Step 2:** Real create via CLI — `POSTGRES_PORT=5432 mix ezagent.agent.create --flavor echo --name demo-echo-$(…)` then grant a cap (or create with `--caps chat.send`): confirm `grant_initial_caps` **succeeds** (previously `{:grant_failed, _, {:unknown_action, :grant_cap}}` because echo lacked Identity). Capture the agent URI + the successful grant.
- [ ] **Step 3:** Record the evidence (CLI output) in the notes dir + the PR body.

---

## Phase B — `soul` into create for the cc flavor (manifest route)

### Task B1: `coerce_create_args/1` accepts optional `:soul`

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex:64-90`
- Test: `apps/ezagent_domain_workspace/test/ezagent/behavior/workspace/agent_create_test.exs` (the existing create test file; create a focused test if absent)

**Interfaces:**
- Produces: create args carry an optional `soul :: String.t() | nil`; threaded to `do_create_agent`. Only `soul` is added — NOT skills/tools/lifecycle (blocker).

- [ ] **Step 1: Failing test** — call the coerce/handle path with `%{flavor: "cc", name: "x", cwd: <tmpdir>, soul: "你是导购"}` and assert `soul` survives into the params passed to `do_create_agent` (assert via a unit test on `coerce_create_args/1` if it's testable, else via the manifest content in B2's test).
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — add `soul = Map.get(args, :soul) || Map.get(args, "soul")` in `coerce_create_args/1`; thread it (extend the returned tuple/map + `do_create_agent` signature). Keep it optional (`nil` default) and string-or-nil validated.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit** — `feat(workspace): create accepts optional soul (threaded, cc only)`

### Task B2: cc create branch builds an inline `%AgentManifest{}` so soul → CLAUDE.md

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex` (the cc/codex file-flavor branch ~lines 274-352; `file_flavor_template/4` ~449-458)
- Reference (do not modify): `apps/ezagent_core/lib/ezagent/agent_manifest.ex:113-145` (`to_template_content/4`), `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex:181,313` (`spawn_from_template_content`), `apps/ezagent_core/lib/ezagent/kind/template.ex:453,466` (cc compile writes `claude_md`).

**Interfaces:**
- Consumes: `soul` from B1.
- Produces: when `soul` is present for **cc**, the create path routes through manifest content (carrying `agent_manifest_resolved.instructions`) instead of the bare `file_flavor_template/4`, so the spawned cc agent's CLAUDE.md contains the rendered soul.

- [ ] **Step 1: Read** the cc branch + `to_template_content/4` + how `spawn_from_template_content` consumes content. Decide the minimal seam: for cc with `soul`, build `%AgentManifest{name: name, soul: soul, skills: [], tools: [], caps: [], lifecycle: :persistent, executor: %{flavor: ["cc"], params: %{project_cwd: cwd, config_dir: <derived>}, fallback: nil, on_exhausted: :notify_orchestrator}}` and call `AgentManifest.to_template_content/4` to get the content map; pass that to the existing `register_and_invoke_template`/cascade path. When `soul` is nil, keep the current `file_flavor_template/4` (no behavior change).
- [ ] **Step 2: Failing test** — create a cc agent with `soul: "你是前台导购"`; assert the registered template content / resulting compiled data carries the soul as `claude_md` (assert on `to_template_content` output, or on the template-data map produced by the cc compile path). RED first.
- [ ] **Step 3: Run, expect fail.**
- [ ] **Step 4: Implement** the inline-manifest seam for the cc `soul`-present case.
- [ ] **Step 5: Run, expect pass** + `POSTGRES_PORT=5432 mix test apps/ezagent_domain_workspace` green (no regression to the soul-absent path).
- [ ] **Step 6: Commit** — `feat(workspace): cc create routes soul through manifest -> CLAUDE.md`

### Task B3: CLI `--soul` flag

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex` (`OptionParser` ~line 115; `build_create_args/1` ~line 246)

- [ ] **Step 1:** add `soul: :string` to the `OptionParser` strict opts; in `build_create_args/1` put `soul` into the args map when present.
- [ ] **Step 2: Verify** — `POSTGRES_PORT=5432 mix ezagent.agent.create --flavor cc --name demo-soul --cwd <tmpdir> --soul "你是前台导购"` runs; the created agent's config dir CLAUDE.md contains the soul text (read the file).
- [ ] **Step 3: Commit** — `feat(cli): ezagent.agent.create --soul flag`

### Task B4: E2E — cc agent created with soul boots with it in CLAUDE.md

**Files:** none (verification + evidence note).

- [ ] **Step 1:** CLI-create a cc agent with `--soul`; locate its per-agent config dir; confirm `CLAUDE.md` contains the soul (this is the real consumer per `home_runtime.ex:293`). Capture the path + content snippet.
- [ ] **Step 2:** Record evidence in the notes dir + PR body.

---

## Documented blockers (PR body — precise, no parallel storage)
- `skills` / `tools` / `lifecycle` / `desired_caps`: accepted nowhere in create on purpose — **no runtime consumer** (`desired_skills` unread by install paths; `manifest_tools`/`manifest_mcp_servers` written `kind/template.ex:509` with no reader; `lifecycle` parsed `agent_manifest.ex:264` with no runtime branch; `desired_caps` deferred PR-5 #533). Each needs a consumer built first — separate tasks for Allen to prioritize.
- **codex `soul`**: cc has a confirmed consumer; codex compile writes `"instructions"` (`kind/template.ex:475`) but no confirmed codex runtime reader — soul is **cc-only** this slice; codex-soul is a flagged follow-up.
- **echo persistence**: `:ephemeral → {:snapshot, :on_change}` — emphasized as a deliberate semantic change.

## Self-Review
- **Coverage:** Allen's "Entity.Echo→Entity.Agent" → Phase A (A1-A7). "soul in create / CLI+前端 同源" → Phase B (B1-B4; CLI flag in B3; frontend soul field deferred to #905 to avoid touching `Identities.tsx` here). "skills/tools/lifecycle/CRUD modify-delete" → documented blockers (no consumer) / future tasks. No silent gaps — each unbuilt item is a stated blocker.
- **Placeholders:** none — each task has concrete file:line + code/commands. A4-Step1 and B2-Step1 are explicit *read-then-implement* seams (the spawn-args arity / the manifest seam), not vague TODOs.
- **Type consistency:** `echo_behaviors/0` defined A1, consumed A3/A4/A6; `soul` added B1, consumed B2/B3. Cap kind `:agent` consistent A2↔A6.
