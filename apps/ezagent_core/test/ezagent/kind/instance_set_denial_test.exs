defmodule Ezagent.Kind.InstanceSetDenialTest do
  # #92: was `use ExUnit.Case` + a hand-rolled `checkout` + `{:shared, self()}`,
  # which made the dying test process the global shared owner and clobbered
  # concurrent suites on exit. DataCase shares via a drainable Agent owner +
  # drain teardown; the per-test `on_exit` below additionally drains this
  # suite's gate-supervisor Kinds.
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Kind.InstanceSetSupport.{SupersetSessionKind, ProbeBehavior}

  # Module-level setup_all — registers the test-only Kind's dispatch entry
  # through the canonical chokepoint exactly as production does at app boot.
  setup_all do
    Code.ensure_loaded!(SupersetSessionKind)
    Code.ensure_loaded!(ProbeBehavior)

    # SupersetSessionKind is test-only and not registered at app boot.
    # Register {SupersetSessionKind, :poke} → ProbeBehavior via the SINGLE
    # canonical entry (CapabilityRegistry.register/3), which reads
    # ProbeBehavior.cap_subjects/0 and inserts into BOTH the subjects table
    # AND BehaviorRegistry (ProbeBehavior is dispatchable). Idempotent —
    # guarded so repeated runs don't conflict.
    if Ezagent.BehaviorRegistry.lookup(SupersetSessionKind, :poke) == :error do
      :ok = Ezagent.CapabilityRegistry.register(SupersetSessionKind, :poke, ProbeBehavior)
    end

    # Sanity: the canonical registration actually wired the dispatch lookup.
    {:ok, ProbeBehavior} = Ezagent.BehaviorRegistry.lookup(SupersetSessionKind, :poke)
    :ok
  end

  setup do
    # Spawn-based tests (E9/E4/E5/E3/E2) start the Kind GenServer in the gate
    # DynamicSupervisor — a SEPARATE process that touches the snapshot DB. The
    # DataCase shared (drainable) owner lets that process use the sandbox
    # connection without globalizing it onto the dying test pid (#92).

    # codex HIGH finding 3: SupersetSessionKind.supervisor/0 returns the
    # dedicated test DynamicSupervisor `Ezagent.LifecycleCase.gate_supervisor()`.
    # It must be RUNNING before any `Ezagent.Kind.spawn(SupersetSessionKind, …)`.
    # `ensure_gate_supervisor!/0` is idempotent.
    Ezagent.LifecycleCase.ensure_gate_supervisor!()

    :persistent_term.put({ProbeBehavior, :probe_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({ProbeBehavior, :probe_pid})

      # Drain any Kind GenServers this test spawned into the gate supervisor so
      # they don't touch the snapshot DB after the sandbox connection is
      # reclaimed (best-effort; mirrors the cold-restart suites' isolation).
      sup = Ezagent.LifecycleCase.gate_supervisor()

      for {_, child_pid, _, _} <- DynamicSupervisor.which_children(sup),
          is_pid(child_pid) do
        _ = DynamicSupervisor.terminate_child(sup, child_pid)
      end
    end)

    :ok
  end

  test "FIRST spawn: out-of-set behavior NEVER runs create/init_slice and NEVER creates its slice (E8, no prior snapshot)" do
    uri =
      Ezagent.URI.session(
        :system,
        :default,
        :"isd-firstinit-#{System.unique_integer([:positive])}"
      )

    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})

    refute Map.has_key?(fresh, :probe)
    refute_received {:probe, :init_slice}
    refute Map.has_key?(fresh, :surface)
    assert Map.has_key?(fresh, :session)
    assert Map.has_key?(fresh, :kind_base)
    assert Ezagent.ActionSet.KindBase.behaviors_in_slice(fresh[:kind_base]) == chat_only
  end

  test "reload prune: a slice for a now-out-of-set behavior is dropped on load (E6/E7 defense-in-depth)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-init-#{System.unique_integer([:positive])}")

    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})

    refute Map.has_key?(reloaded, :probe)
    refute Map.has_key?(reloaded, :surface)
    assert Map.has_key?(reloaded, :session)
    assert Map.has_key?(reloaded, :kind_base)
  end

  test "RELOAD derives the set from the PERSISTED :kind_base, NOT spawn args (E8 reload, codex CRITICAL finding 1)" do
    uri =
      Ezagent.URI.session(
        :system,
        :default,
        :"isd-reload-scope-#{System.unique_integer([:positive])}"
      )

    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    receive do
      {:probe, _} -> :ok
    after
      0 -> :ok
    end

    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{
        behaviors: [
          Ezagent.ActionSet.Session,
          Ezagent.ActionSet.Surface,
          ProbeBehavior,
          Ezagent.ActionSet.KindBase
        ]
      })

    refute Map.has_key?(reloaded, :probe)
    refute Map.has_key?(reloaded, :surface)
    refute_received {:probe, :init_slice}
    assert Map.has_key?(reloaded, :session)
    assert Map.has_key?(reloaded, :kind_base)
    assert Ezagent.ActionSet.KindBase.behaviors_in_slice(reloaded[:kind_base]) == chat_only

    assert Ezagent.Kind.BehaviorSet.effective_set(SupersetSessionKind, reloaded) ==
             Enum.uniq(chat_only ++ Ezagent.Kind.BehaviorSet.base_behaviors())
  end

  test "RELOAD with BOGUS/unclosed spawn args does NOT crash a VALID persisted instance (E8 reload, codex CRITICAL finding 1)" do
    uri =
      Ezagent.URI.session(
        :system,
        :default,
        :"isd-reload-bogus-#{System.unique_integer([:positive])}"
      )

    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{
        behaviors: [Ezagent.ActionSet.Turn]
      })

    assert Map.has_key?(reloaded, :session)
    assert Map.has_key?(reloaded, :kind_base)
    refute Map.has_key?(reloaded, :turns)
    refute Map.has_key?(reloaded, :surface)
    assert Ezagent.ActionSet.KindBase.behaviors_in_slice(reloaded[:kind_base]) == chat_only
  end

  test "LEGACY (pre-P1) snapshot reload: :kind_base-less row keeps ALL declared slices; reload args do NOT prune; :kind_base seeded as legacy sentinel (codex CRITICAL)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-legacy-#{System.unique_integer([:positive])}")

    legacy_state = %{
      session: %{state: %{members: %{}, last_message_id: nil}, transients: %{}},
      surface: %{state: %{versions: []}, transients: %{}}
    }

    :ok =
      Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, legacy_state,
        mark_ever_created: true
      )

    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{
        behaviors: [Ezagent.ActionSet.Session]
      })

    assert Map.has_key?(reloaded, :session)
    assert Map.has_key?(reloaded, :surface)

    assert Ezagent.ActionSet.KindBase.behaviors_in_slice(reloaded[:kind_base]) == nil

    declared = Ezagent.Kind.behaviors_of(SupersetSessionKind)
    effective = Ezagent.Kind.BehaviorSet.effective_set(SupersetSessionKind, reloaded)
    assert Enum.take(effective, length(declared)) == declared

    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, reloaded)

    reloaded2 =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})

    assert Map.has_key?(reloaded2, :session)
    assert Map.has_key?(reloaded2, :surface)
    assert Ezagent.ActionSet.KindBase.behaviors_in_slice(reloaded2[:kind_base]) == nil
  end

  test "FIRST spawn with EXPLICIT empty list: NO declared behavior runs create/init_slice, ONLY base slices materialize (E8, codex CRITICAL)" do
    uri =
      Ezagent.URI.session(
        :system,
        :default,
        :"isd-emptyinit-#{System.unique_integer([:positive])}"
      )

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})

    refute Map.has_key?(fresh, :probe)
    refute Map.has_key?(fresh, :surface)
    refute Map.has_key?(fresh, :session)
    refute_received {:probe, :init_slice}
    assert Map.has_key?(fresh, :kind_base)
    assert Ezagent.ActionSet.KindBase.behaviors_in_slice(fresh[:kind_base]) == []
  end

  test "RELOAD with EXPLICIT empty list: the captured [] is read back as base-only, NOT re-expanded to declared (E8 reload, codex CRITICAL)" do
    uri =
      Ezagent.URI.session(
        :system,
        :default,
        :"isd-emptyreload-#{System.unique_integer([:positive])}"
      )

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    reloaded = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})

    refute Map.has_key?(reloaded, :probe)
    refute Map.has_key?(reloaded, :surface)
    refute Map.has_key?(reloaded, :session)
    assert Map.has_key?(reloaded, :kind_base)
    assert Ezagent.ActionSet.KindBase.behaviors_in_slice(reloaded[:kind_base]) == []

    assert Ezagent.Kind.BehaviorSet.effective_set(SupersetSessionKind, reloaded) ==
             Ezagent.Kind.BehaviorSet.base_behaviors()
  end

  test "FIRST spawn with an UNCLOSED set (Turn without Surface) FAILS LOUD and persists NO partial slice (P1.1, codex CRITICAL/HIGH)" do
    uri =
      Ezagent.URI.session(
        :system,
        :default,
        :"isd-unclosed-#{System.unique_integer([:positive])}"
      )

    uri_str = URI.to_string(uri)

    unclosed = [
      Ezagent.ActionSet.Session,
      Ezagent.ActionSet.Turn,
      ProbeBehavior,
      Ezagent.ActionSet.KindBase
    ]

    err =
      assert_raise Ezagent.Kind.BehaviorSet.UnclosedSetError, fn ->
        Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: unclosed})
      end

    assert err.missing == [{Ezagent.ActionSet.Turn, :surface}]
    assert err.message =~ "Turn"
    assert err.message =~ "surface"

    refute_received {:probe, :init_slice}

    assert is_nil(EzagentCore.Repo.get(Ezagent.Ecto.KindSnapshot, uri_str))
  end

  test "FIRST spawn with an OPTIONAL read missing still SUCCEEDS (Chat without Sandbox → soft %{})" do
    uri =
      Ezagent.URI.session(
        :system,
        :default,
        :"isd-optclosed-#{System.unique_integer([:positive])}"
      )

    set = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: set})

    assert Map.has_key?(fresh, :session)
    assert Map.has_key?(fresh, :kind_base)
  end

  # === Task 10 (E9): dispatch + caps gate through the instance set ===

  # STEP (a) — BEFORE relying on the gate: prove the registry wiring is REAL by
  # dispatching :poke on an instance whose set INCLUDES ProbeBehavior; it must
  # REACH the handler. Guards against a false-green denial test that would
  # "pass" only because :poke was never registered (codex MEDIUM finding 2).
  test "dispatch wiring is real: :poke REACHES the handler on a full-set instance (E9 control)" do
    uri =
      Ezagent.URI.session(
        :system,
        :default,
        :"isd-probe-ok-#{System.unique_integer([:positive])}"
      )

    full = [Ezagent.ActionSet.Session, ProbeBehavior, Ezagent.ActionSet.KindBase]

    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: full})

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=probe.poke")

    cap =
      signed_fixture_cap!(
        uri,
        SupersetSessionKind.type_name(),
        ProbeBehavior,
        :poke,
        Ezagent.Entity.User.admin_uri()
      )

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        authenticated_principal: Ezagent.Entity.User.admin_uri(),
        caps: MapSet.new([cap]),
        reply: :ignore
      }
    })

    assert_received {:probe, :handle_poke}
  end

  # STEP (b) — the actual gate: same registered :poke, but on a chat-only
  # instance (ProbeBehavior NOT in the set, and NOT universal) → DENIED.
  test "dispatch: a NON-universal out-of-set behavior action is DENIED (E9)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-disp-#{System.unique_integer([:positive])}")

    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=probe.poke")

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: Ezagent.Entity.User.admin_uri(),
          caps: signed_caps(uri, ProbeBehavior, :poke),
          reply: :ignore
        }
      })

    assert {:error, :behavior_not_in_instance_set} = result
    refute_received {:probe, :handle_poke}
  end

  test "dispatch: the UNIVERSAL Manage behavior still dispatches on a subset instance (E9 exemption)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-mng-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=manage.delete")

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: Ezagent.Entity.User.admin_uri(),
          caps: signed_caps(uri, Ezagent.ActionSet.Manage, :delete),
          reply: :ignore
        }
      })

    # The exact success/error shape is owned by Manage + authz; the ONLY thing
    # this test asserts is that the instance-set gate did NOT short-circuit it.
    refute match?({:error, :behavior_not_in_instance_set}, result)
  end

  defp signed_caps(uri, behavior, action) do
    cap =
      signed_fixture_cap!(
        uri,
        SupersetSessionKind.type_name(),
        behavior,
        action,
        Ezagent.Entity.User.admin_uri()
      )

    MapSet.new([cap])
  end

  # === Task 11 (E4): mailbox handle_signal path through the instance set ===

  test "signal: an out-of-set behavior does NOT run handle_signal/handle_kind_message (E4)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-sig-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

    {:ok, pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})

    send(pid, %EzagentActor.Signal{kind: :signal, payload: {:some_signal, :payload}})
    _ = :sys.get_state(pid)

    refute_received {:probe, :handle_signal}
  end

  # === Task 12 (E5 + E3): terminate + lifecycle-destroy through the instance set ===

  test "terminate: an out-of-set behavior does NOT run its terminate hook (E5)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-term-#{System.unique_integer([:positive])}")

    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

    {:ok, pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    refute_received {:probe, :terminate}
  end

  test "destroy: an out-of-set behavior does NOT run its destroy hook (E3)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-dstr-#{System.unique_integer([:positive])}")

    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

    {:ok, pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})
    :ok = GenServer.call(pid, {:ezagent_lifecycle_destroy, :test})

    refute_received {:probe, :destroy}
  end

  # === Task 13 (E1 + E2): post_init, on_ready through the instance set ===

  test "on_ready: an out-of-set behavior does NOT run on_ready (E2)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-ready-#{System.unique_integer([:positive])}")

    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]

    {:ok, pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})
    _ = :sys.get_state(pid)

    refute_received {:probe, :on_ready}
    # init_slice ran for in-set behaviors only — ProbeBehavior must not have init'd.
    refute_received {:probe, :init_slice}
  end
end
