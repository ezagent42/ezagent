defmodule Ezagent.LifecycleTest do
  @moduledoc """
  Phase A acceptance tests for `use Ezagent.Lifecycle` (SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`).

  Proves the macro emits a working `@behaviour Ezagent.Behavior` under
  the two-container model, that transients are stripped at the snapshot
  boundary, that `{:set_transient, ...}` is reduced atomically alongside
  `{:set, ...}`, and — THE GATE — that transients are rebuilt (not
  restored) on a cold restart.
  """

  use Ezagent.LifecycleCase

  alias Ezagent.TestSupport.{LifecycleFixture, LifecycleFixtureKind, LifecycleFixtureOverride}
  alias Ezagent.Behavior
  alias Ezagent.Kind.Snapshot
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Invocation

  setup_all do
    # Ensure the fixture modules are loaded (test env lazy-loads) so
    # `function_exported?`-based introspection sees the `use
    # Ezagent.Behavior` marker, and register the fixture's actions in
    # the BehaviorRegistry so dispatch can resolve `:bump` (production
    # Kinds register at app boot via the plugin/registration hooks).
    Code.ensure_loaded!(LifecycleFixture)
    Code.ensure_loaded!(LifecycleFixtureKind)
    Code.ensure_loaded!(LifecycleFixtureOverride)

    # The fixture Kind is test-only and not registered at app boot.
    # Register its declared actions into the BehaviorRegistry so
    # dispatch can resolve `:bump`. Goes through the single canonical
    # chokepoint (`CapabilityRegistry.register/3`). Idempotent — the
    # registry upserts, so repeated runs are safe.
    if Ezagent.BehaviorRegistry.lookup(LifecycleFixtureKind, :bump) == :error do
      :ok =
        Ezagent.CapabilityRegistry.register(LifecycleFixtureKind, :bump, LifecycleFixture)
    end

    :ok
  end

  defp fixture_uri do
    URI.new!("system://lifecycle_fixture/inst-#{System.unique_integer([:positive])}")
  end

  describe "macro emission (compile-down to @behaviour Ezagent.Behavior)" do
    test "emits a new-style Behavior the engine recognises" do
      assert Behavior.new_style?(LifecycleFixture)
      assert :bump in Behavior.action_names(LifecycleFixture)
    end

    test "auto-derives state_slice/0 from the module name" do
      assert LifecycleFixture.state_slice() == :lifecycle_fixture
    end

    test "state_slice override hatch is honored (snapshot-compat)" do
      assert LifecycleFixtureOverride.state_slice() == :legacy_compat_key
    end

    test "init_slice/1 builds the two-container shape; create/1 fills state" do
      slice = LifecycleFixture.init_slice(%{counter: 7, label: "x"})
      assert %{state: %{counter: 7, label: "x"}, transients: %{}} = slice
    end

    test "post_init schedules the unified activate continuation" do
      assert LifecycleFixture.post_init(%{}, %{}) == {:continue, :ezagent_activate}
    end
  end

  describe "activate/2 rebuilds transients (every start)" do
    test "handle_continue(:ezagent_activate) fills :transients from state" do
      slice = %{state: %{counter: 3, label: "a"}, transients: %{}}
      ctx = %{self_uri: fixture_uri(), kind_module: LifecycleFixtureKind}

      assert {:ok, %{state: %{counter: 3}, transients: transients}} =
               LifecycleFixture.handle_continue(:ezagent_activate, slice, ctx)

      assert is_pid(transients.worker)
      assert Process.alive?(transients.worker)
      assert transients.hits == 0
    end
  end

  describe "handle action reduces {:set} + {:set_transient} into the two containers" do
    test "apply_effects routes :set→state and :set_transient→transients" do
      slice = %{state: %{counter: 10}, transients: %{hits: 2}}

      effects = [
        {:set, :counter, 11},
        {:set_transient, :hits, 3}
      ]

      assert {:ok, %{state: new_slice}} = Behavior.apply_effects(effects, slice)
      assert new_slice == %{state: %{counter: 11}, transients: %{hits: 3}}
    end

    test ":set_transient against a flat (non-Lifecycle) slice raises (no shim)" do
      assert_raise ArgumentError, ~r/Lifecycle two-container slice/, fn ->
        Behavior.apply_effects([{:set_transient, :x, 1}], %{flat: true})
      end
    end
  end

  describe "snapshot persistence boundary (only state, never transients)" do
    test "strip_transients/1 drops the :transients sub-key from every Lifecycle slice" do
      slice_state = %{
        lifecycle_fixture: %{state: %{counter: 5}, transients: %{worker: self()}},
        legacy_slice: %{some: :flat_value}
      }

      assert Snapshot.strip_transients(slice_state) == %{
               lifecycle_fixture: %{state: %{counter: 5}},
               legacy_slice: %{some: :flat_value}
             }
    end

    test "save_now persists ONLY the state sub-key (transients gone on disk)", %{} do
      uri = fixture_uri()
      uri_str = URI.to_string(uri)

      slice_state = %{
        lifecycle_fixture: %{state: %{counter: 9, label: "persisted"}, transients: %{worker: self()}}
      }

      :ok = Snapshot.save_now(uri, LifecycleFixtureKind, slice_state)

      row = KindSnapshot.get(uri_str)
      assert {:ok, decoded} = KindSnapshot.decode_state(row)
      assert decoded == %{lifecycle_fixture: %{state: %{counter: 9, label: "persisted"}}}
      refute Map.has_key?(decoded.lifecycle_fixture, :transients)
    end

    test "on_change commit treats a transient-only change as NOT durable" do
      uri = fixture_uri()
      old = %{lifecycle_fixture: %{state: %{counter: 1}, transients: %{hits: 0}}}
      transient_only = %{lifecycle_fixture: %{state: %{counter: 1}, transients: %{hits: 1}}}

      assert Snapshot.commit(uri, LifecycleFixtureKind, old, transient_only) == :not_durable
    end

    test "on_change commit treats a state change as durable" do
      uri = fixture_uri()
      old = %{lifecycle_fixture: %{state: %{counter: 1}, transients: %{hits: 0}}}
      state_change = %{lifecycle_fixture: %{state: %{counter: 2}, transients: %{hits: 0}}}

      assert Snapshot.commit(uri, LifecycleFixtureKind, old, state_change) == :ok
    end
  end

  describe "ever-created marker (§9 OQ-1)" do
    test "ever_created? is false before any persist, true after marking" do
      uri = fixture_uri()
      uri_str = URI.to_string(uri)

      refute KindSnapshot.ever_created?(uri_str)

      :ok =
        Snapshot.save_now(uri, LifecycleFixtureKind, %{
          lifecycle_fixture: %{state: %{counter: 0}}
        })

      refute KindSnapshot.ever_created?(uri_str)

      assert {:ok, _row} = KindSnapshot.mark_ever_created(uri_str)
      assert KindSnapshot.ever_created?(uri_str)
    end

    test "Lifecycle.destroy/1 clears the row + marker (respawn re-creates)" do
      uri = fixture_uri()
      uri_str = URI.to_string(uri)

      :ok =
        Snapshot.save_now(uri, LifecycleFixtureKind, %{lifecycle_fixture: %{state: %{counter: 0}}})

      {:ok, _} = KindSnapshot.mark_ever_created(uri_str)
      assert KindSnapshot.ever_created?(uri_str)

      :ok = Ezagent.Lifecycle.destroy(uri)

      refute KindSnapshot.ever_created?(uri_str)
      assert is_nil(KindSnapshot.get(uri_str))
    end
  end

  describe "live spawn → dispatch → cold restart (end to end)" do
    test "spawn runs create+activate; dispatch mutates both containers" do
      uri = fixture_uri()

      {:ok, _pid} =
        Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: uri, counter: 0, label: "fx"})

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # After boot: state from create, transients from activate.
      {:ok, %{state: state0, transients: tr0}} =
        Ezagent.Kind.get_slice(uri, :lifecycle_fixture)

      assert state0 == %{counter: 0, label: "fx"}
      assert is_pid(tr0.worker)
      assert tr0.hits == 0

      # Dispatch :bump — {:set, :counter} + {:set_transient, :hits}.
      target = URI.new!("#{URI.to_string(uri)}?action=lifecycle_fixture.bump")

      assert {:ok, %{counter: 2}} =
               Invocation.dispatch(%Invocation{
                 target: target,
                 mode: :call,
                 args: %{by: 2},
                 ctx: %{caller: :system, reply: {:caller_inbox, self()}}
               })

      {:ok, %{state: state1, transients: tr1}} =
        Ezagent.Kind.get_slice(uri, :lifecycle_fixture)

      assert state1.counter == 2
      assert tr1.hits == 1
      # the transient worker pid is unchanged by a dispatch (only stopped on restart)
      assert tr1.worker == tr0.worker
    end

    test "THE GATE — cold restart rehydrates state + REBUILDS transients" do
      uri = fixture_uri()

      result =
        assert_transients_rebuilt(
          %{
            kind: LifecycleFixtureKind,
            uri: uri,
            slice_key: :lifecycle_fixture,
            spawn_args: %{counter: 0, label: "gate"}
          },
          fn live_uri ->
            target = URI.new!("#{URI.to_string(live_uri)}?action=lifecycle_fixture.bump")

            {:ok, _} =
              Invocation.dispatch(%Invocation{
                target: target,
                mode: :call,
                args: %{by: 5},
                ctx: %{caller: :system, reply: {:caller_inbox, self()}}
              })
          end
        )

      # Persistent state survived (counter bumped to 5).
      assert result.after.state == %{counter: 5, label: "gate"}
      # Transient worker pid was REBUILT — a fresh live pid, different
      # from the killed incarnation's.
      assert is_pid(result.after.transients.worker)
      assert Process.alive?(result.after.transients.worker)
      refute result.after.transients.worker == result.before.transients.worker
    end
  end
end
