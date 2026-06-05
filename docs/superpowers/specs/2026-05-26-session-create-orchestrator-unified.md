# SPEC: Unified `session create` — CLI/LV parity + orchestrator auto-spawn + orchestrator-skill wiring

**Status**: draft for codex adversarial review
**Date**: 2026-05-26
**Allen directive**: "带有 orchestrator 就是 session 的 default 配置"; CLI/LV 同源派生; orchestrator agent must load `ezagent-session-orchestrator` skill on spawn
**Closes**: tasks #40 / #41 / #42 (3 gaps from PR #407 e2e attempt)

## Problem

PR #407 delivered the orchestrator-UX redesign (owner-bound restart, HealthCard moved to session view, new SKILL.md created, `OrchestratorAdmin` cap subject), but missed three wire-ups that are necessary for actual e2e validation:

1. **Gap A — `create_session/3` doesn't auto-spawn orchestrator**. The pre-existing `Session.ensure_orchestrator/3` is only invoked from the SessionTemplate.instantiate flow, NOT from `EzagentDomainInstanceMessage.create_session/3` (the entry point LV / mix bootstrap / future-CLI use). A session created via `create_session/3` lands with no orchestrator — operator must manually instantiate.

2. **Gap B — orchestration skill not loaded into orchestrator agent**. PR #407 created `.claude/skills/ezagent-session-orchestrator/SKILL.md` but the cc Template Class doesn't copy it into the spawned orchestrator agent's `<config_dir>/skills/`, nor instruct Claude to load it. The orchestrator agent boots as a vanilla cc agent — unaware of its orchestration role.

3. **Gap C — CLI has no `session create` command**. `EzagentDomainInstanceMessage.create_session/3` is a module-facade function, not a Behavior action — so the auto-derived CLI surface (per `feedback_goal_human_ergonomic_verification`) doesn't expose it. LV form posts directly to the facade; the same path isn't reachable from `mix ezagent …`.

All three are wire-ups of design that's already half-implemented. None of them touch the underlying invariants (CapBAC / dispatch / 3-tier).

## Design

### Fix A — `create_session` auto-spawns orchestrator

**Public API change**: extract `Session.ensure_orchestrator/3` from `defp` to `def` (+ `@spec` + `@doc`). Keep the existing logic intact.

**Wire-up**: in `EzagentDomainInstanceMessage.create_session/3`, after `grant_owner_orchestrator_admin_cap/3` succeeds, call:

```elixir
case Ezagent.Entity.Session.ensure_orchestrator(session_uri, workspace_uri, effective_owner) do
  {:ok, orchestrator_uri, _outcome} ->
    # _outcome is :created | :already_present
    {:ok, session_uri, %{orchestrator_uri: orchestrator_uri, orchestrator_status: :ready}}

  {:partial, %{orchestrator_pending: uri}} ->
    # Race window — orchestrator URI is reserved but ownership not yet
    # classified. Surface as pending so the LV restart button can retry.
    {:ok, session_uri, %{orchestrator_uri: uri, orchestrator_status: :pending}}

  {:error, reason} ->
    # Session was created + cap granted; orchestrator spawn failed.
    # Return partial-success so operator sees the gap explicitly.
    {:ok, session_uri, %{orchestrator_uri: nil, orchestrator_status: :failed, orchestrator_error: reason}}
end
```

The 3 cases above mirror `ensure_orchestrator/3`'s 3-way return shape verified at `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:691-734` (codex rev-4 already enumerates `{:ok, _, :created|:already_present}`, `{:partial, %{orchestrator_pending: uri}}`, `{:error, reason}`).

**Return shape change**: from `{:ok, URI.t()}` to `{:ok, URI.t(), %{orchestrator_uri: URI.t() | nil, orchestrator_status: :ready | :pending | :failed, orchestrator_error: term | nil}}`.

**Actual caller count (revised after grep)**: 20 real call sites (was estimated as ~12 in earlier draft):
- 1 application bootstrap (`apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:205`)
- 1 presence-fanout test
- 2 LiveView call sites (`admin_live.ex:709`, `admin_live.ex:2511`)
- 1 home_live.ex:91 (LV "new session" form)
- 1 presence_read_receipts e2e
- 4 session_owner_orchestrator_cap_test sites
- 1 non_admin_grant_flow_e2e
- 5 dynamic_session_test sites
- 3 session_auto_join_test sites
- 1 home_live_test
- 1 caps_denial_e2e_test

Implementer MUST grep `EzagentDomainInstanceMessage.create_session(` across the umbrella and update every match. Backward-compat overload is NOT provided (per `feedback_let_it_crash_no_workarounds` — no silent fallbacks).

**Recommendation**: change the return shape directly. The PR enumerates and updates all callers.

**Failure semantics** (per `feedback_let_it_crash_no_workarounds`):
- Session create failure → propagate `{:error, reason}` as today
- Cap grant failure on success → propagate `{:error, reason}` (cap is load-bearing for restart UX)
- **Orchestrator spawn failure → log + return `{:ok, session_uri, %{orchestrator_uri: nil, orchestrator_status: :failed, orchestrator_error: reason}}`**. We DON'T tear down the session because: (a) session is already persisted + workspace-bound, (b) operator can manually retry orchestrator spawn via the LV Restart button after debugging. **Not a silent fallback** — the meta map is checked by LV / CLI; UI renders "Orchestrator failed: <reason>; click Restart to retry".
- **Orchestrator pending (race window) → return with `orchestrator_status: :pending`**. The URI is reserved but ownership classification is incomplete. LV renders "Orchestrator pending — refresh in a moment"; CLI prints a warning + exit-code 0.

**Invariant #9 obligation (no silent drops)**: every caller of the 3-tuple `create_session/3` MUST inspect the meta map. The implementer is REQUIRED to update `home_live.ex:91` + `admin_live.ex:709/2511` to render the `orchestrator_status` field — silently discarding the meta map (e.g. `{:ok, session_uri, _meta}`) is a Invariant-#9 violation and MUST fail the PR's invariant test.

### Fix B — orchestration skill loading on orchestrator spawn

**cc Template Class change**: add a new optional field `role :: :default | :orchestrator` to the cc Template config map. Default `:default`.

**At `instantiate/3`**:
- if `role == :orchestrator`:
  1. Copy `<umbrella_root>/.claude/skills/ezagent-session-orchestrator/` to `<agent_config_dir>/skills/ezagent-session-orchestrator/` (recursive `File.cp_r/2`)
  2. Append a CLAUDE.md hint line: `## Use the ezagent-session-orchestrator skill for all session coordination work.` to `<agent_config_dir>/CLAUDE.md` (create file if missing)
  3. Set env var `EZAGENT_AGENT_ROLE=orchestrator` on the spawned subprocess (cc PtyServer's `cmd_env` field)
- else (`:default` or omitted): no-op (existing behavior)

**`Session.ensure_orchestrator/3` change**: pass `role: :orchestrator` in the template data threaded to `template.instantiate`.

**Idempotence**: re-spawn of an already-existing orchestrator (the `:already_started` branch of `instantiate/3`) must NOT re-copy the skill or re-append the hint — `File.exists?/1` guard on the skill dir + grep for the hint string in CLAUDE.md before append.

### Fix C — `session create` as Behavior action (CLI/LV parity)

**Add `:create_session` action to `Ezagent.Behavior.Workspace`**:

```elixir
@interface %{
  create_session: %{
    description: "Create a new session in this workspace + auto-spawn orchestrator agent owned by the caller.",
    args: %{short_name: :string, template_name: :string},
    returns: %{session_uri: :uri, orchestrator_uri: {:option, :uri}, orchestrator_error: {:option, :string}},
    modes: [:call]
  }
}

@impl Ezagent.Behavior
def invoke(:create_session, slice, %{short_name: short_name, template_name: tn}, ctx) do
  caller = ctx[:caller]
  workspace_uri = ctx[:self_uri]
  
  case EzagentDomainInstanceMessage.create_session(short_name, caller, [
    workspace_uri: workspace_uri,
    template_name: tn
  ]) do
    {:ok, session_uri, meta} ->
      {:ok, slice, %{
        session_uri: URI.to_string(session_uri),
        orchestrator_uri: meta[:orchestrator_uri] && URI.to_string(meta.orchestrator_uri),
        orchestrator_error: meta[:orchestrator_error] && inspect(meta.orchestrator_error)
      }}
    
    {:error, reason} ->
      {:error, reason}
  end
end
```

**Cap subject**: `Capability.cap(:workspace, Behavior.Workspace, :create_session)` — declared in `required_caps/0`. Workspace members can create sessions in their workspace. Cross-workspace blocked structurally by the dispatch flow.

**CLI auto-derives**:
```
mix ezagent workspace create_session \
  --workspace workspace://system \
  --short-name <name> \
  --template-name default
```

**LV form path**: existing LV "New session" form continues to use `EzagentDomainInstanceMessage.create_session/3` (the facade) — same source-of-truth, no duplication. The invariant test verifies CLI + LV produce identical session URIs given identical args.

## Acceptance criteria

| # | Test | Pass condition |
|---|---|---|
| A1 | `EzagentDomainInstanceMessage.create_session/3` returns 3-tuple `{:ok, uri, %{orchestrator_uri: _, ...}}` | unit test |
| A2 | After `create_session`, `Ezagent.KindRegistry.lookup(orch_uri)` returns `{:ok, pid}` | unit test |
| A3 | Orchestrator spawn failure → partial-success return shape with `orchestrator_error` populated | unit test |
| B1 | Orchestrator agent's `<config_dir>/skills/ezagent-session-orchestrator/SKILL.md` exists after spawn | unit test |
| B2 | Orchestrator agent's `<config_dir>/CLAUDE.md` contains the skill-load hint line | unit test |
| B3 | Default-role cc agent (non-orchestrator) does NOT get the skill copied | unit test |
| B4 | Idempotent re-spawn doesn't duplicate the CLAUDE.md hint line | unit test |
| C1 | `mix ezagent workspace create_session ...` succeeds with auto-derived help | integration test |
| C2 | CLI-created session and LV-created session have identical URI + orchestrator + cap shape | invariant test |
| C3 | Caller without workspace `:create_session` cap → `{:error, :unauthorized}` | unit test |

## Files affected

**Core / domain**:
- `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message.ex` — return shape change + ensure_orchestrator wire-up
- `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex` — `ensure_orchestrator/3` defp → def + `role: :orchestrator` thread
- `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex` — `:create_session` action + cap
- `apps/ezagent_core/lib/ezagent/capability.ex` — (if new cap-subject helper needed)

**Plugin**:
- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` — `:role` field + skill-copy + CLAUDE.md hint
- `apps/ezagent_plugin_cc/lib/ezagent/template/role.ex` — (if separating role logic for clarity)

**Tests**:
- `apps/ezagent_domain_instance_message/test/ezagent_domain_instance_message_test.exs` — return shape + orchestrator-spawn invariants
- `apps/ezagent_domain_instance_message/test/ezagent/entity/session_orchestrator_test.exs` — public ensure_orchestrator + role propagation
- `apps/ezagent_domain_workspace/test/ezagent/behavior/workspace_create_session_test.exs` — new Behavior action
- `apps/ezagent_plugin_cc/test/ezagent/template/orchestrator_role_test.exs` — skill copy + CLAUDE.md hint
- `apps/ezagent_cli/test/cli_workspace_create_session_test.exs` — CLI parity

**Callers updated for return-shape change**:
- LV "new session" form (currently destructures 2-tuple)
- Test seeds that call `create_session/3` (grep estimate: ~10 sites)
- Bootstrap mix tasks that touch session creation

## Out of scope

- Refactoring `Session.ensure_orchestrator/3`'s internal logic — keep as-is, only export
- `cc-orchestrator` template seed (already exists)
- The `ezagent-session-orchestrator` SKILL.md content — written by PR #407
- LV session view renderer changes — separate PR if needed

## Failure modes considered

| Failure | Behavior |
|---|---|
| Session create succeeds, orchestrator spawn fails | Return `{:ok, uri, %{orchestrator_uri: nil, orchestrator_error: reason}}`; session is alive; operator clicks Restart |
| Session create succeeds, cap grant fails | Return `{:error, reason}` — restart UX would be broken; treat as fatal create failure |
| Skill dir missing in umbrella root | `File.cp_r/2` returns error; orchestrator spawn proceeds (skill copy is best-effort UX); cc subprocess sees no skill but still works as plain cc agent — operator gets a notification |
| `:already_started` orchestrator re-instantiation | Skip skill copy + skip CLAUDE.md hint append (idempotence guards) |
| Workspace not a member (caller mismatch) | `{:error, :unauthorized}` at dispatch step 5.5 cap check |

## Constraints honored

- **Let-it-crash** — no silent fallbacks; orchestrator failure surfaces structurally via partial-success meta
- **No destructive migrations** — return shape change is in-process API only
- **Three-tier separation** — Workspace Behavior in domain_workspace, cc Template in plugin_cc, session ensure_orchestrator stays in domain_instance_message
- **CapBAC** — new `:workspace, Workspace, :create_session` cap subject; matches workspace-member cap pattern
- **Dispatch is only path** — Workspace.invoke(:create_session) is dispatched; LV form continues to use the facade (same source of truth)

## Codex adversarial review questions

The codex review should specifically probe:

1. Does the partial-success return shape leak orchestrator state into Workspace.invoke return that should be a separate event/notification?
2. Could the skill-copy step race with concurrent orchestrator instantiations (two LVs creating sessions simultaneously)?
3. Does `EZAGENT_AGENT_ROLE` env var have any conflict with existing env vars used by claude TUI?
4. Is the orchestrator URI shape (`entity://agent/<workspace>/cc_orchestrator-<disc>`) stable across the create_session and template.instantiate paths?
5. Does the cap subject `(:workspace, Workspace, :create_session)` collide with any existing workspace caps?
6. Does the auto-derived CLI handle the new `returns: %{... {:option, :uri}}` shape correctly (Optimus output formatting)?

## Open questions for Allen

1. **Failure surface**: should orchestrator-spawn failure surface as a Notification to the creator (per PR #406 pattern) in addition to the meta-map return? Default: yes, but kept out of this SPEC's scope.
2. **Backward-compat for return shape**: a parallel `create_session/3` (old 2-tuple) + `create_session_with_meta/3` (new) — or break the API? Recommendation: break, since this is single-version + we own all callers.
