defmodule Ezagent.Kind.RuntimeNewContractDispatchTest do
  @moduledoc """
  Phase 1.5 wire-up — `Ezagent.Kind.Runtime.handle_dispatch/4` must
  detect new-contract Behaviors (via `__behavior__?/0` injected by
  `use Ezagent.Behavior`) and dispatch through the
  `handle_<action>/2` + `apply_effects/2` pipeline instead of the
  legacy `invoke/4` shim.

  These tests verify the dispatcher branches cleanly between the two
  contracts within ONE Kind, and that the new-contract path:

  1. Calls `handle_<action>(args, ctx)` with `ctx[:read]` exposing the
     slice as a `(key, default)` getter.
  2. Applies returned effects in declared order via `apply_effects/2`.
  3. Lifts `{:ok, result, effects}` back into the
     `{:ok, new_slice, result}` shape the rest of the dispatch
     pipeline consumes.
  4. Maps action-not-declared / bad-shape / `:halt` returns to typed
     `{:error, _}` tuples instead of crashing or silently succeeding.
  5. Leaves the existing legacy `invoke/4` path UNCHANGED — same
     Kind can host both contracts side-by-side.

  The fixtures live inline (rather than `test/support/`) so the
  Behavior modules pre-exist for the `String.to_existing_atom`
  handler resolution and so the cap-axis-derivation under the
  Runtime authz step has a real `__action_spec__/1` to consult.
  """

  use ExUnit.Case, async: false

  alias Ezagent.{BehaviorRegistry, Invocation}

  # ---------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------

  # New-contract Behavior — declares two actions, each returning
  # effects that mutate its own slice.
  defmodule NewContractBehavior do
    @moduledoc false
    use Ezagent.Behavior

    action :bump,
      args: %{},
      returns: %{count: :integer},
      caps: [:bump],
      modes: [:call]

    action :record,
      args: %{value: :string},
      returns: %{stored: :boolean},
      caps: [:record],
      modes: [:call]

    action :emit_only,
      args: %{},
      returns: :ok,
      caps: [:emit_only],
      modes: [:call]

    action :fail,
      args: %{},
      returns: :ok,
      caps: [:fail],
      modes: [:call]

    action :bad_return,
      args: %{},
      returns: :ok,
      caps: [:bad_return],
      modes: [:call]

    action :halts,
      args: %{},
      returns: :ok,
      caps: [:halts],
      modes: [:call]

    def state_slice, do: :new_contract

    def handle_bump(_args, ctx) do
      cur = ctx[:read].(:count, 0)
      {:ok, %{count: cur + 1}, [{:set, :count, cur + 1}]}
    end

    def handle_record(%{value: value}, _ctx) do
      {:ok, %{stored: true},
       [
         {:set, :last_value, value},
         {:emit, :recorded, %{value: value}}
       ]}
    end

    def handle_emit_only(_args, _ctx) do
      # No `:set` effects — slice should remain unchanged.
      {:ok, :ok, [{:emit, :nothing_changed, %{}}]}
    end

    def handle_fail(_args, _ctx), do: {:error, :explicit_failure}

    def handle_bad_return(_args, _ctx), do: :not_a_proper_shape

    def handle_halts(_args, _ctx) do
      {:ok, :ok,
       [
         {:set, :count, 999},
         {:halt, :on_purpose}
       ]}
    end
  end

  # Legacy-contract Behavior on the SAME Kind — proves the
  # dispatcher routes per-Behavior, not per-Kind.
  defmodule LegacyContractBehavior do
    @moduledoc false
    @behaviour Ezagent.Behavior

    @impl true
    def actions, do: [:legacy_noop]

    @impl true
    def cap_subjects, do: [{:legacy_noop, "legacy no-op"}]

    @impl true
    def state_slice, do: :legacy

    @impl true
    def init_slice(_args), do: %{count: 0}

    @impl true
    def invoke(:legacy_noop, slice, %{msg: msg}, _ctx) do
      {:ok, %{slice | count: slice.count + 1}, %{legacy_echo: msg}}
    end

    @impl true
    def interface do
      %{
        legacy_noop: %{
          description: "legacy no-op",
          args: %{msg: :string},
          returns: %{legacy_echo: :string},
          modes: [:call]
        }
      }
    end

    @impl true
    def required_caps do
      %{legacy_noop: Ezagent.Capability.cap(:any, __MODULE__, :legacy_noop)}
    end
  end

  defmodule MixedKind do
    @moduledoc "Hosts BOTH contracts to prove dispatch branches per-Behavior."

    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :test_mixed

    @impl true
    def behaviors, do: [NewContractBehavior, LegacyContractBehavior]

    @impl true
    def persistence, do: :ephemeral
  end

  # ---------------------------------------------------------------
  # Setup — register Behaviors + prime initial slice state.
  # ---------------------------------------------------------------

  setup do
    :ok = BehaviorRegistry.register(MixedKind, :bump, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :record, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :emit_only, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :fail, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :bad_return, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :halts, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :legacy_noop, LegacyContractBehavior)

    self_uri = URI.parse("entity://agent/team-alpha/runtime-new-contract-test")

    # Start with empty slices for each Behavior (defensive; mirrors
    # what Kind.Server.init/1 would have built via init_slice/1).
    state = %{
      new_contract: %{},
      legacy: %{count: 0}
    }

    {:ok, state: state, self_uri: self_uri}
  end

  defp invocation(self_uri, action, args) do
    target_string = URI.to_string(%{self_uri | query: "action=mixed.#{action}"})

    %Invocation{
      target: URI.parse(target_string),
      mode: :call,
      args: args,
      ctx: %{
        caller: :system,
        caps: MapSet.new(),
        reply: :ignore
      }
    }
  end

  # ---------------------------------------------------------------
  # New-contract dispatch
  # ---------------------------------------------------------------

  describe "new-contract dispatch via Kind.Runtime.handle_dispatch/4" do
    test "calls handle_<action>/2 and applies :set effect into the slice",
         %{state: state, self_uri: self_uri} do
      inv = invocation(self_uri, :bump, %{})

      assert {:ok, new_state, result, slice_change_event} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      assert result == %{count: 1}
      assert new_state.new_contract == %{count: 1}
      # Legacy slice untouched (different Behavior, different slice key).
      assert new_state.legacy == %{count: 0}

      # Slice changed → event should fire post-commit.
      assert is_map(slice_change_event)
      assert slice_change_event.action == :bump
      assert slice_change_event.slice_key == :new_contract
      assert slice_change_event.new_slice == %{count: 1}
    end

    test "applies multiple effects in declared order (:set + :emit)",
         %{state: state, self_uri: self_uri} do
      inv = invocation(self_uri, :record, %{value: "hello"})

      assert {:ok, new_state, result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      assert result == %{stored: true}
      # :set against the slice landed.
      assert new_state.new_contract.last_value == "hello"
    end

    test "handler returning {:error, reason} propagates as runtime error",
         %{state: state, self_uri: self_uri} do
      inv = invocation(self_uri, :fail, %{})

      assert {:error, :explicit_failure} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end

    test "handler returning bad shape surfaces as {:error, {:bad_handler_return, ...}}",
         %{state: state, self_uri: self_uri} do
      inv = invocation(self_uri, :bad_return, %{})

      assert {:error, {:bad_handler_return, NewContractBehavior, :bad_return, :not_a_proper_shape}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end

    test "effect-only handlers (no :set) leave slice unchanged + no slice_change_event",
         %{state: state, self_uri: self_uri} do
      inv = invocation(self_uri, :emit_only, %{})

      assert {:ok, new_state, _result, slice_change_event} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      # Slice unchanged because no :set effect.
      assert new_state.new_contract == %{}
      # Per the Runtime contract, slice_change_event is nil when
      # new_slice == old_slice.
      assert slice_change_event == nil
    end

    test "{:halt, reason} from apply_effects maps to {:error, {:halt, reason}}",
         %{state: state, self_uri: self_uri} do
      inv = invocation(self_uri, :halts, %{})

      assert {:error, {:halt, :on_purpose}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end
  end

  # ---------------------------------------------------------------
  # Mixed-contract proof: same Kind, different Behavior, different
  # contract — dispatcher branches per-call.
  # ---------------------------------------------------------------

  describe "mixed-contract dispatch (legacy + new-contract share one Kind)" do
    test "legacy invoke/4 path still runs unchanged",
         %{state: state, self_uri: self_uri} do
      inv = invocation(self_uri, :legacy_noop, %{msg: "still-legacy"})

      assert {:ok, new_state, result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      assert result == %{legacy_echo: "still-legacy"}
      assert new_state.legacy == %{count: 1}
      # New-contract slice untouched on a legacy dispatch.
      assert new_state.new_contract == %{}
    end

    test "two dispatches against the same state route to their respective contracts",
         %{state: state, self_uri: self_uri} do
      inv1 = invocation(self_uri, :bump, %{})

      assert {:ok, state_after_new, _r1, _e1} =
               Ezagent.Kind.Runtime.handle_dispatch(inv1, state, MixedKind, self_uri)

      inv2 = invocation(self_uri, :legacy_noop, %{msg: "second"})

      assert {:ok, state_after_legacy, _r2, _e2} =
               Ezagent.Kind.Runtime.handle_dispatch(inv2, state_after_new, MixedKind, self_uri)

      assert state_after_legacy.new_contract == %{count: 1}
      assert state_after_legacy.legacy == %{count: 1}
    end
  end
end
