defmodule Ezagent.LifecycleTest do
  @moduledoc """
  Phase A acceptance tests for `use Ezagent.Lifecycle` (SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`).

  Proves the macro emits a working `@behaviour Ezagent.ActionSet` under
  the two-container model, that transients are stripped at the snapshot
  boundary, that `{:set_transient, ...}` is reduced atomically alongside
  `{:set, ...}`, and — THE GATE — that transients are rebuilt (not
  restored) on a cold restart.
  """

  use Ezagent.LifecycleCase

  alias Ezagent.TestSupport.{LifecycleFixture, LifecycleFixtureKind, LifecycleFixtureOverride}
  alias Ezagent.ActionSet
  alias Ezagent.Kind.Snapshot
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Invocation

  setup_all do
    # Ensure the fixture modules are loaded (test env lazy-loads) so
    # `function_exported?`-based introspection sees the `use
    # Ezagent.ActionSet` marker, and register the fixture's actions in
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

  defp signed_bump_ctx(uri) do
    presenter = Ezagent.Entity.User.admin_uri()

    cap =
      signed_fixture_cap!(
        uri,
        LifecycleFixtureKind.type_name(),
        LifecycleFixture,
        :bump,
        presenter
      )

    %{
      caller: presenter,
      authenticated_principal: presenter,
      caps: MapSet.new([cap]),
      reply: {:caller_inbox, self()}
    }
  end

  describe "macro emission (compile-down to @behaviour Ezagent.ActionSet)" do
    test "emits a new-style ActionSet the engine recognises" do
      assert ActionSet.new_style?(LifecycleFixture)
      assert :bump in ActionSet.action_names(LifecycleFixture)
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

      assert {:ok, %{state: new_slice}} = ActionSet.apply_effects(effects, slice)
      assert new_slice == %{state: %{counter: 11}, transients: %{hits: 3}}
    end

    test ":set_transient against a flat (non-Lifecycle) slice raises (no shim)" do
      assert_raise ArgumentError, ~r/Lifecycle two-container slice/, fn ->
        ActionSet.apply_effects([{:set_transient, :x, 1}], %{flat: true})
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
        lifecycle_fixture: %{
          state: %{counter: 9, label: "persisted"},
          transients: %{worker: self()}
        }
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
    test "marker-store failure is fail-closed as not fresh" do
      previous = Application.get_env(:ezagent_core, Ezagent.Lifecycle, [])

      Application.put_env(
        :ezagent_core,
        Ezagent.Lifecycle,
        Keyword.put(
          previous,
          :marker_reader,
          Ezagent.TestSupport.RaisingLifecycleMarkerReader
        )
      )

      on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Lifecycle, previous) end)

      refute Ezagent.Lifecycle.fresh_create?(fixture_uri())
    end

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
      # Raw read — these tests inspect the two-container split (T3's
      # get_slice/2 normalizes to flat .state for production consumers).
      {:ok, %{state: state0, transients: tr0}} =
        Ezagent.Kind.SliceAccess.get_raw_slice(uri, :lifecycle_fixture)

      assert state0 == %{counter: 0, label: "fx"}
      assert is_pid(tr0.worker)
      assert tr0.hits == 0

      # Dispatch :bump — {:set, :counter} + {:set_transient, :hits}.
      target = URI.new!("#{URI.to_string(uri)}?action=lifecycle_fixture.bump")

      assert {:ok, %{counter: 2}} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: target,
                 mode: :call,
                 args: %{by: 2},
                 ctx: signed_bump_ctx(uri)
               })

      {:ok, %{state: state1, transients: tr1}} =
        Ezagent.Kind.SliceAccess.get_raw_slice(uri, :lifecycle_fixture)

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
                origin: :trusted_internal,
                target: target,
                mode: :call,
                args: %{by: 5},
                ctx: signed_bump_ctx(live_uri)
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

  # ===================================================================
  # T1 — handle_signal runs the FULL effect pipeline (not just :set /
  # :set_transient). A signal handler that returns :notify / :dispatch
  # effects actually executes them.
  # ===================================================================
  describe "T1 — handle_signal runs the full effect pipeline" do
    setup do
      Code.ensure_loaded!(Ezagent.TestSupport.LifecycleSignalFixture)
      Code.ensure_loaded!(Ezagent.TestSupport.LifecycleSignalKind)

      if Ezagent.BehaviorRegistry.lookup(
           Ezagent.TestSupport.LifecycleSignalKind,
           :noop
         ) == :error do
        :ok =
          Ezagent.CapabilityRegistry.register(
            Ezagent.TestSupport.LifecycleSignalKind,
            :noop,
            Ezagent.TestSupport.LifecycleSignalFixture
          )
      end

      :ok
    end

    defp signal_uri do
      URI.new!("system://lifecycle_signal_fixture/inst-#{System.unique_integer([:positive])}")
    end

    test "a :notify effect from handle_signal actually broadcasts + both containers advance" do
      uri = signal_uri()

      {:ok, pid} =
        Ezagent.Kind.spawn(Ezagent.TestSupport.LifecycleSignalKind, %{uri: uri})

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      topic = "lifecycle_signal_test:#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

      # Deliver the signal via the sealed transport — the engine's
      # handle_info(%Signal{}) routes it to handle_kind_message → __run_signal__.
      send(pid, %EzagentActor.Signal{kind: :signal, payload: {:lifecycle_signal_notify, topic}})

      # The :notify side-effect bucket must have executed (NOT just the
      # :set / :set_transient) — we receive the broadcast.
      assert_receive {:lifecycle_signal_fired, ^uri}, 1_000

      # Both containers advanced (R10-2 pre-commit): :set → state,
      # :set_transient → transients. Raw read to inspect both containers.
      {:ok, %{state: state, transients: transients}} =
        Ezagent.Kind.SliceAccess.get_raw_slice(uri, :lifecycle_signal)

      assert state.signaled == true
      assert transients.signal_hits == 1
    end

    test "a :dispatch effect from handle_signal re-enters the Router (cross-Kind)" do
      # Target Kind that receives the dispatched :bump.
      target = fixture_uri()

      {:ok, _} =
        Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: target, counter: 0, label: "tgt"})

      wait_until(fn -> Ezagent.ReadyGate.status(target) == :ready end)

      # Signal-emitting Kind.
      uri = signal_uri()
      {:ok, pid} = Ezagent.Kind.spawn(Ezagent.TestSupport.LifecycleSignalKind, %{uri: uri})
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      bump_cap =
        signed_fixture_cap!(
          target,
          LifecycleFixtureKind.type_name(),
          LifecycleFixture,
          :bump,
          uri
        )

      previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

      Application.put_env(
        :ezagent_core,
        Ezagent.Cap,
        Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
      )

      Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
        Ezagent.URI.stable_key(uri) => MapSet.new([bump_cap])
      })

      :persistent_term.put({Ezagent.TestSupport.LifecycleSignalFixture, :bump_cap}, bump_cap)

      on_exit(fn ->
        :persistent_term.erase({Ezagent.TestSupport.LifecycleSignalFixture, :bump_cap})
        Application.put_env(:ezagent_core, Ezagent.Cap, previous)
      end)

      send(pid, %EzagentActor.Signal{kind: :signal, payload: {:lifecycle_signal_dispatch, target}})

      # The :dispatch effect must have executed against the target Kind:
      # its counter is bumped by 7 (proving the signal path ran the
      # dispatch bucket, not just slice mutations).
      wait_until(fn ->
        case Ezagent.Kind.SliceAccess.get_raw_slice(target, :lifecycle_fixture) do
          {:ok, %{state: %{counter: 7}}} -> true
          _ -> false
        end
      end)

      {:ok, %{state: target_state}} =
        Ezagent.Kind.SliceAccess.get_raw_slice(target, :lifecycle_fixture)

      assert target_state.counter == 7

      # The signaling Kind's own :set landed too. get_slice/2 NORMALIZES a
      # two-container slice to flat .state for consumers (T3), so the field
      # is read at the top level here.
      {:ok, %{dispatched_to: dispatched_to}} =
        Ezagent.Kind.read(uri, :lifecycle_signal, spawn: :never)

      assert dispatched_to == target
    end
  end

  # ===================================================================
  # T3 — get_slice normalizes a two-container slice to its .state view.
  # ===================================================================
  describe "T3 — get_slice normalizes two-container → flat state" do
    test "get_slice returns the flat .state view for a two-container slice" do
      uri = fixture_uri()

      {:ok, _} =
        Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: uri, counter: 3, label: "norm"})

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # The fixture's slice is two-container. get_slice/2 NORMALIZES it to
      # the flat .state view a cross-module consumer expects — so
      # `flat.counter` resolves (NOT nil, which is what the raw
      # `%{state:, transients:}` map would give a flat-field reader).
      {:ok, flat} = Ezagent.Kind.read(uri, :lifecycle_fixture, spawn: :never)
      assert flat == %{counter: 3, label: "norm"}
      refute Map.has_key?(flat, :transients)

      # get_raw_slice/2 still exposes the unnormalized two-container split
      # for test infra / introspection.
      {:ok, raw} = Ezagent.Kind.SliceAccess.get_raw_slice(uri, :lifecycle_fixture)
      assert %{state: %{counter: 3, label: "norm"}, transients: _} = raw
    end

    test "normalize_slice_view flattens two-container; passes legacy flat unchanged" do
      two_container = %{state: %{owner_uri: :x, members: %{}}, transients: %{monitors: %{}}}
      assert Ezagent.Kind.normalize_slice_view(two_container) == %{owner_uri: :x, members: %{}}

      legacy_flat = %{owner_uri: :y, members: %{a: 1}}
      assert Ezagent.Kind.normalize_slice_view(legacy_flat) == legacy_flat

      # A map carrying :state but NO :transients is NOT two-container
      # (could be a legacy slice that happens to have a :state field) →
      # unchanged.
      ambiguous = %{state: :running, other: 1}
      assert Ezagent.Kind.normalize_slice_view(ambiguous) == ambiguous
    end

    test "normalize_slice_view flattens the PERSISTED single-key %{state} (transients stripped)" do
      # Snapshot persist strips :transients, so the on-disk slice is a
      # single-key `%{state: map}`. This MUST flatten — the regression that
      # broke orchestrator MCP registration (+ Feishu mirror #502) was this
      # exact case falling through unchanged.
      persisted = %{
        state: %{owner_uri: :z, template_working_copy: %{orchestrator_template_uri: :u}}
      }

      assert Ezagent.Kind.normalize_slice_view(persisted) ==
               %{owner_uri: :z, template_working_copy: %{orchestrator_template_uri: :u}}

      # Guard the false-match: a single-key %{state: <non-map>} is NOT a
      # persisted slice → unchanged (the `is_map(state)` guard).
      assert Ezagent.Kind.normalize_slice_view(%{state: :running}) == %{state: :running}

      # Guard the false-match: a multi-key map that happens to carry a
      # :state MAP among other keys is NOT a persisted slice → unchanged
      # (the `map_size == 1` guard).
      multi = %{state: %{a: 1}, other: 2}
      assert Ezagent.Kind.normalize_slice_view(multi) == multi
    end
  end

  # ===================================================================
  # T4 — load_with_fallback coerces a legacy FLAT snapshot row into the
  # two-container shape on read, so a pre-migration row boots a converted
  # Kind without crashing.
  # ===================================================================
  describe "T4 — legacy flat snapshot row coerced to two-container on load" do
    # Persist a PRE-MIGRATION snapshot: the fixture's slice in the OLD flat
    # shape (no :state / :transients split), with `ever_created` marked so
    # the boot path takes the cold-load branch (create SKIPPED — the most
    # dangerous case: fresh state is empty, only the flat loaded row
    # carries data). Mirrors a row written before the ActionSet converted
    # to `use Ezagent.Lifecycle`.
    defp persist_flat_legacy(uri_str, slice) do
      binary = :erlang.term_to_binary(%{lifecycle_fixture: slice})

      {:ok, _} =
        Ezagent.Ecto.KindSnapshot.upsert(
          uri_str,
          "lifecycle_fixture",
          binary,
          0,
          "workspace://system",
          mark_ever_created: true
        )
    end

    test "a flat legacy row loads into a converted Kind under :state without crashing" do
      uri = fixture_uri()
      persist_flat_legacy(URI.to_string(uri), %{counter: 42, label: "legacy-flat"})

      # Boot the (now two-container) Kind from that flat row. Without the
      # T4 coercion, init would crash: __run_activate__ matches %{state:
      # st} but the merged slice would be the flat map (the legacy row
      # shadowing fresh's two-container value).
      {:ok, _pid} = Ezagent.Kind.spawn(LifecycleFixtureKind, %{uri: uri})
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      {:ok, %{state: state, transients: transients}} =
        Ezagent.Kind.SliceAccess.get_raw_slice(uri, :lifecycle_fixture)

      # The legacy persistent data rehydrated UNDER :state.
      assert state == %{counter: 42, label: "legacy-flat"}
      # Transients were rebuilt fresh by activate/2 (not carried from the
      # flat row, which had none).
      assert is_pid(transients.worker)
      assert Process.alive?(transients.worker)
    end

    test "Snapshot.load_or_init coerces a flat slice for a two-container fresh peer" do
      uri = fixture_uri()
      persist_flat_legacy(URI.to_string(uri), %{counter: 9, label: "unit"})

      loaded = Ezagent.Kind.Snapshot.load_or_init(uri, LifecycleFixtureKind, %{uri: uri})

      # The slice came back in the two-container shape with the legacy data
      # under :state — NOT the raw flat map (which would crash activate).
      assert %{lifecycle_fixture: %{state: %{counter: 9, label: "unit"}, transients: %{}}} =
               loaded
    end
  end
end
