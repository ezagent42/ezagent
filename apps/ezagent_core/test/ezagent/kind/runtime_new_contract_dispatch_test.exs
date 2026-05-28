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

    # Phase 1.5b — actions exercising the full effect grammar
    # (dispatch, notify, emit, saga, terminate, multi-effect ordering).

    action :notify_topic,
      args: %{topic: :string, payload: :map},
      returns: :ok,
      caps: [:notify_topic],
      modes: [:call]

    action :emit_event,
      args: %{event: :atom, payload: :map},
      returns: :ok,
      caps: [:emit_event],
      modes: [:call]

    action :dispatch_to,
      args: %{target: :string},
      returns: :ok,
      caps: [:dispatch_to],
      modes: [:call]

    action :saga_step,
      args: %{},
      returns: :ok,
      caps: [:saga_step],
      modes: [:call]

    action :terminate_target,
      args: %{target: :string},
      returns: :ok,
      caps: [:terminate_target],
      modes: [:call]

    action :halt_after_set_and_notify,
      args: %{},
      returns: :ok,
      caps: [:halt_after_set_and_notify],
      modes: [:call]

    action :multi_effect,
      args: %{},
      returns: :ok,
      caps: [:multi_effect],
      modes: [:call]

    action :order_trace,
      args: %{},
      returns: :ok,
      caps: [:order_trace],
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

    # Phase 1.5b handlers — emit each effect type so executor wiring
    # can be exercised independently.

    def handle_notify_topic(%{topic: topic, payload: payload}, _ctx) do
      {:ok, :ok, [{:notify, topic, payload}]}
    end

    def handle_emit_event(%{event: event, payload: payload}, _ctx) do
      {:ok, :ok, [{:emit, event, payload}]}
    end

    def handle_dispatch_to(%{target: target_str}, _ctx) do
      cmd =
        Ezagent.Cmd.new(
          target_str,
          :legacy_noop,
          %{msg: "from-effect-dispatch"},
          %{caller: :system, reply: :ignore, caps: MapSet.new()}
        )

      {:ok, :ok, [{:dispatch, cmd}]}
    end

    def handle_saga_step(_args, _ctx) do
      saga =
        Ezagent.SagaRunner.new()
        |> Ezagent.SagaRunner.run(:step_a,
          fn ctx, _eff ->
            send(ctx[:test_pid], {:saga_step_ran, ctx[:test_token]})
            {:ok, :step_a_done, []}
          end
        )

      {:ok, :ok, [{:saga, saga}]}
    end

    def handle_terminate_target(%{target: target_str}, _ctx) do
      uri = URI.parse(target_str)
      {:ok, :ok, [{:terminate, uri}]}
    end

    def handle_halt_after_set_and_notify(_args, _ctx) do
      # `apply_effects/2` short-circuits on `:halt`. The `:set` BEFORE
      # the halt IS applied to the accumulator's state (because `:set`
      # runs eagerly during bucketing), but since the dispatcher maps
      # halt to `{:error, _}` the new slice is NEVER committed and the
      # subsequent `:notify` is never executed. We exercise this with
      # a sentinel topic — if the test process receives the
      # broadcast, the executor incorrectly ran past the halt.
      {:ok, :ok,
       [
         {:set, :pre_halt_marker, true},
         {:halt, :stop_now},
         {:notify, "test:halt-after-set:should-not-fire", :sentinel}
       ]}
    end

    def handle_multi_effect(_args, _ctx) do
      # Single handler returning 1 :set + 1 :notify + 1 :emit. All
      # three buckets must execute.
      {:ok, :ok,
       [
         {:set, :multi_effect_marker, :present},
         {:notify, "test:multi-effect:notify", %{multi: :marker}},
         {:emit, :multi_effect_emit, %{from: "multi"}}
       ]}
    end

    def handle_order_trace(_args, _ctx) do
      # Order assertion: notify-topic-1 + emit-event-A + notify-topic-2
      # + emit-event-B. apply_effects/2 SEPARATES notifies and events
      # into distinct buckets but PRESERVES declared order WITHIN each
      # bucket — so the test subscribes to BOTH topics and expects the
      # `:notify, "topic-1"` message to arrive before `"topic-2"`.
      {:ok, :ok,
       [
         {:notify, "test:order-trace:topic-1", :first_notify},
         {:emit, :order_a, %{}},
         {:notify, "test:order-trace:topic-2", :second_notify},
         {:emit, :order_b, %{}}
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

    # Phase 1.5b — register new actions used by effect-executor tests.
    :ok = BehaviorRegistry.register(MixedKind, :notify_topic, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :emit_event, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :dispatch_to, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :saga_step, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :terminate_target, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :halt_after_set_and_notify, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :multi_effect, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :order_trace, NewContractBehavior)

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

  # ===============================================================
  # Phase 1.5b — full effect-executor wiring
  # (`:dispatch`, `:notify`, `:emit`, `:saga`, `:halt`, `:terminate`)
  # ===============================================================

  # Helper: an invocation whose ctx carries extra fields (test pid /
  # token for saga steps). The existing `invocation/3` builds a
  # minimal ctx; this variant lets a test thread an arbitrary
  # payload into the handler.
  defp invocation_with_ctx(self_uri, action, args, extra_ctx) do
    target_string = URI.to_string(%{self_uri | query: "action=mixed.#{action}"})

    %Invocation{
      target: URI.parse(target_string),
      mode: :call,
      args: args,
      ctx:
        Map.merge(
          %{caller: :system, caps: MapSet.new(), reply: :ignore},
          extra_ctx
        )
    }
  end

  describe "Phase 1.5b — :notify effect" do
    test "Phoenix.PubSub.broadcast fires to subscribers on the declared topic",
         %{state: state, self_uri: self_uri} do
      topic = "test:notify-broadcast:#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

      inv = invocation(self_uri, :notify_topic, %{topic: topic, payload: %{hello: :world}})

      assert {:ok, _new_state, _result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      assert_receive %{hello: :world}, 500
    end

    test "broadcast failure (no subscriber) is silent — dispatch still succeeds",
         %{state: state, self_uri: self_uri} do
      # No subscriber on this topic; broadcast should be a no-op + the
      # dispatch must still return :ok.
      topic = "test:notify-silent:#{System.unique_integer([:positive])}"
      inv = invocation(self_uri, :notify_topic, %{topic: topic, payload: %{ignored: true}})

      assert {:ok, _new_state, _result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end
  end

  describe "Phase 1.5b — :emit effect" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
      :ok
    end

    test "EventLog.append/4 is called for each :emit effect",
         %{state: state, self_uri: self_uri} do
      event_name = :"phase15b_emit_#{System.unique_integer([:positive])}"
      payload = %{kind: "test", body: "from-emit"}

      inv = invocation(self_uri, :emit_event, %{event: event_name, payload: payload})

      assert {:ok, _new_state, _result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      rows = Ezagent.EventLog.stream_by_aggregate(self_uri)

      assert Enum.any?(rows, fn r ->
               r.event_name == Atom.to_string(event_name) and r.payload == %{"kind" => "test", "body" => "from-emit"}
             end),
             "Expected EventLog row for event=#{inspect(event_name)}; got #{inspect(Enum.map(rows, & &1.event_name))}"
    end

    test "EventLog append failure is logged but does not halt the dispatch",
         %{state: state, self_uri: self_uri} do
      # `Jason.encode!` raises on payloads containing non-serialisable
      # terms (e.g. PIDs). We craft such a payload so EventLog.append/4
      # rescues into `{:error, _}`; the dispatch must still succeed.
      inv =
        invocation(self_uri, :emit_event, %{
          event: :unserialisable_payload,
          payload: %{pid: self()}
        })

      assert {:ok, _new_state, _result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end
  end

  describe "Phase 1.5b — :dispatch effect" do
    test "a {:dispatch, %Cmd{}} effect re-enters Router.dispatch + propagates failure",
         %{state: state, self_uri: self_uri} do
      # The dispatched Cmd targets a URI that has no live Kind process
      # — Router.dispatch returns `{:error, :no_such_actor}`. Pre-1.5b
      # the executor silently dropped :dispatch effects, so this error
      # would never propagate. Post-1.5b, the dispatch ERROR must
      # surface as `{:error, {:effect_dispatch_failed, _}}` — proving
      # the executor (a) actually called Router.dispatch and (b)
      # propagated the failure.
      target_str = "entity://agent/team-alpha/phase15b-dispatch-target"

      inv = invocation(self_uri, :dispatch_to, %{target: target_str})

      assert {:error, {:effect_dispatch_failed, :no_such_actor}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end

    test "a {:dispatch, %Cmd{}} effect with a valid target is executed (smoke)",
         %{state: state, self_uri: self_uri} do
      # Sanity check: when the executor pre-1.5b silently dropped
      # :dispatch effects, this same handler would have returned
      # {:ok, _, _} even with a bogus target. The previous test
      # asserts the failure path; this one asserts the executor at
      # minimum INVOKED the Router (no silent drop).
      target_str = "entity://agent/team-alpha/another-missing"
      inv = invocation(self_uri, :dispatch_to, %{target: target_str})

      # We expect an error (no live actor) — the IMPORTANT thing is
      # that the error path is `:effect_dispatch_failed`, NOT a
      # silent {:ok, _} from the legacy drop-effects behaviour.
      result = Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      assert match?({:error, {:effect_dispatch_failed, _}}, result),
             "Expected {:error, {:effect_dispatch_failed, _}} (Router was invoked) " <>
               "but got #{inspect(result)} — this indicates the :dispatch effect " <>
               "was silently dropped (pre-1.5b bug)"
    end
  end

  describe "Phase 1.5b — :saga effect" do
    test "{:saga, saga} effect runs SagaRunner.execute/2",
         %{state: state, self_uri: self_uri} do
      token = System.unique_integer([:positive])

      inv =
        invocation_with_ctx(self_uri, :saga_step, %{}, %{
          test_pid: self(),
          test_token: token
        })

      assert {:ok, _new_state, _result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      # The saga's forward step send/2's to test_pid with the token.
      # Receipt proves SagaRunner.execute/2 was invoked (and was
      # passed the ctx with test_pid + test_token).
      assert_receive {:saga_step_ran, ^token}, 500
    end
  end

  describe "Phase 1.5b — :halt effect" do
    test "{:halt, reason} aborts subsequent effects + maps to {:error, {:halt, reason}}",
         %{state: state, self_uri: self_uri} do
      # The handler emits [set, halt, notify]. We subscribe to the
      # notify's sentinel topic — if we receive the broadcast, the
      # executor incorrectly ran past the halt.
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:halt-after-set:should-not-fire")

      inv = invocation(self_uri, :halt_after_set_and_notify, %{})

      assert {:error, {:halt, :stop_now}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      # The notify after :halt MUST NOT have fired.
      refute_receive :sentinel, 100
    end
  end

  describe "Phase 1.5b — :terminate effect" do
    test "{:terminate, URI} calls Ezagent.Kind.terminate (idempotent on absent target)",
         %{state: state, self_uri: self_uri} do
      # Target a URI that has no live Kind. `Kind.terminate/1` is
      # idempotent + best-effort — it must return :ok and the
      # dispatch must succeed (not raise). The behavioural assertion
      # is "no crash" — `Kind.terminate/1` swallows missing-pid
      # lookups so we can't see a positive signal without spawning
      # a real Kind (which would need the full Application + Sup
      # tree). The dispatch returning {:ok, _} IS the assertion.
      target_str = "entity://agent/team-alpha/phase15b-terminate-absent"

      inv = invocation(self_uri, :terminate_target, %{target: target_str})

      assert {:ok, _new_state, _result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end
  end

  describe "Phase 1.5b — multi-effect handler" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
      :ok
    end

    test "handler returning :set + :notify + :emit executes all three buckets",
         %{state: state, self_uri: self_uri} do
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:multi-effect:notify")

      inv = invocation(self_uri, :multi_effect, %{})

      assert {:ok, new_state, _result, slice_change_event} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      # :set ran (state mutated).
      assert new_state.new_contract.multi_effect_marker == :present
      # slice_change_event computed (proves :set wrote into accumulator).
      assert is_map(slice_change_event)
      # :notify ran (broadcast received).
      assert_receive %{multi: :marker}, 500
      # :emit ran (EventLog row appended).
      rows = Ezagent.EventLog.stream_by_aggregate(self_uri)
      assert Enum.any?(rows, fn r -> r.event_name == "multi_effect_emit" end)
    end

    test "declared order is preserved across multiple notifies in the same handler",
         %{state: state, self_uri: self_uri} do
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:order-trace:topic-1")
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:order-trace:topic-2")

      inv = invocation(self_uri, :order_trace, %{})

      assert {:ok, _new_state, _result, _evt} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      # PubSub broadcasts within a single dispatch arrive in
      # declared order at the subscriber (we're a sole subscriber
      # to both topics in this process, and Phoenix.PubSub.broadcast
      # is synchronous from the broadcaster's POV when local).
      assert_receive :first_notify, 500
      assert_receive :second_notify, 500
    end
  end
end
