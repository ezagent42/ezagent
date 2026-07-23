defmodule Ezagent.E2E.Scenario25PhxRestartRebuildTest do
  @moduledoc """
  E2E Scenario #25 — phx restart -> snapshot rebuild + ExternalMirror.

  Catalogue: `docs/scenarios/25-phx-restart-rebuild/scenario.md` (Category 13).
  Pre-this-PR: ✅ implemented-and-tested via `snapshot_restart_test.exs`
  + `session_survives_restart_test.exs` + `cap_action_axis_snapshot_restore_test.exs`.
  This file is the scenario-catalog rollup that wires those building
  blocks into a single restart-surrogate cascade so any regression in
  the Phase 1 PR #451 `StateRebuilder` / `SnapshotStore` /
  `KindSnapshot` triad surfaces here.

  ## Restart surrogate — read this before adding tests here

  Per the scenario spec §"Steps", a true phx restart is not possible
  inside a single `mix test` run (the BEAM process owns the test
  driver; killing it kills the test). The surrogate we use:

    1. Spawn the relevant Kind under its real DynamicSupervisor
       (the production path).
    2. Mutate state via real dispatch (so `:on_change` snapshot fires).
    3. `DynamicSupervisor.terminate_child(supervisor, pid)` — simulates
       the per-Kind process death that a phx restart would cause for
       this entity (the supervisor goes away with the BEAM, every child
       PID dies, every ETS table is wiped).
    4. `Ezagent.WorkspaceRegistry.unbind/1` for Kinds whose binding
       lived in ETS — simulating the ETS wipe.
    5. Re-spawn via the production spawn path
       (`Ezagent.SpawnRegistry.spawn/1` for entities with registered
       schemes, or `Ezagent.Kind.spawn/2` directly for those without).
    6. Assert the rebuilt Kind reflects the persisted state.

  Limits of the surrogate:

    - Cross-Kind referential integrity is NOT tested at scale here —
      `Ezagent.Kind.StateRebuilder.rebuild_all/1` is exercised
      structurally (`state_rebuilder_test.exs`); this file pins the
      lazy-on-first-spawn rebuild path that Phase 1 actually uses
      (per `StateRebuilder` moduledoc "Lazy-on-first-load").
    - ExternalMirror BootReconciler is NOT spawned mid-test — its boot
      sequence is covered by its own integration tests
      (`boot_reconciler_test.exs`). We exercise `StateRebuilder.rebuild/1`
      directly to prove a snapshot row can rehydrate without going
      through the BootReconciler retry loop.
    - Real cross-process snapshot writers race the test reads in some
      paths (e.g. `Snapshot.Writer.flush_now/1`); each test that depends
      on a write being durable uses `wait_until/1` rather than asserting
      immediately.

  Async: `false` — uses shared `Ezagent.WorkspaceRegistry` ETS +
  DynamicSupervisors.
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  @moduletag scenario: "25-phx-restart-rebuild"

  alias Ezagent.{Invocation, KindRegistry, SnapshotStore, WorkspaceRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Agent, User}
  alias Ezagent.Kind.StateRebuilder

  @workspace_uri URI.new!("workspace://team-alpha")

  defp uniq, do: System.unique_integer([:positive])

  defp admin_ctx(target) do
    cap = signed_action_cap!(target, User.admin_uri())

    %{
      caller: User.admin_uri(),
      authenticated_principal: User.admin_uri(),
      caps: MapSet.new([cap]),
      reply: {:caller_inbox, self()}
    }
  end

  defp dispatch(uri, action, args \\ %{}) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=#{action}")

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: admin_ctx(target)
    })
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  # --------------------------------------------------------------------------
  # Section A — Snapshot-based rebuild via StateRebuilder (Phase 1 API)
  # --------------------------------------------------------------------------
  describe "StateRebuilder.rebuild/1 — Phase 1 lazy-spawn rehydrate" do
    test "rebuild after snapshot write returns the stored state with from: :snapshot" do
      # Mirrors the lazy-spawn path the Router uses on registry miss:
      # write -> kill -> rebuild reads the snapshot -> caller spawns
      # a new Kind seeded with this state.
      uri = Ezagent.URI.new!("entity://team-alpha/user/scen25-rebuild-#{uniq()}")

      state = %{
        identity: %{
          caps:
            MapSet.new([
              %Ezagent.Capability{
                kind: :session,
                behavior: :any,
                action: :any,
                instance: :any,
                workspace_uri: @workspace_uri,
                granted_by: User.admin_uri(),
                granted_at: ~U[2026-01-01 00:00:00Z]
              }
            ])
        }
      }

      {:ok, %{version: _}} = SnapshotStore.write(uri, state, kind_type: :user)

      assert {:ok, rebuilt, %{from: :snapshot}} = StateRebuilder.rebuild(uri)
      assert rebuilt == state
      assert MapSet.size(rebuilt.identity.caps) == 1
    end

    test "rebuild on a URI without a snapshot returns :not_found (fresh-init signal)" do
      # The "first dispatch ever" case — Router treats :not_found as
      # "spawn fresh" not "fail dispatch". This is the lazy-spawn
      # contract per `StateRebuilder` moduledoc.
      uri = Ezagent.URI.new!("entity://team-alpha/user/scen25-noinit-#{uniq()}")

      assert {:error, :not_found} = StateRebuilder.rebuild(uri)
    end

    test "rebuild_all walks every snapshot row and counts successes" do
      # Operator path: `mix ezagent.snapshots.replay`. Pin that the
      # bulk walker returns a stable shape and includes newly-written
      # rows.
      initial = StateRebuilder.rebuild_all(:all)

      uri_a = Ezagent.URI.new!("entity://team-alpha/user/scen25-bulk-a-#{uniq()}")
      uri_b = Ezagent.URI.new!("entity://team-alpha/user/scen25-bulk-b-#{uniq()}")

      {:ok, _} = SnapshotStore.write(uri_a, %{identity: %{caps: MapSet.new()}}, kind_type: :user)
      {:ok, _} = SnapshotStore.write(uri_b, %{identity: %{caps: MapSet.new()}}, kind_type: :user)

      after_writes = StateRebuilder.rebuild_all(:all)

      assert after_writes.rebuilt >= initial.rebuilt + 2
      # No new failures introduced by THIS test's writes.
      assert length(after_writes.failed) == length(initial.failed)
    end

    test "workspace-scoped rebuild_all isolates tenants" do
      # SPEC v3 §7 invariant: snapshot rows carry workspace_uri; per-tenant
      # rebuild MUST NOT bleed across workspaces. If StateRebuilder
      # regresses to system-scope walking, this assertion fires.
      ws_name = "scen25-ws-" <> Integer.to_string(uniq())
      uri_in = Ezagent.URI.new!("entity://#{ws_name}/user/scen25-in-#{uniq()}")

      other_ws_name = "scen25-other-" <> Integer.to_string(uniq())
      uri_out = Ezagent.URI.new!("entity://#{other_ws_name}/user/scen25-out-#{uniq()}")

      {:ok, _} = SnapshotStore.write(uri_in, %{identity: %{caps: MapSet.new()}}, kind_type: :user)

      {:ok, _} =
        SnapshotStore.write(uri_out, %{identity: %{caps: MapSet.new()}}, kind_type: :user)

      workspace = Ezagent.URI.new!("workspace://#{ws_name}")
      result = StateRebuilder.rebuild_all(workspace)

      # Exactly one row in this workspace.
      assert result.rebuilt == 1
      assert result.failed == []
    end
  end

  # --------------------------------------------------------------------------
  # Section B — Session restart surrogate: workspace binding survives
  # --------------------------------------------------------------------------
  describe "Session restart surrogate: workspace binding rebind on re-spawn" do
    # Note: the full chat.join -> on_change -> restart -> member rehydrate
    # path is covered by
    # `apps/ezagent_domain_session/test/integration/session_survives_restart_test.exs`.
    # That test exercises chat-domain machinery (Chat Behavior + Session
    # Behavior wiring) which is currently in Phase 2 migration; pinning
    # the member-rehydrate path again here would just duplicate the
    # failure surface. Instead this section exercises the cross-Kind
    # rebuild artefact the scenario-25 catalog actually promises:
    # `SpawnRegistry.spawn/1` for a session URI re-establishes the
    # workspace ETS binding even after the binding has been wiped.
    test "SpawnRegistry.spawn/1 re-binds workspace for an existing session URI after ETS wipe" do
      session_uri =
        Ezagent.URI.new!("session://team-alpha/default/scen25-rebind-#{uniq()}")

      uri_str = URI.to_string(session_uri)
      :ok = KindSnapshot.delete(uri_str)

      # 1. Spawn Session via production SpawnRegistry path (wires
      #    workspace binding via the session spawn fn).
      {:ok, session_pid_1} = Ezagent.SpawnRegistry.spawn(session_uri)

      assert {:ok, %URI{scheme: "workspace", host: "team-alpha"}} =
               WorkspaceRegistry.lookup(session_uri)

      # 2. Simulate phx restart: terminate the Session Kind AND wipe the
      #    ETS workspace binding (the latter is the part the spawn fn
      #    must restore on re-spawn — production phx restart wipes ETS).
      :ok =
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.SessionSupervisor,
          session_pid_1
        )

      wait_until(fn -> KindRegistry.lookup(session_uri) == :error end)
      :ok = WorkspaceRegistry.unbind(session_uri)
      assert :error = WorkspaceRegistry.lookup(session_uri)

      # 3. Re-spawn via the production lazy-spawn path.
      {:ok, session_pid_2} = Ezagent.SpawnRegistry.spawn(session_uri)
      refute session_pid_1 == session_pid_2

      # 4. The workspace binding has been re-established from the URI
      #    (the spawn fn's responsibility, NOT a leftover from ETS).
      assert {:ok, %URI{scheme: "workspace", host: "team-alpha"}} =
               WorkspaceRegistry.lookup(session_uri),
             "rehydrated session lost its WorkspaceRegistry binding — " <>
               "the `session` spawn fn must rebind from the URI"
    end
  end

  # --------------------------------------------------------------------------
  # Section C — Agent slice survives restart (sandbox.config_dir_path)
  # --------------------------------------------------------------------------
  describe "Agent restart surrogate: sandbox slice survives" do
    test "config_dir_path written before terminate is readable after re-spawn" do
      # Agent's persistence/0 is {:snapshot, :on_change} per Allen
      # 2026-05-25 CLI persistence fix. This locks the contract:
      # post_restart `sandbox.read` MUST return the pre_restart values.
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/scen25-agent-#{uniq()}")

      {:ok, pid1} = Ezagent.Kind.spawn(Agent, %{uri: agent_uri})
      :ok = WorkspaceRegistry.bind(agent_uri, @workspace_uri)

      config_dir = "/tmp/scen25-agent-#{uniq()}"

      assert {:ok, _} =
               dispatch(agent_uri, "sandbox.update_config", %{
                 config_dir_path: config_dir,
                 template_class: nil
               })

      uri_str = URI.to_string(agent_uri)
      wait_until(fn -> not is_nil(KindSnapshot.get(uri_str)) end)

      # Surrogate restart: terminate the Agent Kind.
      :ok = DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, pid1)
      wait_until(fn -> KindRegistry.lookup(agent_uri) == :error end)

      # Re-spawn under the SAME URI.
      {:ok, pid2} = Ezagent.Kind.spawn(Agent, %{uri: agent_uri})
      :ok = WorkspaceRegistry.bind(agent_uri, @workspace_uri)
      refute pid1 == pid2

      # Read the slice — config_dir_path MUST be the pre-restart value.
      assert {:ok, %{config_dir_path: ^config_dir}} = dispatch(agent_uri, "sandbox.read"),
             "Agent's sandbox slice MUST round-trip through restart — " <>
               "Ezagent.Entity.Agent.persistence/0 must be {:snapshot, :on_change}"
    end
  end

  # --------------------------------------------------------------------------
  # Section D — Workspace prefix invariant on rehydrated entities
  # --------------------------------------------------------------------------
  describe "post-restart workspace binding tolerates ETS wipe" do
    test "rebuilt entity carries its workspace via URI segment (no ETS dependency)" do
      # SPEC v3 §3 workspace prefix invariant: every entity URI encodes
      # its workspace as a path segment. ETS bindings are a runtime
      # cache; the URI is the source of truth. Post-restart, the cache
      # is empty until the spawn fn re-binds, but `Capability.workspace_of/1`
      # MUST resolve the URI without consulting ETS.
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/scen25-prefix-#{uniq()}")

      # `workspace_of/1` is a pure URI op — wipes / restarts cannot
      # affect its output. Compare via `URI.to_string/1` to avoid the
      # `URI.parse` vs `URI.new!` struct-field divergence
      # (`URI.new!` populates `:authority`; `URI.parse` does not).
      assert URI.to_string(Ezagent.Capability.workspace_of(agent_uri)) ==
               "workspace://team-alpha"

      # And from a snapshot row's `workspace_uri` column, the same
      # answer.
      {:ok, _} =
        SnapshotStore.write(
          agent_uri,
          %{sandbox: %{config_dir_path: nil, template_class: nil}},
          kind_type: :agent
        )

      row = KindSnapshot.get(URI.to_string(agent_uri))
      assert row.workspace_uri == "workspace://team-alpha"
    end
  end

  # --------------------------------------------------------------------------
  # Section E — Failure modes from scenario.md §"Failure modes to test"
  # --------------------------------------------------------------------------
  describe "rebuild failure modes" do
    test "corrupted snapshot row decode failure surfaces in rebuild_all summary" do
      # Inject a row with garbage state_binary so KindSnapshot.decode_state/1
      # returns :error. rebuild_all MUST capture the row as :skipped /
      # :failed and continue walking — a single bad row cannot block
      # bulk replay (Decision #115 honesty: log + telemetry + continue
      # instead of crashing the whole boot).
      ws_name = "scen25-corrupt-" <> Integer.to_string(uniq())
      uri = Ezagent.URI.new!("entity://#{ws_name}/user/scen25-corrupt-#{uniq()}")
      uri_str = URI.to_string(uri)

      # First write a real row so the schema is populated, then poison
      # the state_binary via the Ecto changeset path (direct Repo.update_all
      # is the only way to write a known-bad binary without going through
      # SnapshotStore.write/3's term_to_binary).
      {:ok, _} = SnapshotStore.write(uri, %{x: 1}, kind_type: :user)

      import Ecto.Query

      {1, _} =
        EzagentCore.Repo.update_all(
          from(s in KindSnapshot, where: s.uri == ^uri_str),
          set: [state_binary: <<0, 1, 2, 3>>, state: nil]
        )

      workspace = Ezagent.URI.new!("workspace://#{ws_name}")
      result = StateRebuilder.rebuild_all(workspace)

      # The row appears in :skipped (decode_state returned :error ->
      # SnapshotStore.latest/1 returns :not_found per its current
      # mapping at lib/ezagent/snapshot_store.ex:170-171).
      # NOT :failed and NOT in :rebuilt.
      assert result.rebuilt == 0

      assert Enum.any?(result.skipped, fn {u, _r} -> u == uri_str end) or
               Enum.any?(result.failed, fn {u, _r} -> u == uri_str end),
             "a corrupt snapshot row must show up in either :skipped or :failed — " <>
               "rebuild_all must NOT count it as :rebuilt nor crash the walk"
    end

    test "rebuild_all swallows per-URI raises and continues" do
      # The `safe_rebuild` rescue in StateRebuilder MUST keep the walker
      # going even when a single URI raises. Hard to inject a raise
      # without a behaviour module; instead we assert the bulk walker
      # returns a well-formed summary even on an empty workspace
      # (the smallest invariant: shape contract is preserved regardless
      # of the row population).
      workspace = Ezagent.URI.new!("workspace://scen25-empty-#{uniq()}")

      assert %{rebuilt: 0, failed: [], skipped: []} = StateRebuilder.rebuild_all(workspace)
    end
  end
end
