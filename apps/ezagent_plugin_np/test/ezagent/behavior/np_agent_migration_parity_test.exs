defmodule Ezagent.Behavior.NpAgentMigrationParityTest do
  @moduledoc """
  Phase 2-g r3 migration parity test for `Ezagent.Behavior.NpAgent`.

  Asserts the new-contract Behavior preserves the OUTCOMES the
  legacy `invoke/4`-based implementation provided:

  - `:reset` clears `last_input` / `last_result` / `last_error`
  - `:configure` updates `timeout_ms`
  - `:receive` from self is a no-op (loop guard)
  - The full action set is unchanged
  - Optional callbacks (`post_init/2`, `handle_continue/3`,
    `handle_kind_message/3`) preserve the PTY-orphan-restart contract
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.NpAgent

  describe ":reset parity" do
    test "produces effects that, when applied, clear all 3 last_* fields" do
      slice =
        NpAgent.init_slice(%{uri: URI.parse("entity://agent/ws/np_x")})
        |> Map.put(:last_input, "2+2")
        |> Map.put(:last_result, 4)
        |> Map.put(:last_error, {:python_error, -32_602, "x"})

      assert {:ok, %{ok: true}, effects} = NpAgent.handle_reset(%{}, %{})

      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, slice)
      assert new_state.last_input == nil
      assert new_state.last_result == nil
      assert new_state.last_error == nil
    end
  end

  describe ":configure parity" do
    test "updates timeout_ms through the apply_effects pipeline" do
      slice = NpAgent.init_slice(%{uri: URI.parse("entity://agent/ws/np_x")})
      ctx = %{read: fn k, d -> Map.get(slice, k, d) end}

      assert {:ok, %{ok: true}, effects} =
               NpAgent.handle_configure(%{timeout_ms: 30_000}, ctx)

      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, slice)
      assert new_state.timeout_ms == 30_000
    end
  end

  describe ":receive parity" do
    test "self-message returns identity result tuple with no effects" do
      agent_uri = URI.parse("entity://agent/ws/np_self")
      msg = Ezagent.Message.new(agent_uri, %{text: "self-loop"})
      ctx = %{
        read: fn _k, d -> d end,
        self_uri: agent_uri,
        caller: URI.parse("session://default/ws/main")
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

  describe "post_init/2 + handle_continue/3 parity" do
    test "post_init/2 unconditionally returns {:continue, :setup_phase_tracking_and_ensure_python}" do
      slice = NpAgent.init_slice(%{uri: URI.parse("entity://agent/ws/np_x")})
      assert {:continue, :setup_phase_tracking_and_ensure_python} =
               NpAgent.post_init(%{}, slice)
    end

    test "handle_continue/3 :ignores when cwd is absent (demand-spawn path)" do
      uri = URI.parse("entity://agent/ws/np_demand")
      slice = NpAgent.init_slice(%{uri: uri})
      ctx = %{self_uri: uri}

      assert :ignore =
               NpAgent.handle_continue(:setup_phase_tracking_and_ensure_python, slice, ctx)
    end
  end

  describe "handle_kind_message/3 parity" do
    test "writes :pty_phase event into :python_phase" do
      uri = URI.parse("entity://agent/ws/np_x")
      slice = NpAgent.init_slice(%{uri: uri})
      ctx = %{self_uri: uri}

      assert {:ok, new_slice} =
               NpAgent.handle_kind_message(
                 {:pty_phase, uri, :running, %{}},
                 slice,
                 ctx
               )

      assert new_slice.python_phase == :running
    end

    test "drops mismatched agent_uri (topic-collision defense)" do
      self_uri = URI.parse("entity://agent/ws/np_self")
      foreign_uri = URI.parse("entity://agent/ws/np_other")
      slice = NpAgent.init_slice(%{uri: self_uri})
      ctx = %{self_uri: self_uri}

      assert :ignore =
               NpAgent.handle_kind_message(
                 {:pty_phase, foreign_uri, :dead, %{}},
                 slice,
                 ctx
               )
    end
  end
end
