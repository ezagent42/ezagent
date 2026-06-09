defmodule Ezagent.Kind.InstanceSetDenialTest do
  use ExUnit.Case, async: false

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
    Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)

    # codex HIGH finding 3: SupersetSessionKind.supervisor/0 returns the
    # dedicated test DynamicSupervisor `Ezagent.LifecycleCase.gate_supervisor()`.
    # It must be RUNNING before any `Ezagent.Kind.spawn(SupersetSessionKind, …)`.
    # `ensure_gate_supervisor!/0` is idempotent.
    Ezagent.LifecycleCase.ensure_gate_supervisor!()

    :persistent_term.put({ProbeBehavior, :probe_pid}, self())
    on_exit(fn -> :persistent_term.erase({ProbeBehavior, :probe_pid}) end)
    :ok
  end

  test "FIRST spawn: out-of-set behavior NEVER runs create/init_slice and NEVER creates its slice (E8, no prior snapshot)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-firstinit-#{System.unique_integer([:positive])}")

    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})

    refute Map.has_key?(fresh, :probe)
    refute_received {:probe, :init_slice}
    refute Map.has_key?(fresh, :surface)
    assert Map.has_key?(fresh, :chat)
    assert Map.has_key?(fresh, :kind_base)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(fresh[:kind_base]) == chat_only
  end

  test "reload prune: a slice for a now-out-of-set behavior is dropped on load (E6/E7 defense-in-depth)" do
    uri = Ezagent.URI.session(:system, :default, :"isd-init-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})

    refute Map.has_key?(reloaded, :probe)
    refute Map.has_key?(reloaded, :surface)
    assert Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :kind_base)
  end

  test "RELOAD derives the set from the PERSISTED :kind_base, NOT spawn args (E8 reload, codex CRITICAL finding 1)" do
    uri =
      Ezagent.URI.session(
        :system,
        :default,
        :"isd-reload-scope-#{System.unique_integer([:positive])}"
      )

    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
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
          Ezagent.Behavior.Chat,
          Ezagent.Behavior.Surface,
          ProbeBehavior,
          Ezagent.Behavior.KindBase
        ]
      })

    refute Map.has_key?(reloaded, :probe)
    refute Map.has_key?(reloaded, :surface)
    refute_received {:probe, :init_slice}
    assert Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :kind_base)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == chat_only

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

    chat_only = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]
    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: chat_only})
    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, fresh)

    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{
        behaviors: [Ezagent.Behavior.Turn]
      })

    assert Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :kind_base)
    refute Map.has_key?(reloaded, :turns)
    refute Map.has_key?(reloaded, :surface)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == chat_only
  end

  test "LEGACY (pre-P1) snapshot reload: :kind_base-less row keeps ALL declared slices; reload args do NOT prune; :kind_base seeded as legacy sentinel (codex CRITICAL)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-legacy-#{System.unique_integer([:positive])}")

    legacy_state = %{
      chat: %{state: %{members: %{}, last_message_id: nil}, transients: %{}},
      surface: %{state: %{versions: []}, transients: %{}}
    }

    :ok =
      Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, legacy_state,
        mark_ever_created: true
      )

    reloaded =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{
        behaviors: [Ezagent.Behavior.Chat]
      })

    assert Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :surface)

    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == nil

    declared = Ezagent.Kind.behaviors_of(SupersetSessionKind)
    effective = Ezagent.Kind.BehaviorSet.effective_set(SupersetSessionKind, reloaded)
    assert Enum.take(effective, length(declared)) == declared

    :ok = Ezagent.Kind.Snapshot.save_now(uri, SupersetSessionKind, reloaded)

    reloaded2 =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})

    assert Map.has_key?(reloaded2, :chat)
    assert Map.has_key?(reloaded2, :surface)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded2[:kind_base]) == nil
  end

  test "FIRST spawn with EXPLICIT empty list: NO declared behavior runs create/init_slice, ONLY base slices materialize (E8, codex CRITICAL)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-emptyinit-#{System.unique_integer([:positive])}")

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: []})

    refute Map.has_key?(fresh, :probe)
    refute Map.has_key?(fresh, :surface)
    refute Map.has_key?(fresh, :chat)
    refute_received {:probe, :init_slice}
    assert Map.has_key?(fresh, :kind_base)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(fresh[:kind_base]) == []
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
    refute Map.has_key?(reloaded, :chat)
    assert Map.has_key?(reloaded, :kind_base)
    assert Ezagent.Behavior.KindBase.behaviors_in_slice(reloaded[:kind_base]) == []

    assert Ezagent.Kind.BehaviorSet.effective_set(SupersetSessionKind, reloaded) ==
             Ezagent.Kind.BehaviorSet.base_behaviors()
  end

  test "FIRST spawn with an UNCLOSED set (Turn without Surface) FAILS LOUD and persists NO partial slice (P1.1, codex CRITICAL/HIGH)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-unclosed-#{System.unique_integer([:positive])}")

    uri_str = URI.to_string(uri)

    unclosed = [
      Ezagent.Behavior.Chat,
      Ezagent.Behavior.Turn,
      ProbeBehavior,
      Ezagent.Behavior.KindBase
    ]

    err =
      assert_raise Ezagent.Kind.BehaviorSet.UnclosedSetError, fn ->
        Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: unclosed})
      end

    assert err.missing == [{Ezagent.Behavior.Turn, :surface}]
    assert err.message =~ "Turn"
    assert err.message =~ "surface"

    refute_received {:probe, :init_slice}

    assert is_nil(EzagentCore.Repo.get(Ezagent.Ecto.KindSnapshot, uri_str))
  end

  test "FIRST spawn with an OPTIONAL read missing still SUCCEEDS (Chat without Sandbox → soft %{})" do
    uri =
      Ezagent.URI.session(:system, :default, :"isd-optclosed-#{System.unique_integer([:positive])}")

    set = [Ezagent.Behavior.Chat, Ezagent.Behavior.KindBase]

    fresh = Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: set})

    assert Map.has_key?(fresh, :chat)
    assert Map.has_key?(fresh, :kind_base)
  end
end
