defmodule Ezagent.Kind.RuntimeNewContractDispatchTest do
  @moduledoc """
  `Ezagent.Kind.Runtime.handle_dispatch/4` must detect new-contract
  Behaviors (via `__behavior__?/0` injected by `use Ezagent.ActionSet`)
  and dispatch through the `handle_<action>/2` + `apply_effects/2`
  pipeline.

  These tests verify the new-contract path:

  1. Calls `handle_<action>(args, ctx)` with `ctx[:read]` exposing the
     slice as a `(key, default)` getter.
  2. Applies returned effects in declared order via `apply_effects/2`.
  3. Lifts `{:ok, result, effects}` back into the
     `{:ok, new_slice, result}` shape the rest of the dispatch
     pipeline consumes.
  4. Maps action-not-declared / bad-shape / `:halt` returns to typed
     `{:error, _}` tuples instead of crashing or silently succeeding.

  The fixtures live inline (rather than `test/support/`) so the
  Behavior modules pre-exist for the `String.to_existing_atom`
  handler resolution and so the cap-axis-derivation under the
  Runtime authz step has a real `__action_spec__/1` to consult.

  ## History — Phase 3 deletion (2026-05-28)

  Earlier revisions of this file also tested the LEGACY `invoke/4`
  contract running alongside the new contract on a single Kind. The
  legacy dispatch path was removed in Phase 3 r3 (the only
  Runtime-visible contract is now `use Ezagent.ActionSet` /
  `handle_<action>/2`), so the mixed-contract assertions + the
  `LegacyContractBehavior` fixture were deleted with that phase.
  Phase 3's structural invariant — that the Runtime refuses to
  dispatch a non-new-style module — is enforced by the explicit
  `{:not_a_behavior, _}` return in `invoke_behavior/5` (lib/ezagent/kind/runtime.ex).
  """

  # #92: was `use ExUnit.Case` + two describe-scoped `checkout` + `{:shared,
  # self()}` setups that made the dying test process the global shared owner,
  # clobbering concurrent suites on exit. DataCase shares via a drainable Agent
  # owner module-wide, so the :emit / multi-effect EventLog writes run under a
  # safe shared connection without re-globalizing it onto the test pid.
  use EzagentCore.DataCase, async: false

  alias Ezagent.{BehaviorRegistry, Capability, Invocation}

  # ---------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------

  # New-contract Behavior — declares two actions, each returning
  # effects that mutate its own slice.
  defmodule NewContractBehavior do
    @moduledoc false
    use Ezagent.ActionSet

    action(:bump,
      args: %{},
      returns: %{count: :integer},
      caps: [:bump],
      modes: [:call]
    )

    action(:record,
      args: %{value: :string},
      returns: %{stored: :boolean},
      caps: [:record],
      modes: [:call]
    )

    action(:emit_only,
      args: %{},
      returns: :ok,
      caps: [:emit_only],
      modes: [:call]
    )

    action(:fail,
      args: %{},
      returns: :ok,
      caps: [:fail],
      modes: [:call]
    )

    action(:bad_return,
      args: %{},
      returns: :ok,
      caps: [:bad_return],
      modes: [:call]
    )

    action(:halts,
      args: %{},
      returns: :ok,
      caps: [:halts],
      modes: [:call]
    )

    # Phase 1.5b — actions exercising the full effect grammar
    # (dispatch, notify, emit, saga, terminate, multi-effect ordering).

    action(:notify_topic,
      args: %{topic: :string, payload: :map},
      returns: :ok,
      caps: [:notify_topic],
      modes: [:call]
    )

    action(:emit_event,
      args: %{event: :atom, payload: :map},
      returns: :ok,
      caps: [:emit_event],
      modes: [:call]
    )

    action(:dispatch_to,
      args: %{target: :string},
      returns: :ok,
      caps: [:dispatch_to],
      modes: [:call]
    )

    action(:saga_step,
      args: %{},
      returns: :ok,
      caps: [:saga_step],
      modes: [:call]
    )

    action(:terminate_target,
      args: %{target: :string},
      returns: :ok,
      caps: [:terminate_target],
      modes: [:call]
    )

    action(:halt_after_set_and_notify,
      args: %{},
      returns: :ok,
      caps: [:halt_after_set_and_notify],
      modes: [:call]
    )

    action(:multi_effect,
      args: %{},
      returns: :ok,
      caps: [:multi_effect],
      modes: [:call]
    )

    action(:order_trace,
      args: %{},
      returns: :ok,
      caps: [:order_trace],
      modes: [:call]
    )

    # SPEC 2026-05-29 `:dispatch_returning` exercising actions.
    action(:dispatch_returning_to,
      args: %{target: :string},
      returns: :ok,
      caps: [:dispatch_returning_to],
      modes: [:call]
    )

    action(:dispatch_returning_with_ref,
      args: %{target: :string},
      returns: :ok,
      caps: [:dispatch_returning_with_ref],
      modes: [:call]
    )

    action(:dispatch_returning_mixed_with_effect_returning,
      args: %{target: :string},
      returns: :ok,
      caps: [:dispatch_returning_mixed_with_effect_returning],
      modes: [:call]
    )

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
      # Target URI doesn't exist (the smoke test deliberately points
      # at a missing actor) — Router.dispatch short-circuits with
      # :no_such_actor before the Behavior contract is consulted, so
      # the action atom here is arbitrary.
      cmd =
        Ezagent.Cmd.new(
          target_str,
          :bump,
          %{msg: "from-effect-dispatch"},
          %{caller: :vm_internal, reply: :ignore, caps: MapSet.new()}
        )
        |> Map.put(:origin, :trusted_internal)

      {:ok, :ok, [{:dispatch, cmd}]}
    end

    def handle_saga_step(_args, _ctx) do
      saga =
        Ezagent.SagaRunner.new()
        |> Ezagent.SagaRunner.run(
          :step_a,
          fn ctx, _eff ->
            send(ctx[:test_pid], {:saga_step_ran, ctx[:test_token]})
            {:ok, :step_a_done, []}
          end
        )

      {:ok, :ok, [{:saga, saga}]}
    end

    def handle_terminate_target(%{target: target_str}, _ctx) do
      uri = Ezagent.URI.new!(target_str)
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

    # SPEC 2026-05-29 dispatch_returning handlers.

    def handle_dispatch_returning_to(%{target: target_str}, _ctx) do
      # Single dispatch_returning effect against a missing actor —
      # the executor's `execute_dispatches_returning/3` will surface
      # the Router.dispatch failure as
      # `{:error, {:dispatch_returning_failed, name, reason}}`.
      cmd =
        Ezagent.Cmd.new(
          target_str,
          :bump,
          %{},
          %{caller: :vm_internal, reply: {:caller_inbox, self()}, caps: MapSet.new()}
        )
        |> Map.put(:origin, :trusted_internal)

      {:ok, :ok, [{:dispatch_returning, cmd, bind_as: :bumped}]}
    end

    def handle_dispatch_returning_with_ref(%{target: target_str}, _ctx) do
      # dispatch_returning followed by a downstream :notify whose
      # payload references the bound value via `{:ref, name, path}`.
      # When the dispatch fails, the executor aborts BEFORE the
      # notify runs — but this test exercises ONLY the binding-shape
      # path through the executor (via the deliberate-failure mode).
      cmd =
        Ezagent.Cmd.new(
          target_str,
          :bump,
          %{},
          %{caller: :vm_internal, reply: {:caller_inbox, self()}, caps: MapSet.new()}
        )
        |> Map.put(:origin, :trusted_internal)

      {:ok, :ok,
       [
         {:dispatch_returning, cmd, bind_as: :bumped},
         {:notify, "test:dr-ref:notify", {:ref, :bumped, [:count]}}
       ]}
    end

    def handle_dispatch_returning_mixed_with_effect_returning(%{target: target_str}, _ctx) do
      # Two returning effects in one handler. The executor must run
      # them in declared order, populating the shared `returning` map.
      cmd =
        Ezagent.Cmd.new(
          target_str,
          :bump,
          %{},
          %{caller: :vm_internal, reply: {:caller_inbox, self()}, caps: MapSet.new()}
        )
        |> Map.put(:origin, :trusted_internal)

      {:ok, :ok,
       [
         {:effect_returning, fn -> %{token: :token_a} end, [], bind_as: :first},
         {:dispatch_returning, cmd, bind_as: :second},
         {:set, :marker_first, {:ref, :first, [:token]}}
       ]}
    end
  end

  defmodule MixedKind do
    @moduledoc """
    Hosts the new-contract Behavior. (Pre–Phase-3 this Kind also
    hosted a `LegacyContractBehavior` to prove dispatch branched
    per-Behavior across contracts; the legacy contract was removed
    in Phase 3 r3, so this Kind now hosts a single Behavior.)
    """

    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :test_mixed

    @impl true
    def behaviors, do: [NewContractBehavior]

    @impl true
    def persistence, do: :ephemeral
  end

  # ---------------------------------------------------------------
  # Setup — register Behaviors + prime initial slice state.
  # ---------------------------------------------------------------

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    presenter = Ezagent.URI.new!("entity://team-alpha/user/runtime-contract-presenter")

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(presenter) => MapSet.new([:test_holder_license])
    })

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)

    :ok = BehaviorRegistry.register(MixedKind, :bump, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :record, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :emit_only, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :fail, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :bad_return, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :halts, NewContractBehavior)
    # Phase 1.5b — register new actions used by effect-executor tests.
    :ok = BehaviorRegistry.register(MixedKind, :notify_topic, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :emit_event, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :dispatch_to, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :saga_step, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :terminate_target, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :halt_after_set_and_notify, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :multi_effect, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :order_trace, NewContractBehavior)
    # SPEC 2026-05-29 dispatch_returning actions.
    :ok = BehaviorRegistry.register(MixedKind, :dispatch_returning_to, NewContractBehavior)
    :ok = BehaviorRegistry.register(MixedKind, :dispatch_returning_with_ref, NewContractBehavior)

    :ok =
      BehaviorRegistry.register(
        MixedKind,
        :dispatch_returning_mixed_with_effect_returning,
        NewContractBehavior
      )

    self_uri = Ezagent.URI.new!("entity://team-alpha/agent/runtime-new-contract-test")
    _authority = install_test_authority!(self_uri, :test_mixed)

    # Start with empty slices for each Behavior (defensive; mirrors
    # what Kind.Server.init/1 would have built via init_slice/1).
    state = %{
      new_contract: %{}
    }

    {:ok, state: state, self_uri: self_uri}
  end

  defp invocation(self_uri, action, args) do
    target = Ezagent.URI.with_action(self_uri, :mixed, action)
    presenter = Ezagent.URI.new!("entity://team-alpha/user/runtime-contract-presenter")
    authority = Process.get({Ezagent.Cap.Authority, :current})

    requested =
      Capability.cap(
        :test_mixed,
        NewContractBehavior,
        action,
        Ezagent.URI.instance(self_uri),
        Capability.workspace_of(self_uri)
      )

    signed = authority_signed_cap!(authority, presenter, requested)

    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: presenter,
        authenticated_principal: presenter,
        caps: MapSet.new([signed]),
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

      assert {:ok, new_state, result, slice_change_event, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      assert result == %{count: 1}
      assert new_state.new_contract == %{count: 1}

      # Slice changed → event should fire post-commit.
      assert is_map(slice_change_event)
      assert slice_change_event.action == :bump
      assert slice_change_event.slice_key == :new_contract
      assert slice_change_event.new_slice == %{count: 1}
    end

    test "applies multiple effects in declared order (:set + :emit)",
         %{state: state, self_uri: self_uri} do
      inv = invocation(self_uri, :record, %{value: "hello"})

      assert {:ok, new_state, result, _evt, _deferred} =
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

      assert {:error,
              {:bad_handler_return, NewContractBehavior, :bad_return, :not_a_proper_shape}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end

    test "effect-only handlers (no :set) leave slice unchanged + no slice_change_event",
         %{state: state, self_uri: self_uri} do
      inv = invocation(self_uri, :emit_only, %{})

      assert {:ok, new_state, _result, slice_change_event, _deferred} =
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

  # ===============================================================
  # Phase 1.5b — full effect-executor wiring
  # (`:dispatch`, `:notify`, `:emit`, `:saga`, `:halt`, `:terminate`)
  # ===============================================================

  # Helper: an invocation whose ctx carries extra fields (test pid /
  # token for saga steps). The existing `invocation/3` builds a
  # minimal ctx; this variant lets a test thread an arbitrary
  # payload into the handler.
  defp invocation_with_ctx(self_uri, action, args, extra_ctx) do
    invocation = invocation(self_uri, action, args)
    %{invocation | ctx: Map.merge(invocation.ctx, extra_ctx)}
  end

  describe "Phase 1.5b — :notify effect" do
    test "Phoenix.PubSub.broadcast fires to subscribers on the declared topic",
         %{state: state, self_uri: self_uri} do
      topic = "test:notify-broadcast:#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

      inv = invocation(self_uri, :notify_topic, %{topic: topic, payload: %{hello: :world}})

      assert {:ok, _new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      assert_receive %{hello: :world}, 500
    end

    test "broadcast failure (no subscriber) is silent — dispatch still succeeds",
         %{state: state, self_uri: self_uri} do
      # No subscriber on this topic; broadcast should be a no-op + the
      # dispatch must still return :ok.
      topic = "test:notify-silent:#{System.unique_integer([:positive])}"
      inv = invocation(self_uri, :notify_topic, %{topic: topic, payload: %{ignored: true}})

      assert {:ok, _new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end
  end

  describe "Phase 1.5b — :emit effect" do
    # Shared sandbox provided module-wide by `use EzagentCore.DataCase` (#92).

    test "EventLog.append/4 is called for each :emit effect",
         %{state: state, self_uri: self_uri} do
      event_name = :"phase15b_emit_#{System.unique_integer([:positive])}"
      payload = %{kind: "test", body: "from-emit"}

      inv = invocation(self_uri, :emit_event, %{event: event_name, payload: payload})

      assert {:ok, _new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      rows = Ezagent.EventLog.stream_by_aggregate(self_uri)

      assert Enum.any?(rows, fn r ->
               r.event_name == Atom.to_string(event_name) and
                 r.payload == %{"kind" => "test", "body" => "from-emit"}
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

      assert {:ok, _new_state, _result, _evt, _deferred} =
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
      target_str = "entity://team-alpha/agent/phase15b-dispatch-target"

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
      target_str = "entity://team-alpha/agent/another-missing"
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

      assert {:ok, _new_state, _result, _evt, _deferred} =
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
      target_str = "entity://team-alpha/agent/phase15b-terminate-absent"

      inv = invocation(self_uri, :terminate_target, %{target: target_str})

      assert {:ok, _new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end
  end

  describe "Phase 1.5b — multi-effect handler" do
    # Shared sandbox provided module-wide by `use EzagentCore.DataCase` (#92).

    test "handler returning :set + :notify + :emit executes all three buckets",
         %{state: state, self_uri: self_uri} do
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:multi-effect:notify")

      inv = invocation(self_uri, :multi_effect, %{})

      assert {:ok, new_state, _result, slice_change_event, _deferred} =
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

      assert {:ok, _new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      # PubSub broadcasts within a single dispatch arrive in
      # declared order at the subscriber (we're a sole subscriber
      # to both topics in this process, and Phoenix.PubSub.broadcast
      # is synchronous from the broadcaster's POV when local).
      assert_receive :first_notify, 500
      assert_receive :second_notify, 500
    end
  end

  # ===============================================================
  # SPEC 2026-05-29 — `:dispatch_returning` effect executor
  # (full grammar — happy path / multi-step bind / failure / mixed
  # with `:effect_returning`)
  # ===============================================================

  describe "SPEC 2026-05-29 — :dispatch_returning failure mode" do
    test "{:error, ...} from Router.dispatch surfaces as :dispatch_returning_failed",
         %{state: state, self_uri: self_uri} do
      # The dispatched Cmd targets a URI that has no live Kind process.
      # Router.dispatch returns `{:error, :no_such_actor}`; the executor
      # MUST surface that as `{:error, {:dispatch_returning_failed, :bumped, :no_such_actor}}`
      # — NOT silently succeed (pre-SPEC behaviour for `:dispatch`) and
      # NOT collapse into the generic `:effect_dispatch_failed` wrapper.
      target_str = "entity://team-alpha/agent/dr-failure-target"

      inv = invocation(self_uri, :dispatch_returning_to, %{target: target_str})

      assert {:error, {:dispatch_returning_failed, :bumped, :no_such_actor}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end

    test "failure aborts downstream effects — :notify after failing :dispatch_returning never fires",
         %{state: state, self_uri: self_uri} do
      # Subscribe to the topic referenced by the notify — if it fires,
      # the executor incorrectly ran past the failure.
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:dr-ref:notify")

      target_str = "entity://team-alpha/agent/dr-ref-failure-target"
      inv = invocation(self_uri, :dispatch_returning_with_ref, %{target: target_str})

      assert {:error, {:dispatch_returning_failed, :bumped, :no_such_actor}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)

      # The notify referencing {:ref, :bumped, [:count]} MUST NOT have
      # fired — the executor short-circuited at the failed returning
      # dispatch.
      refute_receive _any, 100
    end
  end

  describe "SPEC 2026-05-29 — :dispatch_returning mixed with :effect_returning" do
    test "both bindings populate; downstream :set substitutes the :effect_returning ref",
         %{state: state, self_uri: self_uri} do
      # The :dispatch_returning side fails (no live target) — we
      # assert that the failure carries the :second binding name,
      # proving the executor reached the :dispatch_returning bucket
      # AFTER processing the :effect_returning bucket (which had
      # populated `returning` before the :dispatch_returning ran).
      target_str = "entity://team-alpha/agent/dr-mixed-failure-target"

      inv =
        invocation(
          self_uri,
          :dispatch_returning_mixed_with_effect_returning,
          %{target: target_str}
        )

      # The handler's effects list is:
      #   [{:effect_returning, fn, [], bind_as: :first},
      #    {:dispatch_returning, cmd, bind_as: :second},
      #    {:set, :marker_first, {:ref, :first, [:token]}}]
      #
      # `apply_effects/2` runs the effect_returning bucket (populating
      # :first = %{token: :token_a}) AND substitutes the :set effect's
      # ref BEFORE the executor handles the buckets. The executor THEN
      # runs the :dispatch_returning bucket, which fails — surfacing
      # `{:dispatch_returning_failed, :second, _}` (the failing
      # binding's name).
      assert {:error, {:dispatch_returning_failed, :second, :no_such_actor}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, MixedKind, self_uri)
    end
  end
end
