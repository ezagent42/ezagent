defmodule Ezagent.Behavior.NpAgentTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.NpAgent

  describe "actions / interface / state_slice" do
    test "exactly the 3 documented actions" do
      assert NpAgent.actions() == [:receive, :reset, :configure]

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

  describe "invoke(:reset)" do
    test "clears last_input / last_result / last_error" do
      slice =
        NpAgent.init_slice(%{uri: URI.parse("entity://agent/team-alpha/np_x")})
        |> Map.put(:last_input, "2+2")
        |> Map.put(:last_result, 4)
        |> Map.put(:last_error, {:python_error, -32_602, "x"})

      assert {:ok, new_slice, %{ok: true}} = NpAgent.invoke(:reset, slice, %{}, %{})
      assert new_slice.last_input == nil
      assert new_slice.last_result == nil
      assert new_slice.last_error == nil
    end
  end

  describe "invoke(:configure)" do
    test "updates timeout_ms" do
      slice = NpAgent.init_slice(%{uri: URI.parse("entity://agent/team-alpha/np_x")})

      assert {:ok, new_slice, %{ok: true}} =
               NpAgent.invoke(:configure, slice, %{timeout_ms: 30_000}, %{})

      assert new_slice.timeout_ms == 30_000
    end
  end

  describe "loop safety on :receive" do
    test "ignores messages whose sender is self_uri" do
      agent_uri = URI.parse("entity://agent/team-alpha/np_self")
      slice = NpAgent.init_slice(%{uri: agent_uri})

      # Message sent by the agent itself — the behavior must not call
      # into Python (the test would crash since Python is not started).
      msg = Ezagent.Message.new(agent_uri, %{text: "should_not_run"})
      ctx = %{self_uri: agent_uri, caller: URI.parse("session://default/team-alpha/x")}

      assert {:ok, ^slice} = NpAgent.invoke(:receive, slice, %{message: msg}, ctx)
    end
  end
end
