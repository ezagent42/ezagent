# Socialware View-Cap Install Postcondition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure a newly created hello session cannot resolve its initial socialware-install obligation until its already-present confirmed user members hold the declared Page view capability.

**Architecture:** Add a result-aware live Session roster read, expose a strict result from the existing Membership grant funnel, and run a focused `ViewCapConvergence` postcondition after definition-agent materialization. Grant or roster failures keep the durable obligation pending; successful cap storage continues through the existing identity `SliceChange` to `world:state` refresh path.

**Tech Stack:** Elixir 1.19, OTP 28, Ecto, ExUnit, Phoenix LiveView 1.1, existing `Ezagent.Identity.Grant` and socialware-install obligation infrastructure.

## Global Constraints

- Scope is only the initial session-template socialware installation after session creation.
- Do not add obligation generations, later socialware upgrade handling, or a new join/membership workflow.
- Do not add a capability constructor or `grant_cap_via_router/4` production call site.
- Run strict convergence caller-side in the obligation worker, never in a Session Kind handler.
- Grant only confirmed, current user members; do not change agent or anonymous provisioning.
- Add no hello-specific World event or production branch.
- Use red-green TDD and run `mix precommit` after focused suites.

---

### Task 1: Result-aware live Session roster

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex:365-449`
- Modify: `apps/ezagent_domain_session/lib/ezagent/entity/session.ex:347-350`
- Test: `apps/ezagent_domain_session/test/integration/chat_session_membership_read_test.exs`

**Interfaces:**
- Produces: `Session.session_member_uris_strict/1 :: {:ok, [URI.t()]} | {:error, term()}`.
- Preserves: `Session.session_member_uris/1 :: [URI.t()]` and its convenience `[]` fallback.

- [ ] **Step 1: Write failing strict-read tests**

Add to `chat_session_membership_read_test.exs`:

```elixir
describe "strict live membership read" do
  test "returns the current owner/member" do
    owner = member_uri()
    session_uri = spawn_owned_session(owner)
    assert {:ok, members} = Session.session_member_uris_strict(session_uri)
    assert owner in members
  end

  test "an unavailable Session is an error, not an empty roster" do
    missing =
      Ezagent.URI.new!(
        "session://team-alpha/default/missing-roster-#{System.unique_integer([:positive])}"
      )

    assert {:error, _reason} = Session.session_member_uris_strict(missing)
    assert Session.session_member_uris(missing) == []
  end
end
```

- [ ] **Step 2: Run RED test**

Run: `mix test apps/ezagent_domain_session/test/integration/chat_session_membership_read_test.exs`

Expected: undefined `session_member_uris_strict/1`.

- [ ] **Step 3: Implement the strict reader**

Add beside `session_member_uris/1`:

```elixir
@doc false
@spec session_member_uris_strict(URI.t()) :: {:ok, [URI.t()]} | {:error, term()}
def session_member_uris_strict(%URI{} = session_uri) do
  case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
    {:ok, persistent} when is_map(persistent) ->
      case Map.fetch(persistent, :members) do
        {:ok, members} when is_map(members) ->
          uris = Map.keys(members)

          if Enum.all?(uris, &match?(%URI{}, &1)),
            do: {:ok, uris},
            else: {:error, :malformed_member_uri}

        {:ok, _} -> {:error, :malformed_members}
        :error -> {:error, :members_missing}
      end

    {:ok, _} -> {:error, :malformed_session_state}
    {:error, reason} -> {:error, reason}
  end
catch
  :exit, reason -> {:error, {:exit, reason}}
end
```

Delegate it from `Ezagent.Entity.Session`. Do not change the old reader.

- [ ] **Step 4: Run GREEN test and commit**

Run: `mix test apps/ezagent_domain_session/test/integration/chat_session_membership_read_test.exs`

Commit:

```bash
git add apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex \
  apps/ezagent_domain_session/lib/ezagent/entity/session.ex \
  apps/ezagent_domain_session/test/integration/chat_session_membership_read_test.exs
git commit -m "feat(session): add strict live member read"
```

---

### Task 2: Strict grant result and focused convergence runner

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:1197-1335`
- Create: `apps/ezagent_domain_session/lib/ezagent/socialware/view_cap_convergence.ex`
- Create: `apps/ezagent_domain_session/test/ezagent/socialware/view_cap_convergence_test.exs`
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/member_backfill_test.exs`

**Interfaces:**
- Produces: `Membership.grant_member_view_caps_strict/2 :: :ok | {:error, term()}`.
- Produces: `ViewCapConvergence.converge/2 :: :ok | {:error, term()}`.
- `converge/2` accepts internal `:roster_reader` and `:grant_member` callbacks for deterministic tests.
- Preserves best-effort `Membership.grant_member_view_caps/2 :: :ok`.

- [ ] **Step 1: Write failing convergence tests**

Create tests proving these exact results:

```elixir
assert {:error, {:member_roster_read_failed, ^session, :database_busy}} =
         ViewCapConvergence.converge(session,
           roster_reader: fn ^session -> {:error, :database_busy} end
         )

assert {:error,
        {:member_view_cap_failed, ^member, TestRender, :test_render,
         :timeout}} =
         ViewCapConvergence.converge(session,
           roster_reader: fn ^session -> {:ok, [member]} end,
           grant_member: fn ^session, ^member ->
             {:error,
              {:member_view_cap_failed, member, TestRender, :test_render, :timeout}}
           end
         )
```

Define `TestRender.actions/0` as `[:test_render]` inside the test module. Create
confirmed, unconfirmed, agent, and anonymous fixtures and assert the injected
`grant_member` callback receives only the confirmed ordinary user. Domain tests
must not reference `EzagentPluginHello` modules.

- [ ] **Step 2: Run RED test**

Run: `mix test apps/ezagent_domain_session/test/ezagent/socialware/view_cap_convergence_test.exs`

Expected: undefined `ViewCapConvergence`.

- [ ] **Step 3: Refactor the existing Membership funnel**

Add `grant_member_view_caps_strict/2`. It must require `user_uri?`, `Users.confirmed?`, and `current_member_entitled?`, enumerate `Installation.declared_view_actions/1`, and call the shared private funnel with `:strict` policy.

Change the private funnel to `grant_session_caps/6` and replace `Enum.each/2` with `Enum.reduce_while/3`. Keep the existing cap constructor and the existing single router call expression. On failure return:

```elixir
{:error, {:member_view_cap_failed, member_uri, behavior, action, reason}}
```

for `:strict`; for `:best_effort`, execute the existing warning/telemetry and continue with `:ok`.

- [ ] **Step 4: Implement `ViewCapConvergence`**

```elixir
defmodule Ezagent.Socialware.ViewCapConvergence do
  @moduledoc false

  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Entity.Session

  @spec converge(URI.t(), keyword()) :: :ok | {:error, term()}
  def converge(%URI{scheme: "session"} = session_uri, opts \\ []) do
    read = Keyword.get(opts, :roster_reader, &Session.session_member_uris_strict/1)
    grant = Keyword.get(opts, :grant_member, &Membership.grant_member_view_caps_strict/2)

    case read.(session_uri) do
      {:ok, members} when is_list(members) ->
        members
        |> Enum.filter(&eligible?/1)
        |> Enum.reduce_while(:ok, fn member, :ok ->
          case grant.(session_uri, member) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, {:member_roster_read_failed, session_uri, reason}}

      other ->
        {:error, {:member_roster_read_failed, session_uri, {:unexpected_result, other}}}
    end
  end

  defp eligible?(%URI{} = member),
    do: Membership.user_uri?(member) and Ezagent.Users.confirmed?(member)

  defp eligible?(_), do: false
end
```

- [ ] **Step 5: Run GREEN suites and chokepoint check**

```bash
mix test apps/ezagent_domain_session/test/ezagent/socialware/view_cap_convergence_test.exs \
  apps/ezagent_domain_session/test/ezagent/socialware/member_backfill_test.exs
rg -n "grant_cap_via_router" apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex
```

Expected: tests pass and Membership has no new router grant site.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex \
  apps/ezagent_domain_session/lib/ezagent/socialware/view_cap_convergence.ex \
  apps/ezagent_domain_session/test/ezagent/socialware/view_cap_convergence_test.exs \
  apps/ezagent_domain_session/test/ezagent/socialware/member_backfill_test.exs
git commit -m "feat(session): converge installed view caps strictly"
```

---

### Task 3: Gate initial installation resolution on view caps

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/session_installer.ex:8-69`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex:296-348`
- Test: `apps/ezagent_domain_session/test/integration/install_session_socialware_test.exs`
- Test: `apps/ezagent_domain_session/test/ezagent/session/socialware_install_sweeper_test.exs`
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs`

**Interfaces:**
- Extends `SessionInstaller.install/4` with defaulted `opts \\ []`, preserving arity 4.
- Runs `ViewCapConvergence.converge/2` only after materialization and unfilled-role persistence succeed.
- Keeps the same initial-creation obligation row and retry lifecycle.

- [ ] **Step 1: Write RED installer and retry tests**

Add an installer test with a live owned Session and complete working copy. Inject:

```elixir
view_cap_converger: fn session_uri, _opts ->
  {:error,
   {:member_view_cap_failed, owner_uri, InstallTestRender, :install_test_render,
    :timeout}}
end
```

Define `InstallTestRender.actions/0` as `[:install_test_render]` inside the domain
test module. Assert `SessionInstaller.install/5` returns that exact error; do not
reference hello plugin modules from the domain app.

Add a sweeper test whose `install_fun` returns that error on attempt 1 and `{:ok, summary}` on attempt 2. Assert status is `:pending` after attempt 1 and `:resolved` only after attempt 2, using the existing backoff-expiry update pattern in `socialware_install_sweeper_test.exs`.

- [ ] **Step 2: Run RED tests**

```bash
mix test apps/ezagent_domain_session/test/integration/install_session_socialware_test.exs \
  apps/ezagent_domain_session/test/ezagent/session/socialware_install_sweeper_test.exs
```

Expected: installer arity/callback test fails before implementation.

- [ ] **Step 3: Integrate the postcondition**

In the successful materialization branch:

```elixir
converger =
  Keyword.get(opts, :view_cap_converger, &Ezagent.Socialware.ViewCapConvergence.converge/2)

with :ok <- SessionCreator.record_unfilled_role_slots(session_uri, summary.skipped),
     :ok <- converger.(session_uri, []) do
  {:ok, summary}
end
```

Propagate convergence errors unchanged. Do not tombstone already-materialized bindings for a retryable cap failure.

- [ ] **Step 4: Include view-only initial installs in obligation creation**

For a complete working copy, require the obligation when:

```elixir
Map.get(working_copy, :member_declarations, []) != [] or
  Ezagent.Socialware.Installation.declared_view_actions(session_uri) != []
```

Keep the no-op path when both collections are empty. Do not reopen resolved rows or change the obligation schema.

- [ ] **Step 5: Add the actual hello/Page regression**

Extend the existing `"workspace class creation asynchronously installs the
declared team"` test in `hello_session_test.exs`. After its `eventually/1`
assertion proves the initial obligation is resolved, assert the real admin
creator can authorize and enumerate the shipped hello Page:

```elixir
assert :ok =
         Ezagent.UI.SessionView.authorize_view(
           EzagentPluginHello.PageView,
           session_uri,
           caller
         )

state =
  Ezagent.World.ConversationData.state_for(session_uri, %{
    caller_uri: caller,
    workspace_uri: workspace_uri,
    sessions: []
  })

assert Enum.any?(state["views"], &(&1["id"] == "hello_page"))
```

Use the existing test's `caller`, `session_uri`, and `workspace_uri` variables.
This is the completion invariant: it must fail before the fix and pass without
manual `MemberBackfill` or database repair.

- [ ] **Step 6: Run GREEN domain suites**

```bash
mix test apps/ezagent_domain_session/test/integration/install_session_socialware_test.exs \
  apps/ezagent_domain_session/test/ezagent/session/socialware_install_obligations_test.exs \
  apps/ezagent_domain_session/test/ezagent/session/socialware_install_sweeper_test.exs \
  apps/ezagent_domain_session/test/ezagent/socialware/view_cap_convergence_test.exs \
  apps/ezagent_domain_session/test/ezagent/socialware/member_backfill_test.exs
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs
```

Expected: all pass and the hello projection contains Page.

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_domain_session/lib/ezagent/socialware/session_installer.ex \
  apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex \
  apps/ezagent_domain_session/test/integration/install_session_socialware_test.exs \
  apps/ezagent_domain_session/test/ezagent/session/socialware_install_sweeper_test.exs \
  apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs
git commit -m "fix(session): require view caps before install resolves"
```

---

### Task 4: Connected World refresh regression

**Files:**
- Modify: `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs`
- Verify only: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:316-324,459-467,557-597`

**Interfaces:**
- Consumes the existing identity `SliceChange` subscription.
- Produces a connected-LiveView assertion that `world:state.views` gains an authorized view.
- Requires no production World change.

- [ ] **Step 1: Write the connected LiveView test**

Define a nested cap-gated test view and render behavior using the same contract as `view_cap_gate_regression_test.exs`. Mount `/sessions?session=<encoded>` as a real joined user without the render cap, call `render_async/2`, and assert the initial state omits the test view.

Create a target-authority-signed cap with:

```elixir
Ezagent.Capability.cap(
  :session,
  WorldRefreshRender,
  :world_refresh_render,
  Ezagent.URI.instance(session_uri),
  Ezagent.Capability.workspace_of(session_uri)
)
```

Store it using `Ezagent.EntityCaps.grant/2`, then assert:

```elixir
assert_push_event(view, "world:state", %{"views" => views}, 2_000)
assert Enum.any?(views, &(&1["id"] == "world_refresh"))
```

- [ ] **Step 2: Run World tests**

```bash
mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs
mix test apps/ezagent_plugin_world/test/ezagent/world/view_cap_gate_regression_test.exs
```

Expected: both pass without modifying `WorldLive`. If notification delivery fails, diagnose the existing generic identity-change contract; do not add a hello-specific event.

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_web/test/ezagent_web/world_conversation_test.exs
git commit -m "test(world): cover live view-cap refresh"
```

---

### Task 5: Final verification

**Files:**
- Verify all Task 1-4 changes.
- Do not modify unrelated worktree files or baseline failures.

- [ ] **Step 1: Format touched Elixir files**

Run `mix format` with the exact changed `.ex` and `.exs` paths reported by `git diff --name-only HEAD~4..HEAD`.

- [ ] **Step 2: Run touched-app suites**

```bash
mix test apps/ezagent_domain_session/test
mix test apps/ezagent_plugin_hello/test
mix test apps/ezagent_plugin_world/test
mix test apps/ezagent_web/test
```

Expected: all pass.

- [ ] **Step 3: Run architecture gates**

```bash
mix ezagent.check_invariants
mix ezagent.uri_query.scan
mix ezagent.doc.scan
```

Expected: no new violation names a touched file.

- [ ] **Step 4: Run required precommit**

Run: `mix precommit`

Expected: PASS. The design-only baseline run already exposed unrelated failures in `grantee_index.ex`, documentation coverage, cap-self-store timing, and a snapshot expectation. If they remain, report exact output and verify they do not name a touched file; do not absorb those fixes into this change.

- [ ] **Step 5: Review scope**

```bash
git diff --check
git status --short
rg -n "hello" \
  apps/ezagent_domain_session/lib/ezagent/socialware/view_cap_convergence.ex \
  apps/ezagent_domain_session/lib/ezagent/socialware/session_installer.ex \
  apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex
```

Expected: no hello-specific production condition. Existing `.superpowers/sdd/task-1-report.md` and `.superpowers/sdd/task-2-report.md` changes remain outside this work.
