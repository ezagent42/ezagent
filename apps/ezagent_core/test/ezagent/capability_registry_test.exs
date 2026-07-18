defmodule Ezagent.CapabilityRegistryTest do
  @moduledoc """
  Unit tests for `Ezagent.CapabilityRegistry` — covers:

  - `register/3` happy path (dispatchable + cap-only)
  - Idempotent same-triple repeat
  - Conflict raise on different behavior for same `{kind, action}`
  - `action ∉ cap_subjects/0` raise (description discipline)
  - `register_default_grant/2` + `default_grants_for/2`
  - `list_grantable/0`, `subjects_for_kind/1`, `lookup_subject/2`
  - `needed_for/3` map shape + KeyError on unknown
  - **Per-Kind action subset preservation** (codex round-3 CRITICAL regression test):
    Chat-on-Session has different actions than Chat-on-User

  Uses real `Ezagent.Entity.User`, `Ezagent.Entity.Session`, etc. + a
  synthetic test Behavior (`MockBehavior`) for clean ETS state without
  fighting production registrations. Production data already in the
  registry is independent — the tests assert on EXACTLY what they
  register, not on counts.

  `async: false` because the ETS tables are global; per-test isolation
  via a unique test action atom per case.
  """

  use ExUnit.Case, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.{BehaviorRegistry, Capability, CapabilityRegistry}
  alias Ezagent.Entity.{Session, User}

  setup do
    for kind <- [Session, User],
        action <- [:mock_test_action_d, :mock_test_action_d2, :declared_action] do
      :ets.match_delete(Ezagent.CapabilityRegistry.Subjects.table(), {{kind, :_, action}, :_})
      :ets.delete(BehaviorRegistry.table(), {kind, action})
    end

    :ok
  end

  # Test fixture — a synthetic Behavior; cap-only by default for the
  # cap-only tests, override `dispatchable?/0` from the test cases that
  # need it dispatchable.
  defmodule MockDispatchableBehavior do
    @behaviour Ezagent.ActionSet

    def actions, do: [:mock_test_action_d, :mock_test_action_d2]

    def cap_subjects do
      [
        {:mock_test_action_d, "mock dispatchable test action 1"},
        {:mock_test_action_d2, "mock dispatchable test action 2"}
      ]
    end

    def state_slice, do: :mock_dispatchable
    def init_slice(_), do: %{}
    def invoke(_action, slice, _args, _ctx), do: {:ok, slice}
    def interface, do: %{}
    # No dispatchable?/0 → defaults to true via CapabilityRegistry's probe
  end

  defmodule MockCapOnlyBehavior do
    @behaviour Ezagent.ActionSet

    def actions, do: [:mock_test_action_co]
    def cap_subjects, do: [{:mock_test_action_co, "mock cap-only test action"}]
    def state_slice, do: :mock_cap_only
    def init_slice(_), do: %{}
    def invoke(_, _, _, _), do: raise("cap-only — not dispatchable")
    def interface, do: %{}
    def dispatchable?, do: false
  end

  defmodule MockBehaviorWithoutAction do
    @behaviour Ezagent.ActionSet

    def actions, do: [:declared_action]
    def cap_subjects, do: [{:declared_action, "declared in cap_subjects"}]
    def state_slice, do: :mock_no_action
    def init_slice(_), do: %{}
    def invoke(_, slice, _, _), do: {:ok, slice}
    def interface, do: %{}
  end

  describe "register/3 — dispatchable subject" do
    test "writes to BOTH subjects table AND BehaviorRegistry" do
      :ok = CapabilityRegistry.register(Session, :mock_test_action_d, MockDispatchableBehavior)

      assert {:ok, subject} =
               CapabilityRegistry.lookup_subject(Session, :mock_test_action_d)

      assert subject.kind == Session
      assert subject.behavior == MockDispatchableBehavior
      assert subject.action == :mock_test_action_d
      assert subject.dispatchable? == true
      assert subject.description == "mock dispatchable test action 1"

      assert {:ok, MockDispatchableBehavior} =
               BehaviorRegistry.lookup(Session, :mock_test_action_d)
    end
  end

  describe "register/3 — cap-only subject (dispatchable?: false)" do
    test "writes ONLY to subjects table; BehaviorRegistry untouched" do
      :ok =
        CapabilityRegistry.register(
          User,
          :mock_test_action_co,
          MockCapOnlyBehavior
        )

      assert {:ok, subject} = CapabilityRegistry.lookup_subject(User, :mock_test_action_co)
      assert subject.dispatchable? == false

      # CRITICAL: BehaviorRegistry must NOT see cap-only subjects
      # (cap-only Behaviors can never be accidentally dispatched).
      assert :error = BehaviorRegistry.lookup(User, :mock_test_action_co)
    end
  end

  describe "register/3 — idempotency + conflict" do
    test "subject-only repair is retained when later registration fails" do
      action = :mock_test_action_d
      :ok = CapabilityRegistry.unregister(Session, action, MockDispatchableBehavior)

      :ets.insert(
        Ezagent.CapabilityRegistry.Subjects.table(),
        {{Session, MockDispatchableBehavior, action},
         %{description: "mock dispatchable test action 1", dispatchable?: true}}
      )

      assert :existing_identical =
               CapabilityRegistry.register_owned(Session, action, MockDispatchableBehavior)

      :ok = BehaviorRegistry.register(Session, :mock_test_action_d2, MockBehaviorWithoutAction)

      assert {:error, _conflict} =
               CapabilityRegistry.register_owned(
                 Session,
                 :mock_test_action_d2,
                 MockDispatchableBehavior
               )

      assert {:ok, MockDispatchableBehavior} = BehaviorRegistry.lookup(Session, action)

      assert {:ok, %{behavior: MockDispatchableBehavior}} =
               CapabilityRegistry.lookup_subject(Session, action)
    end

    test "conflicting dispatch counterpart rejects without changing either row" do
      action = :mock_test_action_d
      :ok = CapabilityRegistry.unregister(Session, action, MockDispatchableBehavior)

      :ets.insert(
        Ezagent.CapabilityRegistry.Subjects.table(),
        {{Session, MockDispatchableBehavior, action},
         %{description: "mock dispatchable test action 1", dispatchable?: true}}
      )

      :ok = BehaviorRegistry.register(Session, action, MockBehaviorWithoutAction)

      assert {:error,
              {:behavior_registry_conflict, Session, ^action, MockBehaviorWithoutAction,
               MockDispatchableBehavior}} =
               CapabilityRegistry.register_owned(Session, action, MockDispatchableBehavior)

      assert {:ok, %{behavior: MockDispatchableBehavior}} =
               CapabilityRegistry.lookup_subject(Session, action)

      assert {:ok, MockBehaviorWithoutAction} = BehaviorRegistry.lookup(Session, action)
    end

    test "behavior-only repair is retained when later registration fails" do
      action = :mock_test_action_d
      :ok = CapabilityRegistry.unregister(Session, action, MockDispatchableBehavior)
      :ok = BehaviorRegistry.register(Session, action, MockDispatchableBehavior)

      assert :existing_identical =
               CapabilityRegistry.register_owned(Session, action, MockDispatchableBehavior)

      :ok = BehaviorRegistry.register(Session, :mock_test_action_d2, MockBehaviorWithoutAction)

      assert {:error, _conflict} =
               CapabilityRegistry.register_owned(
                 Session,
                 :mock_test_action_d2,
                 MockDispatchableBehavior
               )

      assert {:ok, %{behavior: MockDispatchableBehavior}} =
               CapabilityRegistry.lookup_subject(Session, action)

      assert {:ok, MockDispatchableBehavior} = BehaviorRegistry.lookup(Session, action)
    end

    test "unregister removes only an exact paired declaration" do
      action = :mock_test_action_d
      :ok = CapabilityRegistry.unregister(Session, action, MockDispatchableBehavior)
      :ok = CapabilityRegistry.register(Session, action, MockDispatchableBehavior)
      :ok = BehaviorRegistry.register(Session, action, MockBehaviorWithoutAction)

      assert :ok = CapabilityRegistry.unregister(Session, action, MockDispatchableBehavior)

      assert {:ok, %{behavior: MockDispatchableBehavior}} =
               CapabilityRegistry.lookup_subject(Session, action)

      assert {:ok, MockBehaviorWithoutAction} = BehaviorRegistry.lookup(Session, action)
    end

    test "register_owned atomically distinguishes acquired from identical ownership" do
      action = :mock_test_action_d2
      :ok = CapabilityRegistry.unregister(Session, action, MockDispatchableBehavior)

      assert :acquired =
               CapabilityRegistry.register_owned(Session, action, MockDispatchableBehavior)

      assert :existing_identical =
               CapabilityRegistry.register_owned(Session, action, MockDispatchableBehavior)

      assert {:ok, MockDispatchableBehavior} = BehaviorRegistry.lookup(Session, action)
    end

    test "same (kind, action, behavior) triple twice is idempotent (no raise)" do
      :ok = CapabilityRegistry.register(Session, :mock_test_action_d2, MockDispatchableBehavior)
      :ok = CapabilityRegistry.register(Session, :mock_test_action_d2, MockDispatchableBehavior)

      # Single subject row still
      subjects =
        CapabilityRegistry.subjects_for_kind(Session)
        |> Enum.filter(&(&1.action == :mock_test_action_d2))

      assert length(subjects) == 1
    end

    test "different behavior for same (kind, action) RAISES (conflict)" do
      # Both behaviors declare :declared_action, so we trip the conflict
      # path (not the action-not-declared path).
      defmodule SecondBehaviorWithSameAction do
        @behaviour Ezagent.ActionSet
        def actions, do: [:declared_action]
        def cap_subjects, do: [{:declared_action, "alt description"}]
        def state_slice, do: :second_mock
        def init_slice(_), do: %{}
        def invoke(_, slice, _, _), do: {:ok, slice}
        def interface, do: %{}
      end

      :ok = CapabilityRegistry.register(User, :declared_action, MockBehaviorWithoutAction)

      assert_raise RuntimeError, ~r/Capability subject conflict/, fn ->
        CapabilityRegistry.register(User, :declared_action, SecondBehaviorWithSameAction)
      end
    end

    test "action NOT in cap_subjects/0 RAISES (description discipline)" do
      assert_raise RuntimeError, ~r/does not declare action/, fn ->
        CapabilityRegistry.register(Session, :unknown_undeclared_action, MockDispatchableBehavior)
      end
    end
  end

  describe "default grants" do
    defp grant_fn_two_caps(workspace_uri) do
      [
        %Capability{
          kind: :session,
          behavior: :any,
          instance: :any,
          workspace_uri: workspace_uri,
          granted_by: Ezagent.URI.new!("entity://team-alpha/user/system"),
          granted_at: ~U[2026-01-01 00:00:00Z]
        },
        %Capability{
          kind: :workspace,
          behavior: :any,
          instance: :any,
          workspace_uri: workspace_uri,
          granted_by: Ezagent.URI.new!("entity://team-alpha/user/system"),
          granted_at: ~U[2026-01-01 00:00:00Z]
        }
      ]
    end

    defmodule MockGrantedKind do
      def type_name, do: :mock_granted_kind
    end

    test "register_default_grant + default_grants_for returns the fn result" do
      :ok = CapabilityRegistry.register_default_grant(MockGrantedKind, &grant_fn_two_caps/1)

      ws = Ezagent.URI.new!("workspace://test-ws-default-grant")
      caps = CapabilityRegistry.default_grants_for(MockGrantedKind, ws)

      assert length(caps) == 2
      assert Enum.all?(caps, &(&1.workspace_uri == ws))
    end

    test "default_grants_for unknown kind returns []" do
      defmodule UnknownKind, do: nil

      assert [] =
               CapabilityRegistry.default_grants_for(
                 UnknownKind,
                 Ezagent.URI.new!("workspace://x")
               )
    end
  end

  describe "needed_for/3" do
    test "returns 4-field map for registered subject" do
      :ok = CapabilityRegistry.register(Session, :mock_test_action_d, MockDispatchableBehavior)

      target = Ezagent.URI.new!("session://team-alpha/default/test-needed-for")
      needed = CapabilityRegistry.needed_for(Session, :mock_test_action_d, target)

      assert needed.kind == Session.type_name()
      assert needed.behavior == MockDispatchableBehavior
      assert %URI{} = needed.instance
      # Compare URI string form — URI.parse vs URI.new! produce
      # equivalent shape but Erlang struct field order may differ.
      assert URI.to_string(needed.workspace_uri) == "workspace://team-alpha"
    end

    test "raises KeyError on unregistered (kind, action)" do
      target = Ezagent.URI.new!("entity://team-alpha/user/x")

      assert_raise KeyError, ~r/no cap subject registered/, fn ->
        CapabilityRegistry.needed_for(User, :totally_unregistered_xyz, target)
      end
    end
  end

  describe "list_grantable/0 + subjects_for_kind/1" do
    test "list_grantable returns sorted entries" do
      :ok = CapabilityRegistry.register(Session, :mock_test_action_d, MockDispatchableBehavior)
      :ok = CapabilityRegistry.register(Session, :mock_test_action_d2, MockDispatchableBehavior)

      all = CapabilityRegistry.list_grantable()
      assert is_list(all)
      assert length(all) >= 2

      # Sorted by {kind, behavior, action}
      sorted = Enum.sort_by(all, &{&1.kind, &1.behavior, &1.action})
      assert sorted == all
    end

    test "subjects_for_kind filters correctly" do
      :ok = CapabilityRegistry.register(Session, :mock_test_action_d, MockDispatchableBehavior)
      session_subjects = CapabilityRegistry.subjects_for_kind(Session)

      assert Enum.all?(session_subjects, &(&1.kind == Session))
    end
  end

  describe "per-Kind action subset preservation (codex round-3 CRITICAL regression)" do
    # The original SPEC rev 3 tried `register_against_kind(K, B)` which
    # would force every action from B.cap_subjects/0 onto K — wrong because
    # Chat is bound to Session with 5 actions but to User/Agent with only
    # :receive. Rev 4 keeps per-action arg so subsets are preserved.

    defmodule MockMultiActionBehavior do
      @behaviour Ezagent.ActionSet

      def actions, do: [:full_action_a, :full_action_b, :full_action_c]

      def cap_subjects do
        [
          {:full_action_a, "action a"},
          {:full_action_b, "action b"},
          {:full_action_c, "action c"}
        ]
      end

      def state_slice, do: :mock_multi
      def init_slice(_), do: %{}
      def invoke(_, slice, _, _), do: {:ok, slice}
      def interface, do: %{}
    end

    defmodule MockKindForSubset1 do
      def type_name, do: :mock_kind_subset_1
    end

    defmodule MockKindForSubset2 do
      def type_name, do: :mock_kind_subset_2
    end

    test "different Kinds can register different subsets of a Behavior's actions" do
      # Kind 1 gets only :full_action_a
      :ok =
        CapabilityRegistry.register(MockKindForSubset1, :full_action_a, MockMultiActionBehavior)

      # Kind 2 gets only :full_action_b + :full_action_c
      :ok =
        CapabilityRegistry.register(MockKindForSubset2, :full_action_b, MockMultiActionBehavior)

      :ok =
        CapabilityRegistry.register(MockKindForSubset2, :full_action_c, MockMultiActionBehavior)

      subjects_k1 = CapabilityRegistry.subjects_for_kind(MockKindForSubset1)
      subjects_k2 = CapabilityRegistry.subjects_for_kind(MockKindForSubset2)

      k1_actions = Enum.map(subjects_k1, & &1.action) |> Enum.sort()
      k2_actions = Enum.map(subjects_k2, & &1.action) |> Enum.sort()

      assert k1_actions == [:full_action_a]
      assert k2_actions == [:full_action_b, :full_action_c]

      # And BehaviorRegistry sees the matching per-Kind subsets
      assert {:ok, MockMultiActionBehavior} =
               BehaviorRegistry.lookup(MockKindForSubset1, :full_action_a)

      assert :error = BehaviorRegistry.lookup(MockKindForSubset1, :full_action_b)

      assert {:ok, MockMultiActionBehavior} =
               BehaviorRegistry.lookup(MockKindForSubset2, :full_action_b)

      assert :error = BehaviorRegistry.lookup(MockKindForSubset2, :full_action_a)
    end
  end
end
