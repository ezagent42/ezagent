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

At the TEMPLATE INPUT layer (`AgentTemplate` content), make the two intents explicit.

> **DECISION UPDATE (Allen 2026-06-03): `config_dir` PROMOTED to UNIVERSAL.**
> The original PR-2 kept `config_dir` cc-flavor-owned with the cc-named data key
> `"claude_config_dir"` (and flagged the ambiguity below). The maintainer has since
> decided the CONCEPT "every agent has a per-agent config home directory" is
> UNIVERSAL — every flavor (cc/codex/curl/echo/np) gets a `config_dir`. Only the
> CONTENTS / file-format are flavor-specific (cc reads it as `CLAUDE_CONFIG_DIR` +
> writes `.claude.json`/`settings.json`/`.credentials.json`; codex/curl/echo use it
> per their own format). This is consistent with approach B: the DIRECTORY concept is
> universal; the cc FILE FORMAT stays cc-owned. The universal base now emits a
> flavor-NEUTRAL `"config_dir"` data key; the cc-named `"claude_config_dir"` data key
> is REMOVED (no back-compat shim — cc `validate/1` fails loud on it; DB wiped +
> rebuilt).

| Concern | Before | After (post-decision) |
|---|---|---|
| project cwd (universal) | `working_directory` | **`project_cwd`** (universal) → `"cwd"` data key |
| config home (universal) | `claude_config_dir` | **`config_dir`** (universal) → **`"config_dir"`** neutral data key (cc reads it for `CLAUDE_CONFIG_DIR`) |

### Why these choices

- **`project_cwd` is UNIVERSAL** (every flavor needs a cwd) → `"cwd"` data key
  (unchanged).
- **`config_dir` is UNIVERSAL** (every flavor has a per-agent config home) → the
  flavor-NEUTRAL `"config_dir"` data key. The cc Template Class READS this neutral
  key and applies its claude semantics (`CLAUDE_CONFIG_DIR`, the per-agent copy, the
  claude file format). The cc-specific FILE FORMAT stays cc-owned (flavor extras:
  `settings_path`/`mcp_config_path`/`api_key_helper`/`role`).
- **The data key `"config_dir"` is neutral** — it does NOT leak the cc-specific name
  into universal data emitted for curl/codex/echo. The old cc-named
  `"claude_config_dir"` data key is renamed to `"config_dir"` at every consume site
  (cc `build_claude_config_env/2` / `create_agent_config_dir/2`, the
  `--from` clone override in `Behavior.Workspace`, the Sandbox `respawn_template_data`).
- No back-compat shims (`feedback_let_it_crash_no_workarounds`): rename at every call
  site; DB is wiped+rebuilt. `to_template_data/2` returns `:missing_project_cwd` for a
  missing cwd and `{:error, {:invalid_config_dir, _}}` for a malformed (present but
  not a non-empty binary) config_dir; cc `validate/1` returns
  `{:error, {:stale_config_dir_key, "claude_config_dir", _}}` on a stale template.

## Files to change

- `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent_template.ex` — type, moduledoc,
  `to_template_data/2` (`fetch_working_directory` → `fetch_project_cwd`,
  `:missing_working_directory` → `:missing_project_cwd`), mapping table.
- `apps/ezagent_domain_instance_message/lib/ezagent/behavior/template.ex` — universal-fields moduledoc.
- `apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/cc_orchestrator_seed.ex` — seed content
  (`working_directory:` → `project_cwd:`, `claude_config_dir:` → `config_dir:`).
- `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex` — moduledoc references.
- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` — config_dir promotion:
  `template_data_extra/1` NO LONGER emits config_dir (it's universal now); the consume
  path (`build_claude_config_env/2`, `create_agent_config_dir/2`, `@optional_sandbox_keys`)
  reads the neutral `"config_dir"` data key; `validate/1` fails loud on a stale
  `"claude_config_dir"` key.
- `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex` — `--from` clone
  override writes the neutral `"config_dir"` data key.
- `apps/ezagent_core/lib/ezagent/{home/migration.ex,kind/template.ex,behavior/sandbox.ex}`
  — moduledoc references to the config-home data key.
- Mix demo seed task `ezagent.demo.seed_cc_sandbox.ex` — content field rename.
- All affected tests (agent_template_test, template_test, fork_lineage, e2e fixtures, etc).

## TDD order

1. Update `agent_template_test.exs` to the new field names + new error atom; add an
   explicit "project_cwd vs config_dir" intent test. Run → red.
2. Implement rename in agent_template.ex + cc_agent.ex. Run → green.
3. Sweep the remaining producers (seed, demo task) + tests. Full suite green.
