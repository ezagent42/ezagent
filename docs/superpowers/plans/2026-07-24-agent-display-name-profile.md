# Agent Display-Name Persistence and Uniqueness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist a workspace-unique, human-readable name for every newly spawned named Agent.

**Architecture:** PostgreSQL enforces uniqueness among Agent profiles; `Entity.Profile` resolves same-workspace collisions with numeric suffixes. `TemplateSpawn` persists the resolved name only after successful fresh spawn obligations. World already reads profiles first and therefore needs no production UI change.

**Tech Stack:** Elixir, Ecto/PostgreSQL, Phoenix umbrella tests.

## Global Constraints

- Work only in `/home/lenovo/workspace/ezagent/.worktrees/fix-agent-display-name-profile`.
- Do not backfill pre-release data, change Agent URIs, or derive names from Session membership.
- Agent uniqueness applies only to `email IS NULL` profiles in one `workspace_uri`; users remain unaffected.
- Same-URI retries preserve the original profile; duplicate requested Agent names become `name-2`, `name-3`, and so on.
- Use `apply_patch`; read Mix help before unfamiliar tasks; run `mix precommit` before completion.

---

### Task 1: Add a database-backed unique Agent profile API

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260724000000_add_agent_profile_display_name_uniqueness.exs`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:36-49`
- Create: `apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`

**Interfaces:**
- Produces `Profile.ensure_agent_display_name(%URI{}, String.t()) :: {:ok, Profile.t()} | {:error, Ecto.Changeset.t()}`.
- Produces index `entity_profiles_agent_workspace_display_name_index` over `(workspace_uri, display_name)` where `email IS NULL`.

- [ ] **Step 1: Write the failing tests**

Create `profile_test.exs` with `EzagentCore.DataCase`. Test two Agent URIs in one workspace, a repeat for one URI, and a user with the same display name:

```elixir
assert {:ok, %Profile{display_name: "builder"}} =
         Profile.ensure_agent_display_name(agent_one, "builder")

assert {:ok, %Profile{display_name: "builder-2"}} =
         Profile.ensure_agent_display_name(agent_two, "builder")

assert {:ok, %Profile{display_name: "builder"}} =
         Profile.ensure_agent_display_name(agent_one, "ignored-on-retry")
```

- [ ] **Step 2: Run the test red**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`

Expected: FAIL because the public API and unique index do not exist.

- [ ] **Step 3: Add the migration**

Implement `change/0` as follows:

```elixir
def change do
  create unique_index(:entity_profiles, [:workspace_uri, :display_name],
           where: "email IS NULL",
           name: :entity_profiles_agent_workspace_display_name_index
         )
end
```

Read `mix help ecto.migrate`, then run the documented migration command before rerunning tests.

- [ ] **Step 4: Implement the minimal profile API**

Add `ensure_agent_display_name/2` in `Ezagent.Entity.Profile`. It must first return `get(uri)` when that URI already has a profile. Otherwise derive `workspace_uri` using the existing persistence helper and try inserts in this order: base name, `base-2`, then incrementing suffixes. Use a private `agent_profile_changeset/2` with both `unique_constraint(:entity_uri)` and:

```elixir
unique_constraint(:display_name,
  name: :entity_profiles_agent_workspace_display_name_index
)
```

On an entity-URI conflict, fetch and return the winning profile; on the named index conflict, try the next suffix; propagate every other changeset error. Add the named constraint to `upsert/1` too, so direct invalid Agent updates return a normal changeset error.

- [ ] **Step 5: Run green and commit**

Run: `mix test apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs`

Expected: PASS; suffix allocation, same-URI idempotence, and user-name independence are proven.

```bash
git add apps/ezagent_core/priv/repo/migrations/20260724000000_add_agent_profile_display_name_uniqueness.exs apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs
git commit -m "feat(identity): persist unique agent display names"
```

### Task 2: Persist the profile from the generic fresh-spawn path

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex:430-566`
- Modify: `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

**Interfaces:**
- Consumes `Profile.ensure_agent_display_name/2`.
- Produces a display profile after successful fresh `TemplateSpawn` calls only.

- [ ] **Step 1: Write failing TemplateSpawn tests**

In the existing sandbox materialization test, reuse `FallbackSandboxTemplate`. Create two distinct UUID Agent URIs in one workspace, both with `name: "front-desk"`, then assert profiles `front-desk` and `front-desk-2`. Reinvoke the first URI so it is adopted (`fresh?: false`) and assert its existing profile remains unchanged:

```elixir
assert %Profile{display_name: "front-desk"} = Profile.get(first_uri)
assert %Profile{display_name: "front-desk-2"} = Profile.get(second_uri)
```

- [ ] **Step 2: Run red**

Run: `mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

Expected: FAIL because successful Agent spawning currently creates no profile.

- [ ] **Step 3: Add the post-spawn obligation**

Inside `complete_spawn_obligations/10`, add `persist_display_name(instance_uri, template_content_map)` to the existing `fresh?` success `with` chain after `mount_behavior_overlay/2`. The private helper must read atom or string `name`, trim it, skip blank/missing values, and map the new Profile API result to `:ok` or `{:error, {:agent_display_profile_failed, reason}}`:

```elixir
case Ezagent.Entity.Profile.ensure_agent_display_name(agent_uri, String.trim(name)) do
  {:ok, _profile} -> :ok
  {:error, reason} -> {:error, {:agent_display_profile_failed, reason}}
end
```

Keep the existing `else` cleanup path unchanged so a failed profile write rolls back the fresh worker. Do not call the helper in the `fresh?: false` adoption branch.

- [ ] **Step 4: Run green and commit**

Run: `mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

Expected: PASS; only fresh named agents receive unique persistent profiles.

```bash
git add apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
git commit -m "feat(agent): persist display name on template spawn"
```

### Task 3: Add a World regression test for UUID Agent display

**Files:**
- Create: `apps/ezagent_plugin_world/test/ezagent/world/agent_display_name_test.exs`

**Interfaces:**
- Consumes generic `TemplateSpawn` and `IdentityData.list_entities/3`.
- Proves a UUID URI keeps its URI `name` but exposes the profile in `display_name`.

- [ ] **Step 1: Write the failing data-boundary test**

Mirror the workspace/admin-cap setup from `agent_create_appears_in_list_test.exs`. Register a test flavor and materialize a UUID Agent through `TemplateSpawn` with `name: "dispatcher"`. Look up its row from `IdentityData.list_entities/3`:

```elixir
assert row["name"] == Ezagent.URI.name!(agent_uri)
assert row["display_name"] == "dispatcher"
refute row["display_name"] == row["name"]
```

- [ ] **Step 2: Run red**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/agent_display_name_test.exs`

Expected: FAIL before Task 2 because the row falls back to the UUID.

- [ ] **Step 3: Preserve the read path and run green**

Do not modify `IdentityData` or React. Correct only fixture authorization/setup if needed; `EntityPresenter.display_many/1` should make the test pass once Task 2 exists.

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/agent_display_name_test.exs`

Expected: PASS; UUID URI and human display name coexist.

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_plugin_world/test/ezagent/world/agent_display_name_test.exs
git commit -m "test(world): cover agent display names"
```

### Task 4: Verify the full change and manual UI behavior

**Files:**
- Verify only; no source changes expected.

- [ ] **Step 1: Read task help**

Run: `mix help test`, `mix help precommit`, and `mix help ecto.migrate`.

- [ ] **Step 2: Run focused coverage**

Run:

```bash
mix test apps/ezagent_domain_identity/test/ezagent/entity/profile_test.exs apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs apps/ezagent_plugin_world/test/ezagent/world/agent_display_name_test.exs
```

Expected: PASS with zero failures.

- [ ] **Step 3: Run the required project gate**

Run: `mix precommit`

Expected: PASS. If the known unrelated boot failure recurs, capture its exact output and separately report focused results.

- [ ] **Step 4: Manually verify the isolated Hello environment**

Start this branch with the isolated local database, create two Hello sessions that materialize an identically named role, then open `/identities/agents` as the non-admin founder. Each UUID Agent must show a human name; the duplicate role must use the deterministic suffix instead of a UUID.

- [ ] **Step 5: Inspect the final branch**

Run `git status --short`, `git diff main...HEAD --check`, and review all commits. Leave the branch with the design, plan, and focused implementation commits.
