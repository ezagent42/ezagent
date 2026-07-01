# Decision: Default PM / Dev-Together Recipe Ownership

Owner: jjkysy
Date: 2026-07-01
Source PR: https://github.com/ezagent42/ezagent/pull/1110 (integration branch `feat/kanban-agent-e2e`)
Scope: this decision gates the #1110 split (PR C). It records the chosen
ownership model for the `pm-coordinator` and `dev-together` role-agents and
locks the boundary that the agent domain (`ezagent_domain_agent`) hardcodes NO
product recipe. It carries no runtime `.ex` code — the code consequences land in
PR B (generic substrate), PR D (kanban), and PR E (docs/persona).

---

## Problem

#1110 introduced `Ezagent.Agent.DefaultRecipes` + `Ezagent.Agent.DefaultRecipeSeed`
into `ezagent_domain_agent` as a **single "unified entry"** that owns both the
`pm-coordinator` and `dev-together` role-as-data recipes and boot-seeds them
(recipe ConfigObject + `cc × <role>` AgentTemplate) into the `RecipeRegistry`.

The open question raised in `jjkysy-split-pr-1110.md`:

> whether `pm-coordinator` and `dev-together` are ezagent platform defaults or
> kanban / dev-together product policy. Until that is decided, `DefaultRecipes`
> should not be merged casually into `ezagent_domain_agent`.

The "unified entry in the agent domain" framing makes two product agents into
platform defaults that boot-seed on every install, regardless of whether the
kanban product or a dev-together workflow is in use. That is an ownership
inversion: `ezagent_domain_agent` is the generic agent runtime, not a product.

---

## Decision — user-config ownership model

**The agent domain hardcodes no product recipe. Product recipes are owned by the
product plugin that reads their data; generic agents are user configuration, not
platform defaults.**

Concretely:

1. **`pm-coordinator` → kanban plugin `roles/0` (PR D).**
   pm-coordinator is the kanban product's coordinator agent (a `cc`-flavor
   role-as-data that drives the 9-stage team dev flow over the CLI). It belongs
   next to `kanban-manager` in `EzagentPluginKanban.Application.roles/0`, seeded
   through the existing `RoleSeedHook` → `RecipeRegistry` seam. Its board-scoped
   caps are minted at the `GrantRecipeCaps` chokepoint via
   `cap_instance_overrides` (board URI), keyed by the resolved `Ezagent.Behavior.Kanban`
   module. This is `role-as-data` on a legitimate `plugin → domain` arrow — no
   new mechanism.

2. **`dev-together` → user-configured generic agent, NOT a hardcoded recipe.**
   dev-together is the team dev-workflow SKILL (`.claude/skills/dev-together/`,
   issue → test → PR) run by a generic `cc`-headless brain. It is not the
   definitional agent of any plugin. Under the user-config model it is created by
   the user through the "create agent" surface (mount the `dev-together` skill,
   pick caps/routing), not baked into a platform recipe. Until an agent-config UI
   exists, dev-together is at most a **clearly-labeled demo / e2e fixture** (owned
   by the evidence/guide docs, PR E), or simply not seeded. It must never be a
   `ezagent_domain_agent` default recipe.

3. **`DefaultRecipes` / `DefaultRecipeSeed` are NOT introduced into
   `ezagent_domain_agent`.**
   - `apps/ezagent_domain_agent/lib/ezagent/agent/default_recipes.ex` — dropped.
   - `apps/ezagent_domain_agent/lib/ezagent/agent/default_recipe_seed.ex` — dropped.
   - their two tests — dropped.
   - `ezagent_domain_agent`'s `application.ex` keeps main's `start/2` (no
     `DefaultRecipeSeed.seed_all()` boot hunk).
   - `ezagent_plugin_cc`'s `application.ex` keeps main's `after_boot` (no
     `DefaultRecipeSeed.seed_templates_all()` hunk).
   base = `upstream/main` never had these, so this is a **non-introduction**,
   provable by grep (see Verification).

4. **agent-config UI is the real follow-up.**
   The proper landing for dev-together (and any user-defined generic agent) is a
   UI where the user creates an agent, mounts a workflow skill, and configures
   routing under least-priv caps. That is out of scope for this split and tracked
   as a follow-up.

---

## What stays generic (PR B substrate — unchanged by this decision)

The generic per-session materialization substrate stays purely mechanism, with
**zero compile dependency on any plugin product recipe**:

- `SessionAgentMaterialize.materialize_by_role/4` / `by_role_spec/4` resolve a
  recipe by its string **NAME** through `RecipeRegistry.lookup/…` at runtime.
- `DefaultAgentSeed` is the generic `cc × <role>` template-seed engine +
  `default_project_cwd` / `template_content` generators.
- `GrantRecipeCaps` is the single sanctioned cap-grant chokepoint (materialize-
  time deliberate grant, never boot auto-grant), and applies `cap_instance_overrides`
  after string → module resolution.

For an unregistered role the generic path returns `{:error, {:role_not_registered, role}}`
(fail-closed, LOUD) — it never silently no-ops. With dev-together not seeded, any
dev-together auto-materialize degrades to this fail-closed branch (logged +
telemetry), which is a harmless downgrade, not a silent failure.

---

## Least-priv cap sets (now owned by kanban / user config, documented here)

Recorded so the cap sets are traceable when PR D inlines the pm recipe into
kanban and when a user configures dev-together. These are **starter least-priv**
sets (Allen to confirm final set; see `phase3-pm-spec.md` open decision). Every
cap is a `%{behavior:, action:}` map with no `kind` axis (minted at
materialization); behaviors are named by **STRING** so the agent domain keeps
zero compile dep on either plugin.

**pm-coordinator** (`passive: false`, `skills: ["pm-coordinator"]`, `behaviors: []`):

| behavior | actions |
|---|---|
| `Ezagent.Behavior.Kanban` (board ops) | `get_tree`, `add_node`, `set_stage`, `claim_node`, `set_status`, `attach_artifact`, `register_pr` |
| `Ezagent.Behavior.Github` (gateway reads) | `create_issue`, `post_comment`, `get_pull` |

**dev-together** (`passive: false`, `skills: ["dev-together"]`, `behaviors: []`):

| behavior | actions |
|---|---|
| `Ezagent.Behavior.Kanban` (node ops) | `get_tree`, `claim_node`, `set_status`, `attach_artifact`, `register_pr` |
| `Ezagent.Behavior.Github` (gateway reads/writes) | `create_issue`, `post_comment`, `get_pull`, `create_commit_status` |

### `project_cwd` semantics

`project_cwd` is the CLI-reachability sandbox root of a role-agent. It is read
generically by the by-role materialize path (`recipe config[:project_cwd]`, added
only when an operator opts in, so the seeded body stays byte-identical and avoids
`{:role_seed_collision, …}`):

- pm-coordinator: opt-in `:ezagent_domain_agent, :pm_coordinator_cwd`, else the
  generic `~/.ezagent/pm-coordinator` sandbox default. (Under this decision the
  opt-in namespace moves with the recipe to kanban; PR D owns and tests it.)
- dev-together: opt-in `:dev_together_cwd`, else `~/.ezagent/dev-together`. Owned
  by user config / demo fixture, not a domain default.

The `project_cwd` behavior is documented here; the tests land in PR D (kanban pm)
per Allen's acceptance requirement ("project_cwd behavior documented and tested").

---

## Invariants

This decision **preserves** boundaries rather than adding a violation:

- **P9 (reads-what-data decides tier ownership).** pm-coordinator's data (kanban
  board ops) is read by the kanban product → it belongs in the kanban plugin.
  dev-together is generic user config, not owned data of the agent domain.
- **P12 (plugin-specific code lives in the plugin).** The pm-coordinator recipe
  lives in `ezagent_plugin_kanban`; `ezagent_domain_agent` keeps ZERO compile
  dependency on any plugin behavior. The generic substrate resolves recipes by
  string NAME at runtime through `RecipeRegistry`.
- **Not touched:** P14 (dispatch is the only path between Kinds) — this decision
  is data-ownership only, no new dispatch/PubSub path.

---

## Verification (PR C's own gate)

- Non-introduction grep returns empty:
  `git grep -nE 'DefaultRecipes|DefaultRecipeSeed' apps/ezagent_domain_agent apps/ezagent_plugin_cc`
- `ezagent_domain_agent` takes no compile dependency on any plugin
  (`mix xref` / deps check).
- The generic by-role fail-closed test (`{:error, {:role_not_registered, role}}`)
  stays green with dev-together unseeded.
- `ezagent_domain_agent` boot test stays green with no `seed_all()`.

---

## Downstream constraints (handoff)

- **PR B** must strip every dangling `DefaultRecipes` / `DefaultRecipeSeed`
  reference from moduledocs/comments in `session_agent_materialize.ex`,
  `default_agent_seed.ex`, and the `grant_recipe_caps` mix task, and keep the
  substrate generic (resolve by string NAME). Drop the two boot-seed hunks.
- **PR D** must inline the pm-coordinator recipe (cap set above) into
  `EzagentPluginKanban.Application.pm_coordinator_recipe/0`, add it to `roles/0`
  next to `kanban_manager_recipe()`, drop the `alias Ezagent.Agent.DefaultRecipes`
  in `PmCoordinatorSeed`, route materialize through PR B's
  `by_role_spec/4` + `cap_instance_overrides`, and decide the fate of
  dev-together auto-materialize in `connectors.ex` (keep boot-safe fail-soft, or
  remove — PR D body states the choice and awaits Allen/user confirmation). Fix
  the `ezagent_web/mix.exs` comment that claims role-as-data converges into
  `DefaultRecipes`.
- **PR E** must rewrite the guide sections that describe `DefaultRecipes` /
  `DefaultRecipeSeed` as the "unified entry" to the final ownership, mark the
  2026-06-30 grill-refactor handoff/return as superseded, and date-stamp the
  `t14-boot-seed-forensics.txt` evidence as captured on the pre-split #1110
  branch.

---

## Proposed GLOSSARY Decision Log entry (Allen to land — NOT edited here)

GLOSSARY.md is Allen-maintained; this decision only proposes the following row
for §1 Decision Log (next number #156), to be landed by Allen:

> **#156 — Recipe ownership = user-config model, no `DefaultRecipes` in
> `ezagent_domain_agent`.** pm-coordinator recipe is owned by the kanban plugin
> (`roles/0`, board-scoped caps via `GrantRecipeCaps`); dev-together is
> user-configured generic agent config (demo/e2e fixture until an agent-config UI
> exists), not a platform default. The agent domain keeps zero compile dep on any
> plugin; the materialize substrate resolves recipes by string NAME through
> `RecipeRegistry`. (2026-07-01, superseding the 2026-06-30 grill-refactor
> "unified `DefaultRecipes` entry" direction.)

---

## Follow-up (out of this split)

- **agent-config UI** — user creates an agent, mounts a workflow skill (e.g.
  dev-together), configures routing under least-priv caps. This is the formal
  landing for dev-together and any user-defined generic agent.
