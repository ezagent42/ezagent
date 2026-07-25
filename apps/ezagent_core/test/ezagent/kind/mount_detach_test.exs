defmodule Ezagent.Kind.MountDetachTest do
  @moduledoc """
  RF-2 + RF-3 — runtime per-instance behavior MOUNT + DETACH on a LIVE Kind.

  RF-2 (`Ezagent.Kind.mount/2`): adding a recipe-loaded behavior to a running
  instance materializes its slice (create + activate + activated all run, not
  slice-init alone — codex HIGH-A), makes its action dispatch (RF-1 per-instance
  resolution), and survives cold restart (the `:kind_base` capture rehydrates
  it).

  RF-3 (`Ezagent.Kind.detach/2`): removing a behavior runs its `on_detach/2`
  teardown, clears its slice, stops its action dispatching, and rejects removing
  a behavior another remaining behavior still `@required_reads` (reverse
  closure).
  """
  use EzagentCore.DataCase, async: false
  @moduletag :umbrella_only

  alias Ezagent.Kind
  alias Ezagent.Kind.InstanceSetSupport.{SupersetSessionKind, UndeclaredProbe, DetachProbe}
  alias Ezagent.Invocation

  setup do
    Code.ensure_loaded!(SupersetSessionKind)
    Code.ensure_loaded!(UndeclaredProbe)
    Code.ensure_loaded!(DetachProbe)

    Ezagent.LifecycleCase.ensure_gate_supervisor!()
    :persistent_term.put({UndeclaredProbe, :probe_pid}, self())
    :persistent_term.put({DetachProbe, :probe_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({UndeclaredProbe, :probe_pid})
      :persistent_term.erase({DetachProbe, :probe_pid})
      sup = Ezagent.LifecycleCase.gate_supervisor()

      for {_, child_pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(child_pid) do
        _ = DynamicSupervisor.terminate_child(sup, child_pid)
      end
    end)

    :ok
  end

  defp base_set, do: [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

  defp uri(prefix),
    do: Ezagent.URI.session(:system, :default, :"#{prefix}-#{System.unique_integer([:positive])}")

  defp spawn_instance(uri, behaviors) do
    {:ok, _pid} = Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: behaviors})
    :ok
  end

  defp dispatch(uri, action_path, behavior, action) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=#{action_path}")
    presenter = Ezagent.Entity.User.admin_uri()
    cap = signed_fixture_cap!(uri, SupersetSessionKind.type_name(), behavior, action, presenter)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: presenter,
        authenticated_principal: presenter,
        caps: MapSet.new([cap]),
        reply: :ignore
      }
    })
  end

  # ---------------------------------------------------------------- RF-2 mount

  test "RF-2: mount makes an UNDECLARED behavior's action dispatch + slice non-empty" do
    uri = uri("md-mount")
    spawn_instance(uri, base_set())

    # Before mount: not in the set → unknown_action.
    assert {:error, {:unknown_action, :undeclared_poke}} =
             dispatch(uri, "undeclared_probe.undeclared_poke", UndeclaredProbe, :undeclared_poke)

    assert :ok = Kind.mount(uri, UndeclaredProbe)

    # After mount: the behavior is in the effective set + its slice materialized.
    assert UndeclaredProbe in Kind.BehaviorSet.effective_set(SupersetSessionKind, live_slice(uri))
    assert {:ok, slice} = Kind.get_slice(uri, :undeclared_probe)
    assert is_map(slice) and map_size(slice) > 0

    # And its action now dispatches (RF-1 per-instance resolution).
    dispatch(uri, "undeclared_probe.undeclared_poke", UndeclaredProbe, :undeclared_poke)
    assert_received {:undeclared_probe, :handled}
  end

  test "RF-2: mount runs create + activate(transients) + activated (NOT slice-init alone)" do
    uri = uri("md-hooks")
    spawn_instance(uri, base_set())

    assert :ok = Kind.mount(uri, DetachProbe)

    # create ran (persistent state built) AND activated ran live (the post-:ready
    # reachability hook) — slice-init alone would skip activated. activate built
    # the (empty) transients container via the post-init continuation.
    assert_received {:detach_probe, :create}
    assert_received {:detach_probe, :activated}

    assert {:ok, %{state: %{poked: false}, transients: %{}}} =
             Ezagent.Kind.SliceAccess.get_raw_slice(uri, :detach_probe)
  end

  test "RF-2: mount is idempotent (mounting a present behavior → :ok, no re-create)" do
    uri = uri("md-idem")
    spawn_instance(uri, base_set())

    assert :ok = Kind.mount(uri, DetachProbe)
    assert_received {:detach_probe, :create}

    # Second mount of the SAME behavior is a no-op — create does NOT run again.
    assert :ok = Kind.mount(uri, DetachProbe)
    refute_received {:detach_probe, :create}
  end

  test "RF-2: mounting a non-Behavior is rejected with zero residue" do
    uri = uri("md-bad")
    spawn_instance(uri, base_set())

    before = live_slice(uri)
    assert {:error, {:not_a_behavior, NotABehaviorModule}} = Kind.mount(uri, NotABehaviorModule)
    # Live slice unchanged.
    assert live_slice(uri) == before
  end

  test "RF-2: a mounted behavior SURVIVES cold restart (kind_base rehydrates it)" do
    uri = uri("md-cold")
    spawn_instance(uri, base_set())
    assert :ok = Kind.mount(uri, UndeclaredProbe)

    # Terminate the live process, then re-derive the set from the PERSISTED
    # snapshot exactly as Kind.Server.init would on a cold start.
    :ok = Kind.terminate(uri)
    wait_gone(uri)

    rehydrated = Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{uri: uri})

    assert UndeclaredProbe in Kind.BehaviorSet.effective_set(SupersetSessionKind, rehydrated)
    assert Map.has_key?(rehydrated, :undeclared_probe)

    # And re-spawn the SAME URI (a real cold start) → the mounted behavior's
    # action STILL dispatches, proving the rehydrated set is live, not just
    # present in the derived set.
    {:ok, _pid} = Kind.spawn(SupersetSessionKind, %{uri: uri})
    dispatch(uri, "undeclared_probe.undeclared_poke", UndeclaredProbe, :undeclared_poke)
    assert_received {:undeclared_probe, :handled}
  end

  # ---------------------------------------------------------------- RF-3 detach

  test "RF-3: detach stops the action dispatching + runs on_detach + clears the slice" do
    uri = uri("md-detach")
    spawn_instance(uri, base_set())
    assert :ok = Kind.mount(uri, DetachProbe)
    assert_received {:detach_probe, :create}

    # Sanity: dispatches while mounted.
    dispatch(uri, "detach_probe.detach_poke", DetachProbe, :detach_poke)
    assert_received {:detach_probe, :handle_detach_poke}

    assert :ok = Kind.detach(uri, DetachProbe)

    # on_detach (via the detached/2 developer hook) fired.
    assert_received {:detach_probe, :detached}

    # Slice cleared + behavior no longer in the effective set.
    refute DetachProbe in Kind.BehaviorSet.effective_set(SupersetSessionKind, live_slice(uri))
    assert {:ok, nil} = Ezagent.Kind.SliceAccess.get_raw_slice(uri, :detach_probe)

    # Action no longer dispatches.
    assert {:error, {:unknown_action, :detach_poke}} =
             dispatch(uri, "detach_probe.detach_poke", DetachProbe, :detach_poke)

    refute_received {:detach_probe, :handle_detach_poke}
  end

  test "RF-3: reverse-closure REJECTS detaching a behavior another behavior still requires" do
    uri = uri("md-revclosure")
    # Turn @required_reads :surface (owner Behavior.Surface). Spawn with both +
    # Turn so the live set is closed.
    closed = [
      Ezagent.ActionSet.Session,
      Ezagent.ActionSet.Surface,
      Ezagent.ActionSet.Turn,
      Ezagent.ActionSet.KindBase
    ]

    spawn_instance(uri, closed)

    before = live_slice(uri)

    # Detaching Surface would leave Turn requiring a missing :surface owner.
    assert {:error, {:still_required, Ezagent.ActionSet.Surface, _missing}} =
             Kind.detach(uri, Ezagent.ActionSet.Surface)

    # Zero residue — Surface still present.
    assert live_slice(uri) == before

    assert Ezagent.ActionSet.Surface in Kind.BehaviorSet.effective_set(
             SupersetSessionKind,
             before
           )
  end

  test "RF-3: detaching a base behavior (KindBase) is refused" do
    uri = uri("md-base")
    spawn_instance(uri, base_set())

    assert {:error, {:cannot_detach_base_behavior, Ezagent.ActionSet.KindBase}} =
             Kind.detach(uri, Ezagent.ActionSet.KindBase)
  end

  test "RF-3: detaching an absent behavior is a no-op" do
    uri = uri("md-absent")
    spawn_instance(uri, base_set())
    assert :ok = Kind.detach(uri, DetachProbe)
  end

  # ----------------------------------------------------------------- helpers

  defp live_slice(uri) do
    {:ok, pid} = Ezagent.KindRegistry.lookup(uri)
    :sys.get_state(pid).state
  end

  defp wait_gone(uri, tries \\ 100)
  defp wait_gone(_uri, 0), do: :ok

  defp wait_gone(uri, tries) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        Process.sleep(5)
        wait_gone(uri, tries - 1)

      _ ->
        :ok
    end
  end
end
