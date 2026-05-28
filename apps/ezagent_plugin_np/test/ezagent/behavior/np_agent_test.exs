defmodule Ezagent.Behavior.NpAgentTest do
  @moduledoc """
  Phase 2-g r3 migration: tests exercise the new-contract
  `handle_<action>/2` + effects vocabulary instead of `invoke/4`.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.NpAgent

  describe "macro-derived metadata" do
    test "exactly the 3 documented actions" do
      assert MapSet.new(NpAgent.actions()) ==
               MapSet.new([:receive, :reset, :configure])

      assert Map.keys(NpAgent.interface()) |> Enum.sort() ==
               [:configure, :receive, :reset]
    end

    test "state_slice is :np_agent" do
      assert NpAgent.state_slice() == :np_agent
    end

    test "every action has a description" do
      iface = NpAgent.interface()

      for {action, spec} <- iface do
        assert is_binary(spec[:description]),
               "action #{inspect(action)} is missing a description in interface/0"
      end
    end

    test "required_caps/0 uses :np_agent kind axis (not auto-derived :any)" do
      caps = NpAgent.required_caps()
      assert caps.receive.kind == :np_agent
      assert caps.reset.kind == :np_agent
      assert caps.configure.kind == :np_agent
    end

    test "Behavior.new_style?/1 detects the new contract" do
      assert Ezagent.Behavior.new_style?(NpAgent)
    end
  end

  describe "init_slice/1" do
    test "captures python_handle (via :python_handle or fallback :uri)" do
      uri = URI.parse("entity://agent/team-alpha/np_test")
      s1 = NpAgent.init_slice(%{python_handle: uri})
      assert s1.python_handle == uri

      s2 = NpAgent.init_slice(%{uri: uri})
      assert s2.python_handle == uri
    end

    test "defaults timeout_ms to 10s" do
      s = NpAgent.init_slice(%{uri: URI.parse("entity://agent/team-alpha/np_test")})
      assert s.timeout_ms == 10_000
      assert s.last_input == nil
      assert s.last_result == nil
      assert s.last_error == nil
    end

    test "accepts timeout_ms override" do
      s = NpAgent.init_slice(%{uri: URI.parse("entity://agent/team-alpha/np_x"), timeout_ms: 5_000})
      assert s.timeout_ms == 5_000
    end
  end

  describe "handle_reset/2" do
    test "emits :set effects clearing last_input / last_result / last_error" do
      assert {:ok, %{ok: true}, effects} = NpAgent.handle_reset(%{}, %{})

      assert {:set, :last_input, nil} in effects
      assert {:set, :last_result, nil} in effects
      assert {:set, :last_error, nil} in effects
    end
  end

  describe "handle_configure/2" do
    test "emits :set effect for timeout_ms" do
      ctx = %{read: fn :timeout_ms, _ -> 10_000; _, d -> d end}

      assert {:ok, %{ok: true}, effects} =
               NpAgent.handle_configure(%{timeout_ms: 30_000}, ctx)

      assert {:set, :timeout_ms, 30_000} in effects
    end

    test "preserves existing timeout when not provided" do
      ctx = %{read: fn :timeout_ms, _ -> 5_000; _, d -> d end}

      assert {:ok, %{ok: true}, effects} = NpAgent.handle_configure(%{}, ctx)
      assert {:set, :timeout_ms, 5_000} in effects
    end
  end

  describe "loop safety on :receive" do
    test "ignores messages whose sender is self_uri (no effects beyond identity result)" do
      agent_uri = URI.parse("entity://agent/team-alpha/np_self")
      msg = Ezagent.Message.new(agent_uri, %{text: "should_not_run"})
      ctx = %{
        read: fn _k, d -> d end,
        self_uri: agent_uri,
        caller: URI.parse("session://default/team-alpha/x")
      }

      assert {:ok, %{ok: true, ignored: :self_message}, []} =
               NpAgent.handle_receive(%{message: msg}, ctx)
    end
  end

  describe "post_init/2 + handle_continue/3 (PTY-phase-state-machine)" do
    test "post_init/2 ALWAYS returns {:continue, :setup_phase_tracking_and_ensure_python}" do
      slice = NpAgent.init_slice(%{uri: URI.parse("entity://agent/team-alpha/np_x")})

      assert {:continue, :setup_phase_tracking_and_ensure_python} =
               NpAgent.post_init(%{}, slice)
    end

    test "handle_continue/3 :ignores when cwd is missing (demand-spawn path)" do
      uri = URI.parse("entity://agent/team-alpha/np_demand")
      slice = NpAgent.init_slice(%{uri: uri})
      assert slice.cwd == nil

      ctx = %{self_uri: uri, kind_module: SomeKind}

      assert :ignore =
               NpAgent.handle_continue(:setup_phase_tracking_and_ensure_python, slice, ctx)
    end
  end

  describe "init_slice/1 / handle_kind_message/3 — python_phase" do
    test "init_slice/1 defaults python_phase to nil" do
      slice = NpAgent.init_slice(%{uri: URI.parse("entity://agent/team-alpha/np_x")})
      assert slice.python_phase == nil
    end

    test "init_slice/1 accepts python_phase from rehydrated args" do
      slice =
        NpAgent.init_slice(%{
          uri: URI.parse("entity://agent/team-alpha/np_x"),
          python_phase: :running
        })

      assert slice.python_phase == :running
    end

    test "init_slice/1 normalizes invalid python_phase values to nil" do
      slice =
        NpAgent.init_slice(%{
          uri: URI.parse("entity://agent/team-alpha/np_x"),
          python_phase: :bogus_atom
        })

      assert slice.python_phase == nil
    end

    test "handle_kind_message/3 writes :pty_phase events into :python_phase" do
      uri = URI.parse("entity://agent/team-alpha/np_x")
      slice = NpAgent.init_slice(%{uri: uri})
      ctx = %{self_uri: uri}

      meta = %{os_pid: 999, reason: nil, at: System.os_time(:millisecond)}

      assert {:ok, new_slice} =
               NpAgent.handle_kind_message(
                 {:pty_phase, uri, :running, meta},
                 slice,
                 ctx
               )

      assert new_slice.python_phase == :running
      assert new_slice.python_handle == uri
      assert new_slice.timeout_ms == 10_000
    end

    test "handle_kind_message/3 ignores non-phase messages" do
      uri = URI.parse("entity://agent/team-alpha/np_x")
      slice = NpAgent.init_slice(%{uri: uri})
      ctx = %{self_uri: uri}

      assert :ignore = NpAgent.handle_kind_message(:other, slice, ctx)
      assert :ignore = NpAgent.handle_kind_message({:foo, :bar}, slice, ctx)
    end

    test "handle_kind_message/3 ignores invalid phase atoms (defensive)" do
      uri = URI.parse("entity://agent/team-alpha/np_x")
      slice = NpAgent.init_slice(%{uri: uri})
      ctx = %{self_uri: uri}

      assert :ignore =
               NpAgent.handle_kind_message(
                 {:pty_phase, uri, :totally_bogus, %{}},
                 slice,
                 ctx
               )
    end

    test "handle_kind_message/3 ignores phase events whose agent_uri ≠ ctx.self_uri" do
      self_uri = URI.parse("entity://agent/team-alpha/np_self")
      foreign_uri = URI.parse("entity://agent/team-alpha/np_other")
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

  describe "data_owner/1" do
    test "returns :no_owner (admin-only Behavior)" do
      assert NpAgent.data_owner(:any) == :no_owner
      assert NpAgent.data_owner(URI.parse("entity://agent/x/y")) == :no_owner
    end
  end
end
