# PR-2 Plan — Split `AgentTemplate.working_directory` → `project_cwd` vs sandbox config_dir

## Problem (from maintainer 2026-06-03)

`AgentTemplate.working_directory` (universal template field, maps to the `"cwd"` data
key — required) has an ambiguous name that **conflates two intents**:

1. **project_cwd** — the working/project directory the agent process runs in / `cd`s into.
2. **config_dir** — the agent's sandbox config home (`CLAUDE_CONFIG_DIR`, holds
   creds/settings/.claude.json).

## Current state (verified against source, not the brief)

- `working_directory` (universal) → `"cwd"` data key. REQUIRED. This is the **only**
  thing it maps to: project cwd. It does NOT currently feed any config dir. The
  conflation is therefore **semantic (the NAME)**, not structural.
- `claude_config_dir` (cc flavor-owned, via `CcAgent.template_data_extra/1`) →
  `"claude_config_dir"` data key. OPTIONAL. This is a **reference** config dir the
  cc spawn path copies from / falls back to.
- At spawn, `CcAgent.create_agent_config_dir/2` allocates the **per-agent**
  `agent_config_dir` → written into `Sandbox` slice `config_dir_path` via
  `sandbox.write_path`. THAT is "the config_dir" (the runtime realization).
- `"cwd"` is a **universal** data key consumed by EVERY flavor Template Class
  (cc/codex/echo/np) + Workspace.create_agent + the LV agent_new form +
  Sandbox `respawn_template_data`. It is NOT cc-specific.

## Target

At the TEMPLATE INPUT layer (`AgentTemplate` content), make the two intents explicit:

| Concern | Before | After |
|---|---|---|
| project cwd (universal) | `working_directory` | **`project_cwd`** (universal) → `"cwd"` data key (unchanged data key) |
| config_dir input (cc) | `claude_config_dir` | **`config_dir`** (cc flavor-owned) → `"claude_config_dir"` data key (unchanged data key) |

### Why these choices

- **Rename only the TEMPLATE CONTENT field names** (`working_directory` → `project_cwd`;
  `claude_config_dir` → `config_dir`). The downstream **data keys** (`"cwd"`,
  `"claude_config_dir"`) are NOT renamed — they are the universal flavor-Template-Class
  contract consumed by 5+ modules and stored in the Sandbox respawn data. Renaming
  them is out of scope (much larger blast radius; not what "split the template field"
  means) and would touch the runtime sandbox shape PR-3 owns.
- `project_cwd` stays UNIVERSAL (every flavor needs a cwd).
- `config_dir` stays FLAVOR-OWNED (cc only). Per SPEC 2026-06-01-flavor-generic-template-data
  (approach B): curl/codex have no external config dir; config_dir is a cc concept.
  Promoting it to universal would violate that recent decision. **Flagged ambiguity below.**
- No back-compat shims (`feedback_let_it_crash_no_workarounds`): rename at every call
  site; DB is wiped+rebuilt. The error atom becomes `:missing_project_cwd`.

## DESIGN AMBIGUITY for the maintainer

The brief says "make the two intents explicit at the template layer: project_cwd vs
the config_dir input." But per the flavor-generic SPEC (2026-06-01, approach B),
`config_dir` is a **cc-flavor** concept, not universal — curl/codex/echo/np carry no
external config dir. So the two intents do NOT live at the same layer:

- `project_cwd` → UNIVERSAL base field (correct home).
- `config_dir` → cc FLAVOR-OWNED field (`CcAgent`), NOT universal.

This PR makes both explicit but keeps `config_dir` flavor-owned. If the maintainer
instead wants `config_dir` promoted to a universal template field (so the
template-layer split is symmetric), that contradicts approach B and is a larger
change — flagged, NOT guessed. Picked the structural option consistent with the most
recent locked decision.

## Files to change

- `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex` — type, moduledoc,
  `to_template_data/2` (`fetch_working_directory` → `fetch_project_cwd`,
  `:missing_working_directory` → `:missing_project_cwd`), mapping table.
- `apps/ezagent_domain_chat/lib/ezagent/behavior/template.ex` — universal-fields moduledoc.
- `apps/ezagent_domain_chat/lib/ezagent/orchestrator/cc_orchestrator_seed.ex` — seed content
  (`working_directory:` → `project_cwd:`, `claude_config_dir:` → `config_dir:`).
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` — moduledoc references.
- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` — `template_data_extra/1`
  reads `:config_dir` content field (still emits `"claude_config_dir"` data key).
- Mix demo seed task `ezagent.demo.seed_cc_sandbox.ex` — content field rename.
- All affected tests (agent_template_test, template_test, fork_lineage, e2e fixtures, etc).

## TDD order

1. Update `agent_template_test.exs` to the new field names + new error atom; add an
   explicit "project_cwd vs config_dir" intent test. Run → red.
2. Implement rename in agent_template.ex + cc_agent.ex. Run → green.
3. Sweep the remaining producers (seed, demo task) + tests. Full suite green.
