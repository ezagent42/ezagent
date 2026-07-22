defmodule Ezagent.Invariants.KindInitPersistsInitialSnapshotTest do
  @moduledoc """
  Allen 2026-05-25 — CLI persistence invariant.

  Per `feedback_completion_requires_invariant_test`: the architectural
  goal of this fix is "a Kind spawned via mix-task SURVIVES the mix
  BEAM exit." The test that fails when that goal is unmet:

      after `Ezagent.Kind.spawn/2` returns successfully, a
      `kind_snapshots` row MUST exist for any non-ephemeral Kind
      (`{:snapshot, :on_change}` / `{:snapshot, :periodic, _}` /
      `:on_terminate`), with no wait, no mutation, no terminate.

  Without `Kind.Server.init/1`'s `persist_initial_snapshot/3` call
  this test fails for `:on_change`, `:on_terminate`, and `:periodic`
  Kinds because the framework historically only wrote snapshots on
  slice mutation (dispatch), periodic timer tick, or graceful
  `terminate/2` — all three assuming a long-lived BEAM.

  `:ephemeral` / `:external` Kinds explicitly opt out of DB
  persistence; the test asserts no row appears for those (regression
  guard: the init-time write MUST respect the policy).

  Bug: `mix ezagent.agent.create entity://system/agent/cc_*` produced
  an `Ezagent.Entity.Agent` (`:on_terminate` policy) that was lost on
  mix BEAM exit — the agent was visible in the spawning BEAM but
  invisible to any subsequent BEAM lookup.

  Fix: `Ezagent.Kind.Server.init/1` now calls
  `Ezagent.Kind.Snapshot.save_now/3` for every non-ephemeral policy,
  synchronously, immediately after `KindRegistry.put_new` succeeds.
  """

  use EzagentCore.DataCase, async: false
  import ExUnit.CaptureLog

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Ecto.KindSnapshot

  defmodule LaunchVisibilityProbeBehavior do
    @behaviour Ezagent.ActionSet
    def actions, do: []
    def interface, do: %{}
    def required_caps, do: %{}
    def cap_subjects, do: []
    def state_slice, do: :launch_visibility_probe
    def persistence, do: :ephemeral
    def init_slice(args), do: %{saw_launch_context?: Map.has_key?(args, :launch_context)}
    def data_owner(_), do: :any
  end

  defmodule BeforeStartProbeKind do
    @behaviour Ezagent.Kind

    @impl Ezagent.Kind
    def type_name, do: :before_start_probe

    @impl Ezagent.Kind
    def behaviors, do: [LaunchVisibilityProbeBehavior]

    @impl Ezagent.Kind
    def persistence, do: {:snapshot, :on_change}

    @impl Ezagent.Kind
    def before_start(%{probe_pid: probe_pid, probe_result: {:error, reason}}) do
      send(probe_pid, {:before_start_entered, self()})
      {:error, reason}
    end

    def before_start(%{probe_pid: probe_pid, probe_result: :block} = args) do
      send(probe_pid, {:before_start_entered, self(), Map.fetch!(args, :launch_context)})

      receive do
        :release_before_start -> :ok
      end
    end

    def before_start(%{probe_pid: probe_pid} = args) do
      send(probe_pid, {:before_start_entered, self(), Map.get(args, :launch_context, :absent)})
      :ok
    end
  end

  defmodule RaisingSupervisorKind do
    @behaviour Ezagent.Kind
    def type_name, do: :raising_supervisor_probe
    def behaviors, do: []
    def persistence, do: :ephemeral
    def supervisor, do: raise("supervisor resolution failed")
  end

  defmodule EphemeralRelayProbeKind do
    @behaviour Ezagent.Kind
    def type_name, do: :ephemeral_relay_probe
    def behaviors, do: [LaunchVisibilityProbeBehavior]
    def persistence, do: :ephemeral
    def before_start(args), do: BeforeStartProbeKind.before_start(args)
  end

  defmodule ExitingSupervisorKind do
    @behaviour Ezagent.Kind
    def type_name, do: :exiting_supervisor_probe
    def behaviors, do: []
    def persistence, do: :ephemeral
    def supervisor, do: exit(:supervisor_resolution_failed)
  end

  defmodule CustomStrategyProbe do
    def spawn(params) do
      send(Map.fetch!(params, :probe_pid), :custom_strategy_invoked)
      {:ok, self()}
    end
  end

  defmodule CustomStrategyKind do
    @behaviour Ezagent.Kind
    def type_name, do: :custom_strategy_probe
    def behaviors, do: []
    def persistence, do: :ephemeral
    def spawn_strategy, do: {:custom, CustomStrategyProbe, :spawn}
  end

  describe "before_start/1 ordering" do
    test "launch context lives only in a private per-launch relay" do
      context = make_ref()
      relay = Ezagent.Kind.LaunchContextRelay.issue(context)

      assert is_pid(relay)
      assert nil == Process.whereis(Ezagent.Kind.LaunchContextRelay)
      assert :undefined == :ets.whereis(Ezagent.Kind.LaunchContextRelay)
      assert :undefined == :ets.whereis(Ezagent.Kind.LaunchContextStore)
      refute function_exported?(Ezagent.Kind.LaunchContextRelay, :table, 0)
      refute inspect(:sys.get_status(relay)) =~ inspect(context)
      assert {:ok, ^context} = Ezagent.Kind.LaunchContextRelay.take(relay)
      assert :ok = Ezagent.Kind.LaunchContextRelay.commit(relay, self())
      assert :consumed = Ezagent.Kind.LaunchContextRelay.take(relay)
    end

    test "a lost pending token cannot become a context-free live Kind" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_before-start-lost-#{System.unique_integer([:positive])}"
        )

      parent = self()

      relay = Ezagent.Kind.LaunchContextRelay.issue(make_ref())
      relay_ref = Process.monitor(relay)
      Process.exit(relay, :kill)
      assert_receive {:DOWN, ^relay_ref, :process, ^relay, :killed}

      task =
        Task.async(fn ->
          Process.flag(:trap_exit, true)

          Ezagent.Kind.Server.start_link(
            {BeforeStartProbeKind,
             %{
               uri: uri,
               probe_pid: parent,
               probe_result: :ok,
               launch_context_relay: relay
             }}
          )
        end)

      assert {:error, :launch_context_lost} = Task.await(task)

      refute_receive {:before_start_entered, _, _}
      assert :error == Ezagent.KindRegistry.lookup(uri)
    end

    test "issuer death abandons a pending context without exposing it in status" do
      parent = self()
      context = make_ref()

      {issuer, issuer_ref} =
        spawn_monitor(fn ->
          relay = Ezagent.Kind.LaunchContextRelay.issue(context)
          send(parent, {:issued, relay})
        end)

      assert_receive {:issued, relay}
      relay_ref = Process.monitor(relay)
      assert_receive {:DOWN, ^issuer_ref, :process, ^issuer, :normal}
      assert_receive {:DOWN, ^relay_ref, :process, ^relay, reason}
      assert reason in [:normal, :noproc]
    end

    test "raise and exit paths discard pending authority context" do
      for {kind, expected} <- [
            {RaisingSupervisorKind, RuntimeError},
            {ExitingSupervisorKind, :supervisor_resolution_failed}
          ] do
        context = make_ref()
        relays_before = launch_context_relays()

        caught =
          try do
            Ezagent.Kind.spawn(kind, %{uri: URI.parse("entity://team-alpha/agent/failure")},
              launch_context: context
            )
          rescue
            error -> error.__struct__
          catch
            :exit, reason -> reason
          end

        assert caught == expected

        assert launch_context_relays() == relays_before
      end
    end

    test "custom spawn strategy fails closed before invocation" do
      assert {:error, :launch_context_unsupported} =
               Ezagent.Kind.spawn(CustomStrategyKind, %{probe_pid: self()},
                 launch_context: make_ref()
               )

      refute_receive :custom_strategy_invoked
    end

    test "blocks snapshot and live registration until the hook succeeds" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_before-start-block-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(uri)
      parent = self()
      launch_context = make_ref()

      task =
        Task.async(fn ->
          Ezagent.Kind.spawn(
            BeforeStartProbeKind,
            %{uri: uri, probe_pid: parent, probe_result: :block},
            launch_context: launch_context
          )
        end)

      assert_receive {:before_start_entered, server_pid, ^launch_context}
      assert nil == KindSnapshot.get(uri_str)
      assert :error == Ezagent.KindRegistry.lookup(uri)
      assert :unknown == Ezagent.ReadyGate.status(uri_str)

      send(server_pid, :release_before_start)
      assert {:ok, ^server_pid} = Task.await(task)
      assert %KindSnapshot{kind_type: "before_start_probe"} = KindSnapshot.get(uri_str)
      assert {:ok, ^server_pid} = Ezagent.KindRegistry.lookup(uri)
    end

    test "post-take child death before init acknowledgement reclaims the relay" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_before-start-pre-ack-#{System.unique_integer([:positive])}"
        )

      relays_before = launch_context_relays()
      parent = self()

      task =
        Task.async(fn ->
          Ezagent.Kind.spawn(
            BeforeStartProbeKind,
            %{uri: uri, probe_pid: parent, probe_result: :block},
            launch_context: make_ref()
          )
        end)

      assert_receive {:before_start_entered, child, _context}
      assert [relay] = MapSet.to_list(MapSet.difference(launch_context_relays(), relays_before))
      relay_ref = Process.monitor(relay)
      Process.exit(child, :kill)

      assert {:error, :killed} = Task.await(task)
      assert_receive {:DOWN, ^relay_ref, :process, ^relay, :normal}
      assert launch_context_relays() == relays_before
    end

    test "rejection leaves no snapshot, readiness registration, or live Kind" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_before-start-reject-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(uri)

      assert {:error, {:before_start_failed, :probe_rejected}} =
               Ezagent.Kind.spawn(
                 BeforeStartProbeKind,
                 %{uri: uri, probe_pid: self(), probe_result: {:error, :probe_rejected}}
               )

      assert_receive {:before_start_entered, _server_pid}
      assert nil == KindSnapshot.get(uri_str)
      assert :error == Ezagent.KindRegistry.lookup(uri)
      assert :unknown == Ezagent.ReadyGate.status(uri_str)
    end

    test "supervised replacement does not replay context and behavior/live state cannot see it" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_before-start-restart-#{System.unique_integer([:positive])}"
        )

      launch_context = make_ref()

      assert {:ok, pid} =
               Ezagent.Kind.spawn(
                 BeforeStartProbeKind,
                 %{uri: uri, probe_pid: self(), probe_result: :ok},
                 launch_context: launch_context
               )

      assert_receive {:before_start_entered, ^pid, ^launch_context}
      refute inspect(:sys.get_state(pid)) =~ inspect(launch_context)
      assert %{launch_visibility_probe: %{saw_launch_context?: false}} = :sys.get_state(pid).state

      snapshot = KindSnapshot.get(URI.to_string(uri))
      refute inspect(:erlang.binary_to_term(snapshot.state_binary)) =~ inspect(launch_context)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert_receive {:before_start_entered, replacement, :absent}
      assert replacement != pid
      refute_receive {:before_start_entered, ^replacement, ^launch_context}
    end

    test "relay loss before initial take fails closed" do
      relay = Ezagent.Kind.LaunchContextRelay.issue(make_ref())
      ref = Process.monitor(relay)
      Process.exit(relay, :kill)
      assert_receive {:DOWN, ^ref, :process, ^relay, :killed}

      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/lost-relay-#{System.unique_integer([:positive])}"
        )

      parent = self()

      task =
        Task.async(fn ->
          Process.flag(:trap_exit, true)

          Ezagent.Kind.Server.start_link(
            {BeforeStartProbeKind,
             %{uri: uri, probe_pid: parent, probe_result: :ok, launch_context_relay: relay}}
          )
        end)

      assert {:error, :launch_context_lost} = Task.await(task)

      refute_receive {:before_start_entered, _, _}
      assert :error == Ezagent.KindRegistry.lookup(uri)
    end

    test "explicit Kind removal reclaims its consumed relay" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/relay-lifecycle-#{System.unique_integer([:positive])}"
        )

      assert {:ok, pid} =
               Ezagent.Kind.spawn(
                 EphemeralRelayProbeKind,
                 %{uri: uri, probe_pid: self(), probe_result: :ok},
                 launch_context: make_ref()
               )

      assert_receive {:before_start_entered, ^pid, _}
      %{launch_context_relay: relay} = :sys.get_state(pid)
      relay_ref = Process.monitor(relay)
      assert Process.alive?(relay)

      assert :ok = Ezagent.Kind.terminate(uri)
      assert_receive {:DOWN, ^relay_ref, :process, ^relay, :normal}, 1_000
      refute Process.alive?(pid)
    end

    test "Kind.spawn/3 rejects unknown options before starting a child" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_before-start-options-#{System.unique_integer([:positive])}"
        )

      assert {:error, [:launch_context_typo]} =
               Ezagent.Kind.spawn(
                 BeforeStartProbeKind,
                 %{uri: uri, probe_pid: self(), probe_result: :ok},
                 launch_context_typo: make_ref()
               )

      refute_receive {:before_start_entered, _, _}
    end

    test "rejection output does not expose the launch handle" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_before-start-redaction-#{System.unique_integer([:positive])}"
        )

      launch_context = make_ref()
      relays_before = launch_context_relays()

      output =
        capture_log(fn ->
          assert {:error, {:before_start_failed, :probe_rejected}} =
                   Ezagent.Kind.spawn(
                     BeforeStartProbeKind,
                     %{uri: uri, probe_pid: self(), probe_result: {:error, :probe_rejected}},
                     launch_context: launch_context
                   )
        end)

      refute output =~ inspect(launch_context)
      assert launch_context_relays() == relays_before
    end
  end

  defp launch_context_relays do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          Keyword.get(dictionary, :"$initial_call") ==
            {Ezagent.Kind.LaunchContextRelay, :init, 1}

        nil ->
          false
      end
    end)
    |> MapSet.new()
  end

  describe "init writes initial snapshot for non-ephemeral Kinds" do
    test "{:snapshot, :on_change} — row exists immediately after spawn" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_init-snap-onchange-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(uri)

      # Pre-condition — no row before spawn
      assert nil == KindSnapshot.get(uri_str)

      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({Ezagent.Test.OnChangeTestKind, %{uri: uri}})

      # Invariant — row exists IMMEDIATELY (no wait, no mutation).
      # Without the init-time write, this would be nil until a
      # dispatch arrived to mutate the slice. The CLI bug is that
      # the BEAM exits before any such dispatch.
      assert %KindSnapshot{kind_type: "test"} = KindSnapshot.get(uri_str)
    end

    test ":on_terminate — row exists immediately after spawn" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_init-snap-onterm-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(uri)

      assert nil == KindSnapshot.get(uri_str)

      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({Ezagent.Test.OnTerminateTestKind, %{uri: uri}})

      # The CLI bug's primary case — `:on_terminate` Kinds (like
      # `Ezagent.Entity.Agent`) historically only wrote on graceful
      # `terminate/2`. mix-task BEAM exit doesn't reliably drain
      # `terminate/2` callbacks before halt → snapshot never lands.
      # The init-time write fixes this without changing the
      # `terminate/2` contract.
      assert %KindSnapshot{kind_type: "test"} = KindSnapshot.get(uri_str)
    end
  end

  describe "init does NOT write for ephemeral / external Kinds" do
    test ":ephemeral — no row after spawn (regression guard)" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_init-snap-eph-#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(uri)

      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({Ezagent.Test.TestKind, %{uri: uri}})

      # The init-time write MUST respect the policy. Writing a
      # snapshot for an `:ephemeral` Kind would be a regression —
      # operators chose `:ephemeral` precisely to avoid the DB cost.
      assert nil == KindSnapshot.get(uri_str)
    end
  end

  # Codex r1 HIGH (2026-05-25) — the bare init-time write is not
  # enough by itself: any provisioning-via-dispatch that follows the
  # spawn must ALSO land durably before the BEAM can exit. Before
  # Agent was bumped from `:on_terminate` to `{:snapshot, :on_change}`
  # the CLI flow `mix ezagent.agent.create … --caps …` would write
  # the empty initial slice at init, then NOT write the cap grant
  # (because `Snapshot.commit/4` returns `:not_durable` for
  # `:on_terminate`), then race terminate against BEAM halt.
  describe "post-spawn dispatch mutations are durable without relying on terminate/2" do
    test "Agent dispatch-time slice mutation persists immediately (no wait, no terminate)" do
      # Spawn a real Agent Kind directly under its supervisor (same
      # entry as `Ezagent.SpawnRegistry.spawn/1`).
      suffix = System.unique_integer([:positive])
      uri = Ezagent.URI.new!("entity://team-alpha/agent/test_cli-cap-persist-#{suffix}")
      uri_str = URI.to_string(uri)

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          EzagentDomainInstanceMessage.AgentSupervisor,
          {Ezagent.Kind.Server, {Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()}}}
        )

      # Init-time row exists with empty caps.
      assert %KindSnapshot{kind_type: "agent"} = row_init = KindSnapshot.get(uri_str)

      # Dispatch `identity.grant_cap` — the exact action that
      # `Ezagent.Workspace.grant_initial_caps/3` loops over from the
      # CLI `mix ezagent.agent.create --caps …` path.
      # Use a workspace-scoped cap (workspace_uri == agent's
      # workspace) so dispatch's `:grant_workspace_any_requires_admin`
      # guard isn't relevant to what we're testing here — we just
      # need a slice mutation to exercise the dispatch →
      # `commit_and_notify/3` → `Snapshot.commit/4` path.
      cap =
        Ezagent.Capability.cap(
          :agent,
          Ezagent.ActionSet.Session,
          :send,
          uri,
          Ezagent.URI.new!("workspace://team-alpha")
        )

      assert :ok =
               Ezagent.Identity.Grant.grant_cap(
                 uri,
                 cap,
                 {:admin, Ezagent.Entity.User.admin_uri()}
               )

      # The invariant: WITHOUT terminate, WITHOUT waiting, the row
      # is updated to reflect the mutation. Pre-fix (Agent =
      # :on_terminate), `Snapshot.commit/4` returns `:not_durable`
      # on this dispatch path and `updated_at` would equal the init
      # write's timestamp — the row would still hold the empty pre-
      # mutation state, and a fresh BEAM would not see the change.
      row_after = KindSnapshot.get(uri_str)
      assert row_after.updated_at != row_init.updated_at
    end
  end
end
