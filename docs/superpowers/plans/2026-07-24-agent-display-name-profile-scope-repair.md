# Agent Display-Name Scope Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver Agent display-name persistence and presentation without changing core lineage or provenance behaviour.

**Architecture:** A single core migration supplies the Agent-only unique index. Identity allocates a profile before the plugin Template Class is invoked and returns a receipt; Agent domain removes only a receipt-owned profile when the spawn does not complete. World consumes its unchanged profile-first display projection.

**Tech Stack:** Elixir, Ecto/PostgreSQL, Phoenix umbrella tests.

## Global Constraints

- Work only in `/home/lenovo/workspace/ezagent/.worktrees/fix-agent-display-name-profile`.
- Keep exactly one new file under `apps/ezagent_core`: the final Agent-only index migration.
- Do not modify `Ezagent.AgentLineage`, `Ezagent.Provenance.DerivationEdges`, or their tests.
- Do not change Agent URIs or the existing World presentation code.
- Preserve same-URI profiles; roll back only a profile row inserted by the current spawn attempt.
- Use `apply_patch` for source and documentation edits.
- Do not stage `.superpowers/sdd/task-1-report.md` or `.superpowers/sdd/task-4-report.md`.

---

### Task 1: Remove the expanded core implementation

**Files:**

- Delete all changes relative to `origin/main` in `apps/ezagent_core/lib/ezagent/agent_lineage.ex` and `apps/ezagent_core/lib/ezagent/provenance/derivation_edges.ex`.
- Delete `apps/ezagent_core/test/ezagent/agent_lineage_concurrency_test.exs`, `apps/ezagent_core/test/ezagent/profile_display_name_migration_test.exs`, and `apps/ezagent_core/test/support/profile_display_name_migration_test_repo.exs`.
- Delete migrations `20260724001000_scope_agent_profile_display_name_uniqueness.exs` and `20260724002000_repair_agent_profile_display_name_uniqueness.exs`.
- Modify `apps/ezagent_core/priv/repo_pg/migrations/20260724000000_add_agent_profile_display_name_uniqueness.exs`.
- Test `apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`.

**Interfaces:** Produces only `entity_profiles_agent_workspace_display_name_index`, scoped to bare Agent entity URIs, while restoring core business code byte-for-byte to `origin/main`.

- [ ] **Step 1: Write the migration regression first**

```elixir
assert {:ok, %Profile{display_name: "same"}} =
         Profile.ensure_agent_display_name(agent_one, "same")

assert {:ok, %Profile{display_name: "same"}} =
         Profile.upsert(%{entity_uri: user_uri, display_name: "same", email: nil})
```

- [ ] **Step 2: Run the test to establish the red state**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`

Expected: the incorrect migration predicate is observable as a failure.

- [ ] **Step 3: Restore core code and collapse migrations**

Keep only this migration implementation:

```elixir
def up do
  create unique_index(:entity_profiles, [:workspace_uri, :display_name],
           where: "entity_uri ~ '^entity://[^/:?#]+/agent/[^/?#]+$'",
           name: :entity_profiles_agent_workspace_display_name_index
         )
end

def down do
  drop_if_exists(index(:entity_profiles, [:workspace_uri, :display_name],
    name: :entity_profiles_agent_workspace_display_name_index
  ))
end
```

- [ ] **Step 4: Run green and commit**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`

Expected: zero failures; users are outside the Agent-only index.

Commit: `git add apps/ezagent_core/priv/repo_pg/migrations/20260724000000_add_agent_profile_display_name_uniqueness.exs apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs && git commit -m "fix(identity): scope agent display-name index"`

### Task 2: Allocate the display profile before spawning

**Files:**

- Modify `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`.
- Modify `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`.
- Modify `apps/ezagent_domain_agent/test/support/test_template_spawn.ex` if a profile failure hook is needed.

**Interfaces:** Consumes `Profile.ensure_agent_display_name_with_receipt/2`; creates the profile before the plugin Template Class starts; calls `Profile.rollback_agent_display_name/2` only for an `:inserted` receipt when later spawn work fails.

- [ ] **Step 1: Write a pre-spawn profile failure test**

```elixir
assert {:error, {:agent_display_profile_failed, _}} =
         TemplateSpawn.spawn_from_template_content(content, agent_uri, owner_uri, workspace_uri)

refute Ezagent.KindRegistry.alive?(agent_uri)
assert Profile.get(agent_uri) == nil
```

- [ ] **Step 2: Run the test to establish the red state**

Run: `mix test --no-start apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

Expected: FAIL because current code persists the profile after worker creation.

- [ ] **Step 3: Implement the minimal receipt-carrying pre-spawn step**

Use the following ownership rule in the existing error cleanup path:

```elixir
case receipt do
  {:inserted, agent_uri} -> Profile.rollback_agent_display_name(agent_uri, :inserted)
  _ -> :ok
end
```

For blank/missing names, carry no receipt. Remove the PR-added lineage/provenance receipt variants and rollback calls; retain baseline worker/config/grant cleanup.

- [ ] **Step 4: Run green and commit**

Run: `mix test --no-start apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

Expected: zero failures, including profile allocation before startup, same-URI retry preservation, duplicate suffixes, and post-spawn profile cleanup.

Commit: `git add apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs apps/ezagent_domain_agent/test/support/test_template_spawn.ex && git commit -m "fix(agent): allocate display profiles before spawn"`

### Task 3: Verify the consumer and repaired scope

**Files:**

- Modify only if assertions require it: `apps/ezagent_plugin_world/test/ezagent/world/agent_display_name_test.exs`.
- Modify `docs/together/2026-07-24/returns/agent-display-name-profile.md`.

- [ ] **Step 1: Run focused regressions**

```bash
mix test apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs apps/ezagent_domain_identity/test/ezagent/entity/profile_concurrency_test.exs
mix test --no-start apps/ezagent_plugin_world/test/ezagent/world/agent_display_name_test.exs
```

Expected: zero failures; UUID Agent URI is retained and the profile is exposed as `display_name`.

- [ ] **Step 2: Verify scope mechanically**

```bash
git diff --name-only origin/main...HEAD | rg '^apps/ezagent_core/'
git diff origin/main...HEAD -- apps/ezagent_core/lib/ezagent/agent_lineage.ex apps/ezagent_core/lib/ezagent/provenance/derivation_edges.ex
```

Expected: the first command lists only the migration; the second has no output.

- [ ] **Step 3: Run the project gate**

Run: `mix precommit`

Expected: terminal success; if environment boot prevents completion, record the exact result and do not claim green.

- [ ] **Step 4: Commit return evidence and publish**

Commit and push: `git add docs/together/2026-07-24/returns/agent-display-name-profile.md && git commit -m "docs(together): record display-name scope repair" && git push --force-with-lease origin fix/agent-display-name-profile`

Expected: PR #1570 reflects the repaired branch; the two pre-existing SDD reports remain unstaged.
