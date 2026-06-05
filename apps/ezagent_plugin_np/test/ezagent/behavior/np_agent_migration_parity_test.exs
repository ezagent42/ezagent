defmodule Ezagent.Behavior.NpAgentMigrationParityTest do
  @moduledoc """
  Phase 2-g r3 migration parity test for `Ezagent.Behavior.NpAgent`.

  Asserts the new-contract Behavior preserves the OUTCOMES the
  legacy `invoke/4`-based implementation provided:

  - `:reset` clears `last_input` / `last_result` / `last_error`
  - `:configure` updates `timeout_ms`
  - `:receive` from self is a no-op (loop guard)
  - The full action set is unchanged
  - Lifecycle hooks (`activate/2`, `handle_signal/2`) preserve the
    PTY-orphan-restart contract (Phase B, SPEC 2026-05-29 §2.3B — the
    pre-Lifecycle `post_init/2` + `handle_continue/3` + `handle_kind_message/3`
    unify into the macro-emitted start/signal path).
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.NpAgent

  describe ":reset parity" do
    test "produces effects that, when applied, clear all 3 last_* fields" do
      # `apply_effects/2` reduces an effect list against a FLAT state map
      # (the persistent `.state` container) and returns
      # `{:ok, %{state: new_state}}`. Seed the persistent fields non-nil so
      # the reset effects are observably clearing them.
      state =
        NpAgent.init_slice(%{uri: Ezagent.URI.new!("entity://ws/agent/np_x")}).state
        |> Map.merge(%{
          last_input: "2+2",
          last_result: 4,
          last_error: {:python_error, -32_602, "x"}
        })

      assert {:ok, %{ok: true}, effects} = NpAgent.handle_reset(%{}, %{})

      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, state)
      assert new_state.last_input == nil
      assert new_state.last_result == nil
      assert new_state.last_error == nil
    end
  end

  describe ":configure parity" do
    test "updates timeout_ms through the apply_effects pipeline" do
      # The framework `read` closure + `apply_effects/2` both work against
      # the FLAT persistent `.state` container.
      state = NpAgent.init_slice(%{uri: Ezagent.URI.new!("entity://ws/agent/np_x")}).state
      ctx = %{read: fn k, d -> Map.get(state, k, d) end}

      assert {:ok, %{ok: true}, effects} =
               NpAgent.handle_configure(%{timeout_ms: 30_000}, ctx)

      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, state)
      assert new_state.timeout_ms == 30_000
    end
  end

  describe ":receive parity" do
    test "self-message returns identity result tuple with no effects" do
      agent_uri = Ezagent.URI.new!("entity://ws/agent/np_self")
      msg = Ezagent.Message.new(agent_uri, %{text: "self-loop"})
      ctx = %{
        read: fn _k, d -> d end,
        self_uri: agent_uri,
        caller: Ezagent.URI.new!("session://ws/default/main")
      }

      assert {:ok, %{ok: true, ignored: :self_message}, []} =
               NpAgent.handle_receive(%{message: msg}, ctx)
    end
  end

  describe "macro-derived legacy callbacks (backwards-compat parity)" do
    test "actions/0 matches the legacy set" do
      assert MapSet.new(NpAgent.actions()) ==
               MapSet.new([:receive, :reset, :configure])
    end

    test "interface/0 still keys on all 3 actions with descriptions" do
      iface = NpAgent.interface()

      for action <- [:receive, :reset, :configure] do
        assert Map.has_key?(iface, action)
        assert is_binary(iface[action][:description])
      end
    end

    test "required_caps/0 preserves :np_agent kind axis (not auto-derived :any)" do
      caps = NpAgent.required_caps()

      for action <- [:receive, :reset, :configure] do
        assert %Ezagent.Capability{kind: :np_agent} = caps[action]
      end
    end
  end

  # Lifecycle (SPEC 2026-05-29 §2.3B): `post_init/2` is macro-emitted and
  # ALWAYS schedules the engine `:ezagent_activate` continuation; the
  # developer subscribe-+-self-heal logic lives in `activate/2`.
  describe "activate/2 parity (unified start hook)" do
    test "post_init/2 unconditionally schedules the engine activate continuation" do
      slice = NpAgent.init_slice(%{uri: Ezagent.URI.new!("entity://ws/agent/np_x")})
      assert {:continue, :ezagent_activate} = NpAgent.post_init(%{}, slice)
    end

    test "activate/2 rebuilds the phase-subscription transient when cwd absent (demand-spawn)" do
      uri = Ezagent.URI.new!("entity://ws/agent/np_demand")
      %{state: state} = NpAgent.init_slice(%{uri: uri})
      ctx = %{self_uri: uri}

      assert {:ok, %{phase_subscription: %{topic: topic, subscriber: sub}}} =
               NpAgent.activate(state, ctx)

      assert topic == "pty:phase:" <> URI.to_string(uri)
      assert sub == self()
    end
  end

  # Lifecycle (SPEC 2026-05-29 §2.3B): `handle_kind_message/3` is
  # macro-emitted; the developer hook is `handle_signal/2`, returning the
  # SAME effect list as an action handler.
  describe "handle_signal/2 parity" do
    test "emits {:set, :python_phase, phase} for a matching :pty_phase" do
      uri = Ezagent.URI.new!("entity://ws/agent/np_x")
      ctx = %{self_uri: uri}

      assert {:ok, effects} = NpAgent.handle_signal({:pty_phase, uri, :running, %{}}, ctx)
      assert {:set, :python_phase, :running} in effects
    end

    test "drops mismatched agent_uri (topic-collision defense)" do
      self_uri = Ezagent.URI.new!("entity://ws/agent/np_self")
      foreign_uri = Ezagent.URI.new!("entity://ws/agent/np_other")
      ctx = %{self_uri: self_uri}

      assert :ignore = NpAgent.handle_signal({:pty_phase, foreign_uri, :dead, %{}}, ctx)
    end
  end
end
