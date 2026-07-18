defmodule Ezagent.LifecycleFollowupTest do
  @moduledoc """
  Regression tests for the 6 codex-review defects in the Phase A
  Lifecycle FOUNDATION (F1-F6). Each test FAILS if its fix is reverted.

  - F1 — transients never leak into durable storage (SliceChange emission
    suppressed on transient-only change; Publisher ring strips transients).
  - F2 — mixed legacy/Lifecycle sibling reads resolve for BOTH shapes,
    regardless of conversion order (the Phase B coexistence invariant).
  - F3 — `ever_created` is written ATOMICALLY with the initial persist
    (single upsert), closing the create-re-run window.
  - F4 — the developer `destroy/2` hook actually runs (before durable
    state is cleared).
  - F5 — `deactivate/2` is `:ok`-only (a returned state is discarded).
  - F6 — `pre_handle/3` + `post_handle/4` run around the handler dispatch.

  ## Codex round-2 follow-ups (2026-05-29)

  - F1-remainder — `Ezagent.SnapshotStore.write/3` (the Phase 2+ durable-
    write seam) ALSO strips Lifecycle transients before serialization,
    matching every other durable-write path.
  - F2 (self-destroy) — `Ezagent.Lifecycle.destroy/2` rejects a self-call
    with `{:error, :cannot_self_destroy}` instead of half-completing
    (row deleted but process alive).
  """

  use Ezagent.LifecycleCase

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.ActionSet
  alias Ezagent.Kind.Snapshot
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.{Invocation, SnapshotStore}

  alias Ezagent.TestSupport.{
    LifecycleFixture,
    LifecycleFixtureKind,
    LifecycleDestroyFixture,
    LifecycleDestroyKind,
    LifecycleInterceptFixture,
    LifecycleInterceptKind,
    SelfDestroyFixture,
    SelfDestroyKind,
    SiblingReader,
    SiblingMixKind,
    LegacySibling,
    LifecycleSibling
  }

  setup_all do
    for m <- [
          LifecycleFixture,
          LifecycleFixtureKind,
          LifecycleDestroyFixture,
          LifecycleDestroyKind,
          LifecycleInterceptFixture,
          LifecycleInterceptKind,
          SelfDestroyFixture,
          SelfDestroyKind,
          SiblingReader,
          SiblingMixKind,
          LegacySibling,
          LifecycleSibling
        ] do
      Code.ensure_loaded!(m)
    end

    register = fn kind, action, behavior ->
      if Ezagent.BehaviorRegistry.lookup(kind, action) == :error do
        :ok = Ezagent.CapabilityRegistry.register(kind, action, behavior)
      end
    end

    register.(LifecycleDestroyKind, :touch, LifecycleDestroyFixture)
    register.(LifecycleInterceptKind, :run, LifecycleInterceptFixture)
    register.(LifecycleInterceptKind, :guarded, LifecycleInterceptFixture)
    register.(SelfDestroyKind, :boom, SelfDestroyFixture)
    register.(SiblingMixKind, :read, SiblingReader)

    :ok
  end

  defp uri(type),
    do: URI.new!("system://#{type}/inst-#{System.unique_integer([:positive])}")

  defp signed_ctx(uri, kind, behavior, action) do
    presenter = Ezagent.Entity.User.admin_uri()
    cap = signed_fixture_cap!(uri, kind.type_name(), behavior, action, presenter)

    %{
      caller: presenter,
      caps: MapSet.new([cap]),
      reply: {:caller_inbox, self()}
    }
  end

  # ===================================================================
  # F1 — transients never reach durable storage (two indirect paths)
  # ===================================================================

  describe "F1 — SliceChange is suppressed for a transient-only change" do
    test "persistable-diff building block: transient-only change is equal, state change differs" do
      old = %{state: %{counter: 1}, transients: %{hits: 0}}
      transient_only = %{state: %{counter: 1}, transients: %{hits: 9}}
      state_change = %{state: %{counter: 2}, transients: %{hits: 0}}

      # The SliceChange emission predicate compares transients-stripped
      # views (F1a); these are the building blocks it uses.
      assert Snapshot.strip_transients(%{k: old}) ==
               Snapshot.strip_transients(%{k: transient_only})

      refute Snapshot.strip_transients(%{k: old}) ==
               Snapshot.strip_transients(%{k: state_change})
    end

    test "end-to-end: a transient-only handler does not fire SliceChange" do
      alias Ezagent.TestSupport.{TransientOnlyFixture, TransientOnlyKind}
      Code.ensure_loaded!(TransientOnlyFixture)

      if Ezagent.BehaviorRegistry.lookup(TransientOnlyKind, :tick) == :error do
        :ok = Ezagent.CapabilityRegistry.register(TransientOnlyKind, :tick, TransientOnlyFixture)
      end

      u = uri("lifecycle_transient_only")
      {:ok, _pid} = Ezagent.Kind.spawn(TransientOnlyKind, %{uri: u})
      wait_until(fn -> Ezagent.ReadyGate.status(u) == :ready end)

      Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.SliceChange.topic(u))

      target = URI.new!("#{URI.to_string(u)}?action=lifecycle_transient_only.tick")

      {:ok, _} =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{},
          ctx: signed_ctx(u, TransientOnlyKind, TransientOnlyFixture, :tick)
        })

      # The transient hits counter advanced (slice key pinned to :transient_only)...
      # Raw read — T3's get_slice/2 normalizes to flat .state, hiding transients.
      {:ok, %{transients: tr}} = Ezagent.Kind.get_raw_slice(u, :transient_only)
      assert tr.hits == 1

      # ...but NO SliceChange broadcast fired (transients are not durable;
      # the persistable view was unchanged, so the emit was suppressed).
      refute_receive {:slice_changed, _}, 150
    end
  end

  # NOTE: F1b (Publisher ring strips Lifecycle transients) is tested in
  # `ezagent_domain_session` where `Ezagent.ActionSet.Publisher.SessionImpl`
  # lives — that module is OUTSIDE ezagent_core's dependency cone (P9), so
  # the Publisher-ring regression test cannot run here. See
  # `apps/ezagent_domain_session/test/ezagent/behavior/publisher/session_impl_test.exs`.

  # ===================================================================
  # F2 — mixed legacy / Lifecycle sibling reads (conversion-order safe)
  # ===================================================================

  describe "F2 — a Kind mixing a legacy + a Lifecycle sibling reads BOTH" do
    test "reads_siblings_of/1 unions the legacy and Lifecycle callbacks" do
      assert Enum.sort(ActionSet.reads_siblings_of(SiblingReader)) ==
               [:legacy_sibling, :lifecycle_sibling]

      assert ActionSet.reads_siblings_of(LegacySibling) == []
    end

    test "both ctx.sibling_slices and ctx.siblings expose flat fields for BOTH shapes" do
      u = uri("lifecycle_sibling_mix")
      {:ok, _pid} = Ezagent.Kind.spawn(SiblingMixKind, %{uri: u})
      wait_until(fn -> Ezagent.ReadyGate.status(u) == :ready end)

      target = URI.new!("#{URI.to_string(u)}?action=lifecycle_sibling_mix.read")

      {:ok, result} =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{},
          ctx: signed_ctx(u, SiblingMixKind, SiblingReader, :read)
        })

      # The legacy-flat sibling AND the Lifecycle two-container sibling
      # BOTH resolve to their flat `[:keys]["deepseek"]` value through
      # BOTH reader surfaces. Conversion order is irrelevant — this is
      # the Phase B coexistence invariant.
      assert result.via_sibling_slices == %{legacy: "legacy-key", lifecycle: "lifecycle-key"}
      assert result.via_siblings == %{legacy: "legacy-key", lifecycle: "lifecycle-key"}
    end
  end

  # ===================================================================
  # F3 — ever_created atomic with the initial persist
  # ===================================================================

  describe "F3 — ever_created is written atomically with the initial snapshot" do
    test "save_now(..., mark_ever_created: true) sets state AND marker in one upsert" do
      u = uri("lifecycle_fixture")
      uri_str = URI.to_string(u)

      refute KindSnapshot.ever_created?(uri_str)

      :ok =
        Snapshot.save_now(
          u,
          LifecycleFixtureKind,
          %{lifecycle_fixture: %{state: %{counter: 0}, transients: %{}}},
          mark_ever_created: true
        )

      # One write — both the row AND the marker are present. No separate
      # fire-and-forget mark step that a crash could skip.
      assert KindSnapshot.ever_created?(uri_str)
      row = KindSnapshot.get(uri_str)
      assert row.ever_created == true
      assert {:ok, %{lifecycle_fixture: %{state: %{counter: 0}}}} = KindSnapshot.decode_state(row)
    end

    test "spawning a Lifecycle Kind marks ever_created on the initial boot persist" do
      u = uri("lifecycle_fixture")
      uri_str = URI.to_string(u)

      {:ok, _pid} = Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: u, counter: 0, label: "f3"})
      wait_until(fn -> Ezagent.ReadyGate.status(u) == :ready end)

      assert KindSnapshot.ever_created?(uri_str)
    end

    test "an ordinary save_now (no opt) does NOT touch ever_created" do
      u = uri("lifecycle_fixture")
      uri_str = URI.to_string(u)

      :ok =
        Snapshot.save_now(u, LifecycleFixtureKind, %{
          lifecycle_fixture: %{state: %{counter: 1}, transients: %{}}
        })

      refute KindSnapshot.ever_created?(uri_str)
    end
  end

  # ===================================================================
  # F4 — developer destroy/2 hook runs before durable state is cleared
  # ===================================================================

  describe "F4 — destroy/2 hook is reachable" do
    test "Lifecycle.destroy/2 runs the author's destroy hook, THEN clears state + terminates" do
      probe = :ets.new(:f4_probe, [:public, :set])
      u = uri("lifecycle_destroy_fixture")
      uri_str = URI.to_string(u)

      {:ok, pid} =
        Ezagent.Kind.spawn(LifecycleDestroyKind, %{uri: u, label: "doomed", probe: probe})

      wait_until(fn -> Ezagent.ReadyGate.status(u) == :ready end)
      assert KindSnapshot.ever_created?(uri_str)

      :ok = Ezagent.Lifecycle.destroy(u, :user_requested)

      # 1. The developer destroy hook RAN, with access to its live state
      #    (it read :label = "doomed").
      assert [{:destroyed, :user_requested, "doomed"}] = :ets.lookup(probe, :destroyed)

      # 2. Durable state + marker cleared.
      assert is_nil(KindSnapshot.get(uri_str))
      refute KindSnapshot.ever_created?(uri_str)

      # 3. Process terminated.
      wait_until(fn -> Ezagent.KindRegistry.lookup(u) == :error end)
      refute Process.alive?(pid)
    end
  end

  # ===================================================================
  # F5 — deactivate/2 is :ok-only (returned state discarded)
  # ===================================================================

  describe "F5 — deactivate/2 cannot mutate persisted state" do
    test "the @callback type is :ok-only (no {:ok, state} arm)" do
      # The contract is documented + the runner discards the return.
      # Assert the runner returns :ok even if a module returned a state.
      ctx = %{self_uri: uri("x"), kind_module: LifecycleDestroyKind}

      assert :ok =
               Ezagent.Lifecycle.__run_deactivate__(
                 # a module whose deactivate returns {:ok, state} — discarded
                 __MODULE__.DeactivateReturnsState,
                 :shutdown,
                 %{state: %{a: 1}, transients: %{}},
                 ctx
               )
    end

    test "graceful stop fires deactivate but the snapshot state is unchanged by it" do
      probe = :ets.new(:f5_probe, [:public, :set])
      u = uri("lifecycle_destroy_fixture")
      uri_str = URI.to_string(u)

      {:ok, pid} =
        Ezagent.Kind.spawn(LifecycleDestroyKind, %{uri: u, label: "graceful", probe: probe})

      wait_until(fn -> Ezagent.ReadyGate.status(u) == :ready end)

      # Graceful stop → OTP terminate/3 → deactivate (entity persists).
      ref = Process.monitor(pid)
      :ok = GenServer.stop(pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      # deactivate ran (side effect recorded)...
      assert [{:deactivated, :shutdown}] = :ets.lookup(probe, :deactivated)

      # ...and durable state is intact (entity persists; deactivate did
      # not — and could not — mutate it).
      assert {:ok, decoded} = KindSnapshot.decode_state(KindSnapshot.get(uri_str))
      assert decoded.lifecycle_destroy_fixture.state.label == "graceful"
    end
  end

  # ===================================================================
  # F6 — pre_handle/3 + post_handle/4 run
  # ===================================================================

  describe "F6 — fine interception hooks run around the handler" do
    test "pre_handle rewrites args; post_handle injects an effect + rewrites the result" do
      u = uri("lifecycle_intercept_fixture")
      {:ok, _pid} = Ezagent.Kind.spawn(LifecycleInterceptKind, %{uri: u})
      wait_until(fn -> Ezagent.ReadyGate.status(u) == :ready end)

      target = URI.new!("#{URI.to_string(u)}?action=lifecycle_intercept_fixture.run")

      {:ok, result} =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{n: 3},
          ctx: signed_ctx(u, LifecycleInterceptKind, LifecycleInterceptFixture, :run)
        })

      # pre_handle doubled n (3 → 6) before the handler ran.
      assert result.n == 6
      # post_handle rewrote the result.
      assert result.post == true

      {:ok, %{state: state}} = Ezagent.Kind.get_raw_slice(u, :lifecycle_intercept_fixture)
      # handler's {:set, :seen, 6} landed (proves pre_handle arg rewrite)...
      assert state.seen == 6
      # ...AND post_handle's injected {:set, :post_marker, :ran} landed.
      assert state.post_marker == :ran
    end

    test "pre_handle {:halt, result} skips the handler entirely" do
      u = uri("lifecycle_intercept_fixture")
      {:ok, _pid} = Ezagent.Kind.spawn(LifecycleInterceptKind, %{uri: u})
      wait_until(fn -> Ezagent.ReadyGate.status(u) == :ready end)

      target = URI.new!("#{URI.to_string(u)}?action=lifecycle_intercept_fixture.guarded")

      {:ok, result} =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{},
          ctx: signed_ctx(u, LifecycleInterceptKind, LifecycleInterceptFixture, :guarded)
        })

      assert result == %{denied: true}

      # The handler never ran, so it never set :seen to :should_not_happen.
      {:ok, %{state: state}} = Ezagent.Kind.get_raw_slice(u, :lifecycle_intercept_fixture)
      refute state.seen == :should_not_happen
    end
  end

  # ===================================================================
  # F1-remainder — SnapshotStore.write/3 strips transients
  # ===================================================================

  describe "F1-remainder — SnapshotStore.write/3 strips Lifecycle transients" do
    test "a two-container write persists ONLY the :state view (transients gone on reload)" do
      u = uri("lifecycle_fixture")
      uri_str = URI.to_string(u)

      {:ok, %{version: _}} =
        SnapshotStore.write(
          u,
          %{lifecycle_fixture: %{state: %{x: 1}, transients: %{pid: self()}}},
          kind_type: :lifecycle_fixture
        )

      # Reload through the public read API: the transients sub-key is
      # ABSENT — a PID had no serialization path and was stripped at the
      # write boundary, exactly like save_now/3.
      assert {:ok, %{state: reloaded}} = SnapshotStore.latest(uri_str)
      assert reloaded == %{lifecycle_fixture: %{state: %{x: 1}}}
      refute Map.has_key?(reloaded.lifecycle_fixture, :transients)

      # And the raw row confirms it (no live PID smuggled into the BLOB).
      assert {:ok, decoded} = KindSnapshot.decode_state(KindSnapshot.get(uri_str))
      assert decoded == %{lifecycle_fixture: %{state: %{x: 1}}}
    end

    test "a legacy flat slice (no :transients key) round-trips unchanged" do
      u = uri("lifecycle_fixture")
      uri_str = URI.to_string(u)

      flat = %{some_slice: %{x: 1, y: "z"}}

      {:ok, %{version: _}} =
        SnapshotStore.write(u, flat, kind_type: :lifecycle_fixture)

      # No :transients sub-key anywhere → the strip is a structural no-op
      # and the state round-trips byte-for-byte.
      assert {:ok, %{state: ^flat}} = SnapshotStore.latest(uri_str)
    end
  end

  # ===================================================================
  # F2 (self-destroy) — destroy/2 rejects a self-call (never torn state)
  # ===================================================================

  describe "F2 — self-destroy from inside the target Kind is rejected, not half-completed" do
    test "a handler that calls destroy(self_uri) gets {:error, :cannot_self_destroy}; row + process intact" do
      probe = :ets.new(:self_destroy_probe, [:public, :set])
      u = uri("lifecycle_self_destroy_fixture")
      uri_str = URI.to_string(u)

      {:ok, pid} =
        Ezagent.Kind.spawn(SelfDestroyKind, %{uri: u, label: "doomed?", probe: probe})

      wait_until(fn -> Ezagent.ReadyGate.status(u) == :ready end)
      assert KindSnapshot.ever_created?(uri_str)

      target = URI.new!("#{uri_str}?action=lifecycle_self_destroy_fixture.boom")

      # The handler runs IN the Kind.Server process and calls
      # destroy(self_uri). The call must NOT deadlock (it would if the
      # guard were absent → the inner GenServer.call(self()) blocks until
      # the 5s timeout); it returns promptly with the rejection.
      {:ok, result} =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{},
          ctx: signed_ctx(u, SelfDestroyKind, SelfDestroyFixture, :boom)
        })

      # The handler observed the structural rejection.
      assert result.result == {:error, :cannot_self_destroy}
      assert [{:boom_result, {:error, :cannot_self_destroy}}] = :ets.lookup(probe, :boom_result)

      # INVARIANT: NEITHER torn state NOR honest destruction. The durable
      # row + marker are INTACT and the process is STILL ALIVE — the
      # self-destroy did not clear the row (which, with a live process,
      # is exactly the torn state F2 guards against) and did not kill it.
      assert Process.alive?(pid)
      assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(u)
      refute is_nil(KindSnapshot.get(uri_str))
      assert KindSnapshot.ever_created?(uri_str)
    end

    test "destroy/2 from an EXTERNAL process (not self) still destroys normally" do
      u = uri("lifecycle_self_destroy_fixture")
      uri_str = URI.to_string(u)

      {:ok, pid} = Ezagent.Kind.spawn(SelfDestroyKind, %{uri: u, label: "ext"})
      wait_until(fn -> Ezagent.ReadyGate.status(u) == :ready end)
      assert KindSnapshot.ever_created?(uri_str)

      # The test process is NOT the Kind.Server pid, so this is the
      # legitimate external-caller path — it fully destroys.
      refute self() == pid
      assert :ok = Ezagent.Lifecycle.destroy(u, :external_requested)

      assert is_nil(KindSnapshot.get(uri_str))
      refute KindSnapshot.ever_created?(uri_str)
      wait_until(fn -> Ezagent.KindRegistry.lookup(u) == :error end)
      refute Process.alive?(pid)
    end
  end

  describe "entity transition lock" do
    test "string, struct, and action variants share one lock while different URIs do not block" do
      instance = uri("lifecycle_fixture")
      action = Ezagent.URI.with_action(instance, :lifecycle_fixture, :touch)
      string = URI.to_string(instance)
      other = uri("lifecycle_fixture")
      parent = self()
      ref = make_ref()

      first =
        Task.async(fn ->
          Ezagent.Lifecycle.with_entity_transition(action, fn ->
            send(parent, {ref, :first_locked, self()})

            assert :nested ==
                     Ezagent.Lifecycle.with_entity_transition(instance, fn -> :nested end)

            assert :nested_string ==
                     Ezagent.Lifecycle.with_entity_transition(string, fn -> :nested_string end)

            receive do
              {^ref, :release} -> :first_done
            end
          end)
        end)

      assert_receive {^ref, :first_locked, first_pid}, 1_000

      assert transition_lock_available?(instance) == false

      unrelated =
        Task.async(fn ->
          Ezagent.Lifecycle.with_entity_transition(other, fn ->
            send(parent, {ref, :other_locked})
            :other_done
          end)
        end)

      assert_receive {^ref, :other_locked}, 1_000
      assert :other_done = Task.await(unrelated, 1_000)
      send(first_pid, {ref, :release})

      assert :first_done = Task.await(first, 1_000)
      assert transition_lock_available?(instance) == true
    end

    test "callback raise and exit release both the process marker and global lock" do
      instance = uri("lifecycle_fixture")

      assert_raise RuntimeError, "transition callback failed", fn ->
        Ezagent.Lifecycle.with_entity_transition(instance, fn ->
          raise "transition callback failed"
        end)
      end

      assert :after_raise ==
               Ezagent.Lifecycle.with_entity_transition(instance, fn -> :after_raise end)

      assert catch_exit(
               Ezagent.Lifecycle.with_entity_transition(instance, fn ->
                 exit(:transition_callback_exit)
               end)
             ) == :transition_callback_exit

      assert :after_exit ==
               Ezagent.Lifecycle.with_entity_transition(instance, fn -> :after_exit end)
    end
  end

  defp transition_lock_available?(uri) do
    stable_key = uri |> Ezagent.URI.instance() |> Ezagent.URI.stable_key()

    Task.async(fn ->
      lock_id = {{:ezagent_entity_transition, stable_key}, self()}

      if :global.set_lock(lock_id, [node()], 0) do
        :global.del_lock(lock_id, [node()])
        true
      else
        false
      end
    end)
    |> Task.await(1_000)
  end

  # A throwaway module whose deactivate returns {:ok, state} — used to
  # prove __run_deactivate__ DISCARDS it (F5).
  defmodule DeactivateReturnsState do
    def deactivate(_reason, _ctx), do: {:ok, %{mutated: true}}
  end
end
