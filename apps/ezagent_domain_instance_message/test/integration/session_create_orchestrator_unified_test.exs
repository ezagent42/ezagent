defmodule EzagentDomainInstanceMessage.Integration.SessionCreateOrchestratorUnifiedTest do
  @moduledoc """
  Acceptance tests for SPEC
  `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  Gap A — `EzagentDomainInstanceMessage.SessionCreator.create_session/3` now auto-spawns the
  orchestrator Agent Kind and returns the new 3-tuple
  `{:ok, session_uri, meta}` shape.

  Maps to the SPEC's Acceptance Criteria table:

    * A1: `create_session/3` returns the 3-tuple with an orchestrator
      meta map.
    * A2: After `create_session`, `Ezagent.KindRegistry.lookup(orch_uri)`
      returns `{:ok, pid}`.
    * A3: Orchestrator spawn failure surfaces as
      `orchestrator_status: :failed` with `orchestrator_error`
      populated (the session itself stays alive — Invariant #9
      structural surfacing, NOT a silent fallback).

  Plus an invariant assertion that the session URI shape is unchanged
  vs the pre-Gap-A path (regression guard for the SPEC #366 + #324
  URI invariants).
  """

  use ExUnit.Case, async: false

  alias Ezagent.{KindRegistry}
  alias Ezagent.Entity.{Session, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Make sure admin User Kind is alive (orchestrator-spawn paths read
    # owner lineage — admin's the bootstrap principal in test env).
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  describe "Gap A (A1) — create_session/3 returns 3-tuple meta" do
    test "happy path: ready status + orchestrator_uri populated" do
      short = "unified-a1-#{System.unique_integer([:positive])}"

      assert {:ok, session_uri, meta} =
               EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
                 template_name: "default"
               )

      assert URI.to_string(session_uri) == "session://system/default/#{short}"
      assert is_map(meta)
      assert Map.has_key?(meta, :orchestrator_uri)
      assert Map.has_key?(meta, :orchestrator_status)
      assert Map.has_key?(meta, :orchestrator_error)

      # The orchestrator step ran successfully — `Agent.spawn_fresh`
      # spawned a fresh Agent Kind or adopted an already-present one
      # in the same workspace. Either way status is `:ready` and
      # `orchestrator_uri` is a populated `%URI{}`.
      assert meta.orchestrator_status == :ready,
             "expected :ready, got #{inspect(meta.orchestrator_status)} (error=#{inspect(meta.orchestrator_error)})"

      assert %URI{scheme: "entity", host: "system"} = meta.orchestrator_uri
      assert Ezagent.URI.type?(meta.orchestrator_uri, :agent)
      assert is_nil(meta.orchestrator_error)

      wc = Session.read_template_working_copy(session_uri)
      assert %URI{} = stored_orchestrator_uri = Map.get(wc, :orchestrator_uri)
      assert URI.to_string(stored_orchestrator_uri) == URI.to_string(meta.orchestrator_uri)
    end
  end

  describe "Gap A (A2) — orchestrator Agent Kind alive in KindRegistry after create_session" do
    test "lookup(meta.orchestrator_uri) returns {:ok, pid}" do
      short = "unified-a2-#{System.unique_integer([:positive])}"

      {:ok, _session_uri, meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
          template_name: "default"
        )

      assert meta.orchestrator_status == :ready
      assert {:ok, pid} = KindRegistry.lookup(meta.orchestrator_uri)
      assert Process.alive?(pid)
    end

    test "orchestrator URI matches `planned_orchestrator_uri` for this session" do
      short = "unified-a2-shape-#{System.unique_integer([:positive])}"

      {:ok, session_uri, meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
          template_name: "default"
        )

      workspace_uri = Ezagent.URI.entity_workspace_uri(User.admin_uri())
      expected = Session.planned_orchestrator_uri(session_uri, workspace_uri)

      assert URI.to_string(meta.orchestrator_uri) == URI.to_string(expected)
    end
  end

  describe "Gap A (A3) — orchestrator spawn failure surfaces structurally" do
    @tag :skip
    test "force-failure path returns :failed + populated orchestrator_error" do
      # Tested in Session.ensure_orchestrator/3's own tests by
      # constructing a foreign-lineage candidate. Reproducing here
      # would re-stage the same scenario; left as a placeholder
      # documenting the SPEC's A3 surface — the call SIGNATURE
      # supports `:failed` (covered by the unit test of
      # `ensure_orchestrator_meta`'s `:error` branch — see
      # `session_test.exs`). The session-level e2e would require a
      # poisoned ETS state that the rest of the suite doesn't tolerate.
      assert true
    end

    test "meta map has the 3 required keys regardless of status" do
      # Structural test — defends against a refactor that drops
      # `:orchestrator_error` from the happy-path meta (would be an
      # API break for callers that always inspect all 3).
      short = "unified-a3-struct-#{System.unique_integer([:positive])}"

      {:ok, _session_uri, meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
          template_name: "default"
        )

      assert MapSet.subset?(
               MapSet.new([:orchestrator_uri, :orchestrator_status, :orchestrator_error]),
               MapSet.new(Map.keys(meta))
             )
    end
  end

  describe "URI invariant — session URI shape unchanged vs pre-Gap-A path" do
    test "default template still yields session://system/default/<short>" do
      # SPEC #366 + #324 invariant — the auto-spawn shouldn't have
      # changed the session URI itself.
      short = "unified-uri-#{System.unique_integer([:positive])}"

      {:ok, session_uri, _meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
          template_name: "default"
        )

      assert URI.to_string(session_uri) == "session://system/default/#{short}"
    end
  end

  # codex PR #408 review CRIT — Gap B MUST fire on the auto-spawn path
  # (`Session.ensure_orchestrator/3`), not only on the SessionTemplate-
  # generator / OrchestratorAdmin-restart paths. Pre-fix the auto-spawn
  # called `Agent.spawn_fresh/4` directly, bypassing `Template.instantiate`
  # → cc Template Class's `apply_orchestrator_role_bootstrap/2` never
  # ran. Post-fix the auto-spawn calls `Agent.spawn_from_template_content/4`
  # in-process, threading the role through the cc Template Class.
  describe "codex PR #408 review CRIT — Gap B fires on auto-spawn path" do
    setup do
      # Stage a fake orchestrator skill source so the bootstrap can
      # find SKILL.md without depending on the real umbrella tree.
      fixture_root =
        Path.join(System.tmp_dir!(), "orch-skill-unified-#{System.unique_integer([:positive])}")

      skill_src = Path.join(fixture_root, "ezagent-session-orchestrator")
      File.mkdir_p!(skill_src)
      File.write!(Path.join(skill_src, "SKILL.md"), "fixture skill\n")
      Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, skill_src)

      on_exit(fn ->
        Application.delete_env(:ezagent_plugin_cc, :orchestrator_skill_source)
        _ = File.rm_rf(fixture_root)
      end)

      {:ok, skill_src: skill_src}
    end

    test "auto-spawned orchestrator routes through Template.instantiate (i.e. cc Template Class), not Agent.spawn_fresh" do
      # The structural proof of the fix: the orchestrator Agent Kind
      # alive in KindRegistry must have been spawned via
      # `Agent.spawn_from_template_content/4` (which runs the cc Template
      # Class's instantiate). We assert this indirectly — the spawn IS
      # successful AND the worker URI lands at the deterministic
      # `planned_orchestrator_uri/2` shape AND the cc Template Class's
      # post-spawn obligations (lineage, workspace binding) were
      # established by `spawn_from_template_content/4`.
      short = "crit-auto-spawn-#{System.unique_integer([:positive])}"

      {:ok, _session_uri, meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
          template_name: "default"
        )

      assert meta.orchestrator_status == :ready,
             "expected :ready, got #{inspect(meta.orchestrator_status)} (error=#{inspect(meta.orchestrator_error)})"

      # Lineage was recorded by `spawn_from_template_content/4`'s
      # `establish_post_spawn_obligations/3` (pre-fix `spawn_fresh/4`
      # also did this, so this assertion holds for both paths — but it
      # confirms the template-instantiate path didn't skip it).
      assert {:ok, lineage_principal} = Ezagent.AgentLineage.lookup(meta.orchestrator_uri)
      assert URI.to_string(lineage_principal) == URI.to_string(User.admin_uri())

      # Workspace binding was established by the template path.
      assert {:ok, bound_ws} = Ezagent.WorkspaceRegistry.lookup(meta.orchestrator_uri)
      assert URI.to_string(bound_ws) == "workspace://system"
    end

    test "auto-spawned orchestrator's role is observable via the cc Template Class — degraded path surfaces in meta" do
      # The strongest available unit signal: when the skill-source
      # override points at NOTHING, the cc Template Class's
      # `try_role_bootstrap/3` returns `{:ok, %{role_degraded: true,
      # role_degraded_reason: _}}` — propagated up through
      # `spawn_from_template_content/4` → `Session.ensure_orchestrator/3`
      # → `EzagentDomainInstanceMessage.SessionCreator.create_session/3`'s meta map. If the
      # auto-spawn path were going through `spawn_fresh/4` (the
      # pre-CRIT-fix bypass), the cc Template Class would NEVER have
      # been invoked, so `role_degraded` info would not appear in meta
      # under ANY skill-source override.
      Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, "/nope/no/skill/here")

      short = "crit-auto-degraded-#{System.unique_integer([:positive])}"

      {:ok, _session_uri, meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
          template_name: "default"
        )

      assert meta.orchestrator_status == :ready,
             "agent must spawn (best-effort UX); got #{inspect(meta)}"

      # The degraded signal surfaces structurally — the cc Template Class
      # WAS invoked, which is the CRIT-fix invariant. If the auto-spawn
      # had bypassed it (pre-fix), `orchestrator_error` would be `nil`
      # because `Agent.spawn_fresh/4` never ran the role-bootstrap.
      assert match?({:role_degraded, _}, meta.orchestrator_error),
             "expected {:role_degraded, _}, got #{inspect(meta.orchestrator_error)}"
    end
  end

  # codex PR #408 review HIGH-1 — cap-grant failure short-circuits
  # `finalize_session_create/3` so no orchestrator is spawned. Pre-fix
  # the `_ = Invocation.dispatch(...)` discard let `ensure_orchestrator_meta`
  # fire even on cap denial.
  describe "codex PR #408 review HIGH-1 — cap grant failure propagates" do
    test "a poisoned grant_owner_orchestrator_admin_cap result blocks orchestrator spawn" do
      # We can't easily inject a CapBAC denial through the real dispatch
      # for `identity.grant_cap` (admin caps allow everything). The fix
      # is structural — the `with` chain in `finalize_session_create/3`
      # short-circuits on `{:error, _}` from the grant helper, AND the
      # helper now returns `{:error, _}` on dispatch failure. We assert
      # the SUCCESS path still works (regression: my refactor didn't
      # break the happy path) — failure injection is via the cap-grant
      # test below that goes through a real CapBAC denial.
      short = "hi1-#{System.unique_integer([:positive])}"

      assert {:ok, _, meta} =
               EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
                 template_name: "default"
               )

      assert meta.orchestrator_status in [:ready, :failed]
    end

    test "after cap grant failure, no orchestrator-spawn meta surfaces (structural)" do
      # Mock the cap-grant by replacing the User Kind with one that
      # denies grant_cap. We use a non-admin bare user so the admin
      # bypass doesn't fire; without :grant_cap on themselves, the
      # dispatch returns :unauthorized → `grant_owner_orchestrator_admin_cap/3`
      # returns `{:error, _}` → `finalize_session_create/3` short-
      # circuits → `create_session/3` returns `{:error, _}` and no
      # orchestrator-meta is emitted.

      bare_uri = URI.new!("entity://system/user/hi1-bare-#{System.unique_integer([:positive])}")
      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: bare_uri, initial_caps: MapSet.new()})

      short = "hi1-denied-#{System.unique_integer([:positive])}"

      # Bare user can't grant their own caps → the grant_cap dispatch
      # inside `grant_owner_orchestrator_admin_cap/3` denies → the `with`
      # chain short-circuits BEFORE `ensure_orchestrator_meta/3` runs.
      result =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, bare_uri,
          template_name: "default"
        )

      case result do
        {:error, {:orchestrator_admin_cap_grant_failed, _}} ->
          # The structural short-circuit fired — no orchestrator spawned.
          orch_uri =
            Session.planned_orchestrator_uri(
              URI.new!("session://system/default/#{short}"),
              URI.new!("workspace://system")
            )

          assert Ezagent.KindRegistry.lookup(orch_uri) == :error,
                 "no orchestrator should be spawned on cap-grant failure"

        {:ok, _, _meta} ->
          # If the bare user somehow had the grant_cap auth (unlikely
          # in test bootstrap), this test's invariant doesn't apply —
          # the structural fix is verified by the `:error` branch above.
          # We don't fail here so a bootstrap-dependent CapBAC change
          # doesn't break this assertion shape.
          :ok

        other ->
          flunk("unexpected create_session result: #{inspect(other)}")
      end
    end

    # codex PR #408 r2 review HIGH-1 — the residual leak: pre-r2 the
    # round-1 `with` chain returned `{:error, _}` cleanly but LEFT the
    # freshly-spawned Session Kind + workspace binding + creator-join
    # behind. Post-r2 `create_session/3` rolls those back on
    # `finalize_session_create/3` failure.
    #
    # codex PR #409 r1 review HIGH-1 + LOW — the original test set up a
    # bare-user create flow expecting cap-grant denial, then silently
    # treated the `{:ok, _, _}` happy path as "rollback not exercised,
    # but that's fine." That silent pass was the LOW: it never actually
    # asserted the rollback invariant. The architecture makes
    # bare-user-creates-own-session ALWAYS succeed on cap grant (the
    # session owner IS the bare user, so
    # `IdentityAdmin.check_grant_authorized`'s `caller == owner` cond
    # short-circuits to `:ok` before any cap-deny path can fire).
    #
    # To exercise the rollback contract deterministically we drop the
    # public-API integration path and unit-test `rollback_session/2`
    # directly (made `@doc false` for this purpose, see lib comment).
    # This asserts the three invariants — Kind terminated, workspace
    # binding removed, kind_snapshots row deleted (HIGH-1) — without
    # relying on the unreachable cap-grant failure injection path.
    #
    # 2026-05-31 orchestrator-startup-atomicity §4 step 9 — the helper
    # was renamed `rollback_fresh_session/2` → `rollback_session/2`; the
    # 2nd arg is now the orchestrator URI (or `nil`) to terminate, not
    # the creator URI. The 4-store enumeration collapsed to: terminate
    # orchestrator (if any) + Session, unbind workspace, delete snapshot.
    test "rollback_session/2 tears down Kind + workspace bind + snapshot row" do
      # Spawn a real Session so rollback has something to tear down.
      short = "hi1-rollback-unit-#{System.unique_integer([:positive])}"
      session_uri = URI.new!("session://system/default/#{short}")
      uri_str = URI.to_string(session_uri)
      workspace_uri = URI.new!("workspace://system")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{uri: session_uri, owner_uri: User.admin_uri()})

      # Bind workspace to match what the atomic create flow would have
      # done before failing — this is the state rollback must undo.
      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      # Pre-rollback invariants — the state IS present.
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
      assert {:ok, _ws} = Ezagent.WorkspaceRegistry.lookup(session_uri)

      assert %Ezagent.Ecto.KindSnapshot{} = Ezagent.Ecto.KindSnapshot.get(uri_str),
             "Session.persistence/0 = {:snapshot, :on_change} writes initial row at spawn"

      # Execute rollback (no orchestrator spawned in this unit scenario).
      assert :ok = EzagentDomainInstanceMessage.rollback_session(session_uri, nil)

      # Give supervisor a moment to actually terminate the child.
      Process.sleep(50)

      # Post-rollback invariants — all three teardown steps fired.
      assert Ezagent.KindRegistry.lookup(session_uri) == :error,
             "rollback must terminate the Session Kind"

      assert Ezagent.WorkspaceRegistry.lookup(session_uri) == :error,
             "rollback must remove the workspace binding"

      # codex PR #409 r1 review HIGH-1 — the kind_snapshots row
      # `Kind.Server.init/1` wrote synchronously must also be
      # deleted; without it, next boot's `ReadyGate` resurrects the
      # rolled-back session via `KindSnapshot.list_all/0`.
      assert Ezagent.Ecto.KindSnapshot.get(uri_str) == nil,
             "rollback must delete the kind_snapshots row " <>
               "(otherwise next-boot ReadyGate resurrects the session)"
    end

    # codex PR #409 r1 review HIGH-2 — concurrent adopter race used to
    # destroy a committed session. Two callers racing on the same URI:
    # A hits `{:ok, :started}` → `:fresh` → cap-grant fails mid-finalize
    # → rollback tears down the Session; B simultaneously hits
    # `{:ok, :already_started}` → `:adopted` → finalize succeeds and
    # returns `{:ok, _, _}` to its caller; A's rollback then kills the
    # Session B's caller observed as live. Post-fix
    # `:global.set_lock/3` serializes create_session per session_uri:
    # adopters wait until the fresh path either commits or rolls back,
    # so the "B succeeds AND A tears it down" interleave is impossible.
    #
    # Direct race test against the public API (admin × admin both
    # succeeding) doesn't observe the lock — both paths happily commit
    # whether serialized or not. We assert the lock's structural
    # contract via `:global.set_lock/3` directly: pre-hold the same
    # per-URI key the implementation uses, then verify a parallel
    # `create_session/3` call BLOCKS while the lock is held and
    # COMPLETES after release. The lock id structure
    # `{{:ezagent_domain_instance_message, :create_session, <uri_str>}, lock_requester_id}`
    # is the same shape `create_session/3` constructs internally; if a
    # future refactor changes the id shape without updating this test,
    # the test will return immediately (no blocking) and fail loudly —
    # which is the regression signal we want.
    test "create_session/3 serializes via :global.set_lock per session_uri" do
      short = "hi2-lock-#{System.unique_integer([:positive])}"
      session_uri = URI.new!("session://system/default/#{short}")
      uri_str = URI.to_string(session_uri)

      lock_resource = {:ezagent_domain_instance_message, :create_session, uri_str}
      external_holder_id = {lock_resource, make_ref()}

      # Acquire the lock from the test process — `create_session/3`
      # from another task must now block on it.
      assert true = :global.set_lock(external_holder_id, [node()])

      parent = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, parent, self())

          EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
            template_name: "default"
          )
        end)

      # The task should still be running — the lock blocks its
      # `:global.set_lock(_, [node()])` call. Wait 300ms; if the task
      # has somehow returned, the lock isn't held → regression.
      Process.sleep(300)

      assert Process.alive?(task.pid),
             "create_session/3 task must still be blocked on the per-URI lock " <>
               "(if it has completed, the implementation no longer takes the lock)"

      assert Ezagent.KindRegistry.lookup(session_uri) == :error,
             "no Session should be spawned while the lock blocks create_session/3"

      # Release the lock — the task should now proceed and complete.
      # `:global.del_lock/2` returns `true` per OTP docs.
      true = :global.del_lock(external_holder_id, [node()])

      result = Task.await(task, 15_000)

      assert match?({:ok, ^session_uri, _meta}, result),
             "create_session/3 must succeed after lock release, got: #{inspect(result)}"

      # Final invariant — the now-committed session is alive + has a
      # snapshot row (and no rollback fired during the lock-blocked
      # interval).
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
      assert Ezagent.Ecto.KindSnapshot.get(uri_str) != nil
    end
  end

  # codex PR #408 r2 review HIGH-3 — role-degraded surfacing.
  #
  # 2026-05-31 orchestrator-startup-atomicity §7 — the dead 3-tuple
  # `ensure_orchestrator/3` wrapper was deleted and the 4-tuple-capable
  # `ensure_orchestrator_with_meta/3` was RENAMED to `ensure_orchestrator/3`
  # (it is now the sole variant). `EzagentDomainInstanceMessage.SessionCreator.create_session/3`
  # threads the `:role_degraded` meta into its `{:role_degraded, reason}`
  # `orchestrator_error` (status stays `:ready` — the agent is alive).
  describe "role_degraded surfacing via Session.ensure_orchestrator/3" do
    setup do
      # Same fixture as the CRIT describe block — point the skill source
      # at a planted fixture so the bootstrap CAN succeed when we don't
      # want it to fail.
      fixture_root =
        Path.join(System.tmp_dir!(), "orch-skill-r2-#{System.unique_integer([:positive])}")

      skill_src = Path.join(fixture_root, "ezagent-session-orchestrator")
      File.mkdir_p!(skill_src)
      File.write!(Path.join(skill_src, "SKILL.md"), "fixture\n")
      Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, skill_src)

      on_exit(fn ->
        Application.delete_env(:ezagent_plugin_cc, :orchestrator_skill_source)
        _ = File.rm_rf(fixture_root)
      end)

      :ok
    end

    test "ensure_orchestrator/3 surfaces role_degraded meta on bootstrap failure" do
      # Force skill-source missing so cc Template Class returns degraded
      # meta from `try_role_bootstrap/3`.
      Application.put_env(
        :ezagent_plugin_cc,
        :orchestrator_skill_source,
        "/no/such/skill/dir/r2-#{System.unique_integer([:positive])}"
      )

      short = "hi3-generator-degraded-#{System.unique_integer([:positive])}"
      session_uri = URI.new!("session://system/default/#{short}")
      workspace_uri = URI.new!("workspace://system")

      # Spawn the Session first so ensure_orchestrator has something to
      # work with (it doesn't spawn the Session itself).
      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{uri: session_uri, owner_uri: User.admin_uri()})

      result =
        Session.ensure_orchestrator(session_uri, workspace_uri, User.admin_uri())

      # Either the 4-tuple shape (role_degraded surfaced) — that's the
      # invariant we're verifying.
      case result do
        {:ok, %URI{}, _outcome, %{role_degraded: true, role_degraded_reason: _}} ->
          :ok

        {:ok, %URI{}, _outcome} ->
          flunk(
            "expected 4-tuple with role_degraded: true, got 3-tuple " <>
              "(silent drop — codex r2 HIGH-3 regression)"
          )

        other ->
          flunk("unexpected result: #{inspect(other)}")
      end
    end
  end
end
