# PR-5 Instance Message + Create Grant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the remaining #533 PR-5 work without touching #21 Dockerize: rename the misleading chat domain to instance-message, make all user/operator-facing create-session paths go through Workspace, implement create-time Manage-cap grants by construction, and remove the public create-session bypass at the end.

**Architecture:** `domain.chat` was named from the transport shape but now hosts Session, Agent, templates, routing, orchestrator tooling, and IM-adapter integration. Rename it first to `domain_instance_message` so future code reviews see the boundary correctly. Then build PR-5 around an authorized create entry and a create-time grant policy rather than local per-Kind special cases.

**Tech Stack:** Elixir umbrella apps, Phoenix/LiveView tests, Ezagent Lifecycle/Behavior/Kind, CapBAC, ExUnit invariants, E2E scenario tests.

---

## Locked Decisions

- `ezagent_domain_chat` / `EzagentDomainChat` is renamed first to `ezagent_domain_instance_message` / `EzagentDomainInstanceMessage`.
- The public `EzagentDomainInstanceMessage.create_session/3` facade may exist temporarily during migration, but must be removed before PR-5 is considered done.
- All user/operator-facing create-session interfaces must use `Ezagent.Workspace.create_session/3`.
- Internal materialization may remain inside the instance-message app, but it must not be a public facade usable by UI, CLI, MCP, or E2E tests.
- Manage-cap grant is an abstract create-time Behavior grant policy. Kind-specific business meaning is injected by Kind/registration policy; implementation must avoid one-off `agent`/`session` drift.
- E2E tests are in scope and must be migrated away from the public create-session bypass.

## Task 1: Branch + Baseline

**Files:**
- No production edits.

- [x] **Step 1: Confirm branch isolation**

Run:

```bash
git status --short --branch
git branch --show-current
```

Expected: branch is `feat/pr5c-instance-message-create-grant`, with a clean worktree before edits.

- [x] **Step 2: Verify baseline targeted tests**

Run:

```bash
MIX_ENV=test mix test apps/ezagent_domain_instance_message/test/integration/manage_behavior_test.exs apps/ezagent_domain_workspace/test/integration/create_session_dispatch_test.exs
```

Expected: pass before behavior edits. If this fails, record the failure before changing production code.

## Task 2: Mechanical Rename To Instance Message

**Files:**
- Move: `apps/ezagent_domain_chat/` -> `apps/ezagent_domain_instance_message/`
- Modify: umbrella references in `mix.exs`, app deps, config, docs, tests.
- Rename modules under `EzagentDomainChat` to `EzagentDomainInstanceMessage`.

- [x] **Step 1: Perform mechanical path/module/app rename**

Use structured project-wide replacement for these identifiers:

```text
apps/ezagent_domain_chat -> apps/ezagent_domain_instance_message
:ezagent_domain_chat -> :ezagent_domain_instance_message
EzagentDomainChat -> EzagentDomainInstanceMessage
ezagent_domain_chat -> ezagent_domain_instance_message
domain_chat -> domain_instance_message
```

Do not rename `Ezagent.Behavior.Chat` in this task. Chat remains the message Behavior; the app/domain boundary is what changes.

- [x] **Step 2: Compile and fix mechanical fallout**

Run:

```bash
MIX_ENV=test mix compile
```

Expected: compile succeeds. Fix stale module names, supervisor names, ETS table strings, and application deps exposed by compile errors.

- [x] **Step 3: Run renamed app tests**

Run:

```bash
MIX_ENV=test mix test apps/ezagent_domain_instance_message/test --seed 0 --max-cases 1
```

Expected: the renamed app suite runs under the new path. Failures should be rename fallout only, not semantic PR-5 work.

## Task 3: Add Boundary Invariants Before Behavior Changes

**Files:**
- Create or modify: `apps/ezagent_core/test/invariants/session_create_single_path_test.exs`
- Modify: existing invariants that still mention the old app path/module.

- [x] **Step 1: Write failing invariant for public create-session bypass**

The invariant scans production and E2E/user-facing test surfaces for direct calls to the lower-level facade:

```elixir
defmodule Ezagent.Invariants.SessionCreateSinglePathTest do
  use ExUnit.Case, async: true

  @allowed_internal_paths [
    "apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message.ex",
    "apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex"
  ]

  test "user/operator-facing create_session goes through Ezagent.Workspace.create_session" do
    matches =
      Path.wildcard("apps/**/*.{ex,exs}")
      |> Enum.reject(&String.contains?(&1, "/_build/"))
      |> Enum.flat_map(&direct_create_session_refs/1)
      |> Enum.reject(fn {path, _line} -> path in @allowed_internal_paths end)

    assert matches == [],
           "Direct EzagentDomainInstanceMessage.create_session/3 bypasses Workspace.create_session: #{inspect(matches)}"
  end

  defp direct_create_session_refs(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _idx} ->
      String.contains?(line, "EzagentDomainInstanceMessage.create_session(")
    end)
    |> Enum.map(fn {_line, idx} -> {path, idx} end)
  end
end
```

- [x] **Step 2: Run and verify RED**

Run:

```bash
MIX_ENV=test mix test apps/ezagent_core/test/invariants/session_create_single_path_test.exs
```

Expected: fail with direct references in LiveView, core E2E, and instance-message E2E tests.

- [x] **Step 3: Confirm all-Kind Manage registration invariant coverage**

Extend or create an invariant that enumerates registered Kind modules and asserts `Ezagent.Behavior.Manage` resolves for `:delete` and `:reconfigure`. Expected RED before the by-construction registration is implemented: plugin-defined Kinds are missing Manage.

## Task 4: Create-Time Manage-Cap Grant Abstraction

**Files:**
- Modify/create core module for create grant policy, likely under `apps/ezagent_core/lib/ezagent/kind/`.
- Modify tests under `apps/ezagent_core/test/ezagent/kind/` and integration tests under instance-message/workspace apps.

- [x] **Step 1: Write failing grant policy tests**

Required test cases:

- fresh create grants `cap(kind, Ezagent.Behavior.Manage, :any, instance)` to authenticated `ctx.caller`;
- rehydrate/adopt does not grant;
- grant failure rolls back the create saga;
- grantee is captured from `ctx.caller`, not from forgeable spawn args or template data.

- [x] **Step 2: Implement one trusted create-grant primitive**

The primitive must be centralized. It may dispatch `identity.grant_cap` with system authority, but callers must not repeat that logic at each create site.

- [x] **Step 3: Implement Kind/Behavior injection point**

Kinds declare whether they receive create-time Manage grants by policy. The default should be safe and explicit enough to avoid granting to boot/system/internal creations accidentally, but the mechanism should be reusable across all Kind modules.

- [x] **Step 4: Run grant tests GREEN**

Run:

```bash
MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs
```

Expected: grant policy tests pass without weakening CapBAC.

## Task 5: Manage Registration By Construction

**Files:**
- Modify core/domain/plugin registration path.
- Modify `apps/ezagent_core/test/invariants/...` Manage invariant.

- [x] **Step 1: Implement by-construction Manage registration**

Do not hand-register only the currently failing Kinds. The mechanism should make new Kind registration include Manage unless a Kind explicitly opts out with a tested reason.

- [x] **Step 2: Run invariant GREEN**

Run:

```bash
MIX_ENV=test mix test apps/ezagent_core/test/invariants/*manage* apps/ezagent_domain_instance_message/test/integration/manage_behavior_test.exs
```

Expected: every registered Kind resolves Manage actions; unsupported reconfigure still returns `{:error, :reconfigure_unsupported}`.

## Task 6: Migrate Interfaces And E2E Tests To Workspace.create_session

**Files:**
- Modify LiveView modules such as `apps/ezagent_plugin_liveview/lib/.../admin_live.ex`.
- Modify web/home LiveView modules.
- Modify E2E tests under `apps/ezagent_domain_instance_message/test/e2e/`, `apps/ezagent_core/test/e2e/`, and LiveView E2E.

- [x] **Step 1: Convert UI/session creation surfaces**

Replace direct lower-level create calls with:

```elixir
Ezagent.Workspace.create_session(workspace_uri, %{short_name: short_name, template_name: template_name}, ctx)
```

The `ctx` must carry the authenticated caller and the caller's real caps. Do not inject `admin_caps` fallback.

- [x] **Step 2: Convert E2E helpers**

E2E setup must create sessions through Workspace unless the test is explicitly exercising internal materialization. If an E2E needs admin setup, build an admin ctx and dispatch through Workspace.

- [x] **Step 3: Run invariant GREEN**

Run:

```bash
MIX_ENV=test mix test apps/ezagent_core/test/invariants/session_create_single_path_test.exs
```

Expected: no direct lower-level create-session references remain outside internal allowlist.

## Task 7: Remove Public InstanceMessage.create_session Bypass

**Files:**
- Modify: `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message.ex`
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex`
- Modify tests that still refer to the old facade.

- [x] **Step 1: Move materialization behind an internal module/function**

Workspace may call an internal materializer module inside the instance-message app, but the app facade must not expose `create_session/3`.

- [x] **Step 2: Remove the public function**

Delete `EzagentDomainInstanceMessage.create_session/3` after all callers have migrated.

- [x] **Step 3: Compile and run bypass invariant**

Run:

```bash
MIX_ENV=test mix compile
MIX_ENV=test mix test apps/ezagent_core/test/invariants/session_create_single_path_test.exs
```

Expected: no public facade references remain.

## Task 8: Final Verification

**Files:**
- No new production files unless tests reveal missed fallout.

- [ ] **Step 1: Run targeted suites**

Run:

```bash
MIX_ENV=test mix test apps/ezagent_core/test/invariants apps/ezagent_domain_workspace/test/integration/create_session_dispatch_test.exs apps/ezagent_domain_instance_message/test/integration/manage_behavior_test.exs apps/ezagent_domain_instance_message/test/e2e --seed 0 --max-cases 1
```

Expected: targeted PR-5 invariants, session-create dispatch tests, Manage tests, and E2E session flows pass.

- [ ] **Step 2: Run precommit gate**

Run:

```bash
MIX_ENV=test mix precommit
```

Expected: pass. If formatter wants unrelated churn, format touched files only and record any existing formatter debt separately.

- [ ] **Step 3: PR and merge target**

Open PR(s) against `domain-agent-handoff`, not `main`. Do not touch #21 Dockerize branches. Merge only after checks pass.
