# Role-over-Flavor — design (task #54)

> **Design spec.** Direction approved by Allen 2026-06-14 (`agent = role × flavor`).
> Implementation is **sequenced after socialware 基座化 completes (post-PR-9c)** —
> this spec is written now; coding waits. Builds on the current-state analysis
> [`2026-06-14-role-over-flavor-analysis.md`](./2026-06-14-role-over-flavor-analysis.md).
>
> Bilingual mirror: `2026-06-14-role-over-flavor-design.zh_cn.md` (to follow).

## 1. The governing principle (Allen 2026-06-14)

> **The CONTENTS of the sandbox are the ROLE; HOW the sandbox is loaded is the FLAVOR.**

This is exact and code-grounded:

- **Role = sandbox contents.** What goes *into* an agent's `config_dir` (its
  sandbox): skills, plugins, system prompt / `CLAUDE.md` persona, the behavior
  set it runs, its caps, and its session-template wiring. Today this is smeared
  into flavor-specific bootstraps — e.g. `orchestrator_bootstrap.ex` *installs
  the orchestrator **skill** into a cc agent's `config_dir`*. That skill IS the
  role; it has nothing cc-specific about it.
- **Flavor = sandbox loader.** *How* that `config_dir` is provisioned and bound
  into a running runtime: `CLAUDE_CONFIG_DIR` (cc) / `CODEX_HOME` (codex) /
  in-process (curl), plus the `bridge_adapter` and `kind`. This is the existing
  `AgentFlavorRegistry` job and stays as-is.

An agent is materialized by **choosing a role (what fills the sandbox) and a
flavor (how the sandbox is loaded)** — the two compose, independently.

## 2. Design

### 2.1 `Ezagent.RoleRegistry` (new, in `core`, parallel to `AgentFlavorRegistry`)

A declarative `role → sandbox-content recipe`, ETS-backed, same house style as
`AgentFlavorRegistry`. A role decl:

```elixir
%{
  role: "orchestrator" | "reviewer" | "customer-service" | …,  # the role id
  skills: [skill_ref],          # skills installed into the sandbox config_dir
  plugins: [plugin_ref],        # plugins installed into the sandbox
  prompt: prompt_ref | nil,     # system prompt / CLAUDE.md persona fragment
  behaviors: [module()],        # behavior subset the role needs (composed with flavor's)
  caps: [cap_template],         # caps the role's agent holds
  session_template: ref | nil   # session-template wiring (the post-9c-coupled part)
}
```

The role decl is **flavor-agnostic** — none of its fields name cc/codex/curl.

### 2.2 Flavor unchanged

`AgentFlavorRegistry` keeps `{kind, template_class, instance_behaviors,
bridge_adapter}` + the config_dir-load mechanism. No strength removed.

### 2.3 Composition — at materialization

When an agent is created from `(role, flavor)`:
1. **Flavor** provisions the empty sandbox (`config_dir`) + decides the kind +
   the loader env (`CLAUDE_CONFIG_DIR` / `CODEX_HOME` / none).
2. **Role** fills that sandbox: install `skills` + `plugins`, write the `prompt`
   fragment, compose `behaviors` (role's ∪ flavor's), grant `caps`.
3. The flavor's loader binds the now-populated `config_dir` into the runtime.

The `role`-fills-sandbox step is the generalization of today's
`*_bootstrap.ex` installers, made flavor-blind: a role's installer writes into
"the config_dir" without knowing whether it's a `CLAUDE_CONFIG_DIR` or a
`CODEX_HOME`.

### 2.4 The naming axis

An agent URI's name prefix today encodes flavor (`cc_…`, `curl_…`). Role becomes
a separate attribute (queried via the unified URI-query, per
`2026-06-05-unify-uri-query-design.md`), NOT concatenated into the name —
avoids re-entangling identity. (Open sub-decision §4.)

## 3. Migration — the orchestrator is the first Role

`cc-orchestrator` is the load-bearing existing "role". It becomes:
- Role **`orchestrator`** = {orchestrator skill, orchestrator prompt, the
  orchestrator behavior/caps, the orchestrator session-template} — everything
  `cc_orchestrator_seed.ex` + `orchestrator_bootstrap.ex` install, minus the cc
  assumption.
- Flavor **`cc`** = its default (today's only) loader.

So "the orchestrator role, codex flavor" becomes expressible by installing the
same role recipe into a `CODEX_HOME` sandbox. `orchestrator_bootstrap.ex` is
rewritten to consult the RoleRegistry and write into *whatever* the flavor's
config_dir is. Risk surface: the team-routing + orchestrator-readiness paths
that assume cc — audited in the plan.

## 4. Open sub-decisions (for Allen, before the plan)

1. **Role storage — registry vs Template subtype.** A standalone
   `RoleRegistry` (module-declared, like flavors) OR roles as `Template` data
   rows (operator-editable at runtime)? Recommendation: **registry for built-in
   roles + a Template subtype for operator-authored roles** (both resolve to the
   same recipe shape) — mirrors how flavors are code but templates are data.
2. **Composition point.** At template materialization (recommended — keeps the
   role×flavor product as a concrete Template) vs. at spawn. 
3. **Session-template wiring ownership.** The `session_template` field is the
   one role field that touches the `instance_message`→`session` domain — this is
   why impl waits for post-9c. Confirm: role *references* a session-template;
   it does not own session code.
4. **Naming/identity.** Role as a queried attribute (recommended) vs. a second
   name-prefix axis.

## 5. Sequencing

- **Now:** this spec + (after Allen review) the implementation plan.
- **Codex-review gate:** per `feedback_spec_codex_adversarial_review`, run a
  codex adversarial-review on this spec before implementation.
- **Beachhead (optional, post-9c):** land `Ezagent.RoleRegistry` in `core`
  (flavor-side, no session dep) first; wire the `session_template` field only
  after 9c settles the session domain.
- **Implementation:** after 基座化 (PR-9c) is merged + gate-green.

## 6. Definition of done (the invariant)

The completion test (per `feedback_completion_requires_invariant_test`): a test
that **materializes the SAME role against TWO different flavors and asserts the
sandbox contents (skills/prompt/behaviors/caps) are identical while the loader
(config_dir env / kind / bridge) differs.** That test fails today (roles can't
compose across flavors) and passes only when role×flavor truly decouples.

## 7. Cross-references

- Analysis: `2026-06-14-role-over-flavor-analysis.md`.
- `Ezagent.AgentFlavorRegistry` / `Ezagent.Plugin` — the flavor side.
- `apps/ezagent_plugin_cc/lib/ezagent/template/{orchestrator,onboarding}_bootstrap.ex` — today's sandbox-content installers (to generalize).
- `2026-06-05-unify-uri-query-design.md` — URI-as-opaque-id attribute query (for the role attribute).
- North Star: `feedback_north_star_plugin_isolation`.
