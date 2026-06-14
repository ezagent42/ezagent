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

### 2.1 Role is a **Template subtype** (Allen 2026-06-14 — NOT a new registry)

A Role is a first-class **Template** (the template-kind axis gains `role`
alongside `agent` / `session`): a persisted, URI-addressed
(`template://<ws>/role/<name>`), **forkable** Template whose content is the
sandbox-content recipe:

```elixir
# template content of a `template://<ws>/role/<name>`:
%{
  skills: [skill_ref],          # skills installed into the sandbox config_dir
  plugins: [plugin_ref],        # plugins installed into the sandbox
  prompt: prompt_ref | nil,     # system prompt / CLAUDE.md persona fragment
  behaviors: [module()],        # behavior subset the role needs (composed with flavor's)
  caps: [cap_template],         # REQUESTED caps — authorized fail-closed at materialization (§2.3.1), not copied
  session_template: ref | nil   # a REFERENCE to a session-template (role does not own session code)
}
```

The recipe is **flavor-agnostic** — none of its fields name cc/codex/curl.

**Why a Template subtype, not an `AgentFlavorRegistry`-style registry?** (Allen's
question, 2026-06-14.) Both *can* be code-declared — built-in roles are
code-**seeded** Templates exactly as `cc-orchestrator` is seeded today. The
difference is not "code vs not-code"; it is *what the thing is at runtime*:

| | registry (flavor) | Template subtype (role) |
|---|---|---|
| storage | code-only, boot-time **ETS** lookup | **persisted** DB row + snapshot |
| identity | a string key | a `template://` **URI** |
| runtime authorability | none — change = code + redeploy | **operators fork / edit / create** roles at runtime |
| lifecycle / caps / ownership / versioning | none | full Template lifecycle (fork is a generic Template concern) |
| creation path | direct register | the **creation-unification** chokepoint |

A **flavor** is genuinely static wiring (transport adapters are code), so a
registry fits. A **role** is *product-level content an operator should author* —
"what the agent does" — so it must be first-class data, not a frozen code table.
Role-as-Template reuses the whole Template machinery (fork, caps, snapshot,
creation-unification) instead of reinventing it. (This supersedes the analysis
doc's "registry + Template subtype" both-option — Allen chose Template-only.)

### 2.2 Flavor unchanged

`AgentFlavorRegistry` keeps `{kind, template_class, instance_behaviors,
bridge_adapter}` + the config_dir-load mechanism. No strength removed.

### 2.3 Composition — at materialization

When an agent is created from `(role, flavor)`:
1. **Flavor** provisions the empty sandbox (`config_dir`) + decides the kind +
   the loader env (`CLAUDE_CONFIG_DIR` / `CODEX_HOME` / none).
2. **Role** fills that sandbox: install `skills` + `plugins`, write the `prompt`
   fragment, compose `behaviors` (role's ∪ flavor's).
3. **Caps are resolved through a fail-closed authorization step — NOT copied**
   (see §2.3.1).
4. The flavor's loader binds the now-populated `config_dir` into the runtime.

The `role`-fills-sandbox step is the generalization of today's
`*_bootstrap.ex` installers, made flavor-blind: a role's installer writes into
"the config_dir" without knowing whether it's a `CLAUDE_CONFIG_DIR` or a
`CODEX_HOME`.

### 2.3.1 Cap composition is fail-closed (codex adversarial-review, 2026-06-14)

A role's `caps` are **requested** caps, not granted ones. Blindly copying a
role's cap templates onto an agent regardless of flavor/runtime/tenant would be
a CapBAC hole ("never weaken authz") — e.g. the orchestrator role requests a
PTY/bridge-driving cap that is meaningless (and must not be silently granted) on
a `curl` flavor that has no bridge. So materialization runs an explicit
authorization step:

```
effective_caps = authorize(role.requested_caps, flavor_policy, tenant_policy)
              = role.requested_caps ∩ {caps the flavor/runtime + tenant permit}
```

**Fail closed:** a requested cap not permitted by the flavor/runtime/tenant
policy is **rejected, never copied**. The role's *contents* (skills, prompt,
behaviors) are identical across flavors; the *effective caps* are
flavor-validated and may legitimately differ. This keeps the cap chokepoint
(`Ezagent.Capability.matches?`) the sole authority — role is a *request*, the
authorization step is the *grant*.

### 2.4 The naming axis

An agent URI's name prefix today encodes flavor (`cc_…`, `curl_…`). Role becomes
a separate attribute (queried via the unified URI-query, per
`2026-06-05-unify-uri-query-design.md`), NOT concatenated into the name —
avoids re-entangling identity. (Decided — §4.)

## 3. Migration — the orchestrator is the first Role

`cc-orchestrator` is the load-bearing existing "role". It becomes:
- Role **`orchestrator`** = {orchestrator skill, orchestrator prompt, the
  orchestrator behavior/caps, the orchestrator session-template} — everything
  `cc_orchestrator_seed.ex` + `orchestrator_bootstrap.ex` install, minus the cc
  assumption.
- Flavor **`cc`** = its default (today's only) loader.

So "the orchestrator role, codex flavor" becomes expressible by installing the
same role recipe into a `CODEX_HOME` sandbox. `orchestrator_bootstrap.ex` is
rewritten to consult the **role Template** and write into *whatever* the flavor's
config_dir is. The orchestrator role ships as a **code-seeded role Template**
(`template://system/role/orchestrator`), seeded the same way `cc_orchestrator_seed.ex`
seeds today — but as a forkable Template, so a tenant can fork + tweak it. Risk
surface: the team-routing + orchestrator-readiness paths that assume cc — audited
in the plan.

## 4. Sub-decisions — DECIDED (Allen 2026-06-14)

1. **Role storage → Template subtype** (NOT a registry). Roles are forkable,
   persisted Template-kind `role` entities; built-ins are code-seeded Templates.
   See §2.1 for the registry-vs-Template rationale Allen asked about.
2. **Composition point → template materialization** (role-Template × flavor →
   a concrete agent at materialization, not at spawn).
3. **Session-template → reference only.** The role's `session_template` field is
   a *reference*; the role does not own session code. (This is the field that
   touches the renamed `session` domain — impl waits post-9c.)
4. **Naming/identity → role is a queried attribute**, not a second name-prefix
   axis (queried via the unified URI-query).

No open design decisions remain. Next: implementation plan (post-9c).

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
sandbox CONTENTS (skills / prompt / behaviors) are identical while the loader
(config_dir env / kind / bridge) differs.** Caps are asserted **flavor-validated,
not identical** — per §2.3.1 the effective caps are `requested ∩ flavor/tenant
policy`, so they may legitimately differ across flavors. That test fails today
(roles can't compose across flavors) and passes only when role×flavor decouples.

Plus a **negative authorization test** (codex adversarial-review): the
orchestrator role materialized against a flavor that does NOT support a
requested cap (e.g. a bridge-driving cap on a no-bridge flavor) must have that
cap **rejected (fail-closed), not copied** — proving cap composition is an
authorization, not a copy.

## 7. Cross-references

- Analysis: `2026-06-14-role-over-flavor-analysis.md`.
- `Ezagent.AgentFlavorRegistry` / `Ezagent.Plugin` — the flavor side.
- `apps/ezagent_plugin_cc/lib/ezagent/template/{orchestrator,onboarding}_bootstrap.ex` — today's sandbox-content installers (to generalize).
- `2026-06-05-unify-uri-query-design.md` — URI-as-opaque-id attribute query (for the role attribute).
- North Star: `feedback_north_star_plugin_isolation`.
