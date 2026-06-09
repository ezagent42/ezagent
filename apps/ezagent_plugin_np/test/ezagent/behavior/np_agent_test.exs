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

  # Lifecycle migration (SPEC 2026-05-29 §2.3B) — `init_slice/1` is now
  # macro-emitted and returns the two-container slice `%{state:,
  # transients:}`; the developer builder is `create/1`. The durable
  # fields live in `.state`, so these tests read `init_slice(...).state`
  # (the chat reference precedent).
  describe "create/1 (PERSISTENT state)" do
    test "captures python_handle (via :python_handle or fallback :uri)" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/np_test")
      s1 = NpAgent.init_slice(%{python_handle: uri}).state
      assert s1.python_handle == uri

      s2 = NpAgent.init_slice(%{uri: uri}).state
      assert s2.python_handle == uri
    end

    test "defaults timeout_ms to 10s" do
      s = NpAgent.init_slice(%{uri: Ezagent.URI.new!("entity://team-alpha/agent/np_test")}).state
      assert s.timeout_ms == 10_000
      assert s.last_input == nil
      assert s.last_result == nil
      assert s.last_error == nil
    end

    test "accepts timeout_ms override" do
      s =
        NpAgent.init_slice(%{uri: Ezagent.URI.new!("entity://team-alpha/agent/np_x"), timeout_ms: 5_000}).state

      assert s.timeout_ms == 5_000
    end

    test "init_slice/1 starts with an EMPTY transients container" do
      slice = NpAgent.init_slice(%{uri: Ezagent.URI.new!("entity://team-alpha/agent/np_x")})
      assert slice.transients == %{}
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
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/np_self")
      msg = Ezagent.Message.new(agent_uri, %{text: "should_not_run"})
      ctx = %{
        read: fn _k, d -> d end,
        self_uri: agent_uri,
        caller: Ezagent.URI.new!("session://team-alpha/default/x")
      }

      assert {:ok, %{ok: true, ignored: :self_message}, []} =
               NpAgent.handle_receive(%{message: msg}, ctx)
    end
  end

  # Lifecycle migration (SPEC 2026-05-29 §2.3B) — the pre-Lifecycle
  # `post_init/2` + `handle_continue/3` UNIFY into `activate/2` (the ONE
  # start hook). `post_init/2` is now macro-emitted and ALWAYS schedules
  # the engine's `:ezagent_activate` continuation; the developer logic
  # (subscribe to phase topic + ensure subprocess alive) lives in
  # `activate/2`, which returns `{:ok, transients}` with the rebuilt
  # phase-subscription transient.
  describe "activate/2 (PTY-phase-state-machine — unified start hook)" do
    test "post_init/2 ALWAYS schedules the engine activate continuation" do
      slice = NpAgent.init_slice(%{uri: Ezagent.URI.new!("entity://team-alpha/agent/np_x")})

      assert {:continue, :ezagent_activate} = NpAgent.post_init(%{}, slice)
    end

    test "activate/2 rebuilds the phase-subscription transient (subscriber = self)" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/np_demand")
      %{state: state} = NpAgent.init_slice(%{uri: uri})
      assert state.cwd == nil

      ctx = %{self_uri: uri, kind_module: SomeKind}

      # cwd missing → demand-spawn path: no subprocess re-spawn, but the
      # phase subscription transient is STILL rebuilt against this process.
      assert {:ok, %{phase_subscription: %{topic: topic, subscriber: sub}}} =
               NpAgent.activate(state, ctx)

      assert topic == "pty:phase:" <> URI.to_string(uri)
      assert sub == self()
    end
  end

  # Lifecycle migration (SPEC 2026-05-29 §2.3B) — `python_phase` is
  # DURABLE state (the LV-badge mirror), read via `init_slice(...).state`.
  # `handle_kind_message/3` is now macro-emitted; the developer hook is
  # `handle_signal/2`, which returns the SAME effect list as an action
  # handler — so a `:pty_phase` signal returns `[{:set, :python_phase,
  # phase}]` (the macro reduces it into the two-container slice).
  describe "create/1 / handle_signal/2 — python_phase" do
    test "init_slice/1 defaults python_phase to nil" do
      slice = NpAgent.init_slice(%{uri: Ezagent.URI.new!("entity://team-alpha/agent/np_x")}).state
      assert slice.python_phase == nil
    end

    test "init_slice/1 accepts python_phase from rehydrated args" do
      slice =
        NpAgent.init_slice(%{
          uri: Ezagent.URI.new!("entity://team-alpha/agent/np_x"),
          python_phase: :running
        }).state

      assert slice.python_phase == :running
    end

    test "init_slice/1 normalizes invalid python_phase values to nil" do
      slice =
        NpAgent.init_slice(%{
          uri: Ezagent.URI.new!("entity://team-alpha/agent/np_x"),
          python_phase: :bogus_atom
        }).state

      assert slice.python_phase == nil
    end

    test "handle_signal/2 emits {:set, :python_phase, phase} for a matching :pty_phase" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/np_x")
      ctx = %{self_uri: uri}

      meta = %{os_pid: 999, reason: nil, at: System.os_time(:millisecond)}

      assert {:ok, effects} =
               NpAgent.handle_signal({:pty_phase, uri, :running, meta}, ctx)

      assert {:set, :python_phase, :running} in effects
    end

    test "handle_signal/2 ignores non-phase messages" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/np_x")
      ctx = %{self_uri: uri}

      assert :ignore = NpAgent.handle_signal(:other, ctx)
      assert :ignore = NpAgent.handle_signal({:foo, :bar}, ctx)
    end

    test "handle_signal/2 ignores invalid phase atoms (defensive)" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/np_x")
      ctx = %{self_uri: uri}

      assert :ignore = NpAgent.handle_signal({:pty_phase, uri, :totally_bogus, %{}}, ctx)
    end

    test "handle_signal/2 ignores phase events whose agent_uri ≠ ctx.self_uri" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/np_self")
      foreign_uri = Ezagent.URI.new!("entity://team-alpha/agent/np_other")
      ctx = %{self_uri: self_uri}

      assert :ignore = NpAgent.handle_signal({:pty_phase, foreign_uri, :dead, %{}}, ctx)
    end
  end

  describe "data_owner/1" do
    test "returns :no_owner (admin-only Behavior)" do
      assert NpAgent.data_owner(:any) == :no_owner
      assert NpAgent.data_owner(Ezagent.URI.new!("entity://x/agent/y")) == :no_owner
    end
  end
end
