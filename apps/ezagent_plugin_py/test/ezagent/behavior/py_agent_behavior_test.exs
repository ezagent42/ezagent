defmodule Ezagent.ActionSet.PyAgentTest do
  @moduledoc """
  `Behavior.PyAgent` (py-agent P4b) — the STATE half of the py flavor folded
  onto the unified `Entity.Agent` Kind. The script round-trip moved to
  `EzagentPluginPy.BridgeAdapter` (the `:in_process_sync` transport); this
  Behavior owns:

    * `:py_sync_result` — persist the adapter's result (`{:ok, %{text}}` /
      `{:ok, :silent}` / `{:error, _}`) into `last_*` and, on a non-nil reply,
      emit a `chat.send` `{:dispatch, %Cmd{}}`.
    * `:py_configure` — set `timeout_ms` ONLY (never the script).
    * `:py_reset` — clear `last_*`.

  The live end-to-end script→reply round-trip is covered by
  `echo_equivalent_session_test.exs` (real `uv` subprocess through the adapter).
  """

  use ExUnit.Case, async: false

  alias Ezagent.ActionSet.PyAgent
  alias Ezagent.Cmd

  # ctx mock matching the Lifecycle test harness (lifecycle.md §Testing).
  defp ctx(self_uri, caller, state) do
    %{
      self_uri: self_uri,
      caller: caller,
      reply: :none,
      read: fn key, default -> Map.get(state, key, default) end,
      transients: %{},
      caps: MapSet.new()
    }
  end

  describe "macro-derived metadata" do
    test "exactly the 4 py-namespaced actions" do
      # :py_ensure_alive added in PR #1259 (item 1b — the async adopt-path
      # provision retry).
      assert MapSet.new(PyAgent.actions()) ==
               MapSet.new([:py_sync_result, :py_reset, :py_configure, :py_ensure_alive])
    end

    test "required_caps/0 — :py_sync_result/:py_ensure_alive on :agent axis, :py_reset/:py_configure on :any" do
      caps = PyAgent.required_caps()
      assert caps.py_sync_result.kind == :agent
      assert caps.py_ensure_alive.kind == :agent
      assert caps.py_reset.kind == :any
      assert caps.py_configure.kind == :any
    end

    test "state_slice is :py_agent" do
      assert PyAgent.state_slice() == :py_agent
    end
  end

  describe "handle_py_reset/2" do
    test "clears last_input/result/error via :set effects" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_r")
      {:ok, %{ok: true}, effects} = PyAgent.handle_py_reset(%{}, ctx(self_uri, nil, %{}))

      assert {:set, :last_input, nil} in effects
      assert {:set, :last_result, nil} in effects
      assert {:set, :last_error, nil} in effects
    end
  end

  describe "handle_py_configure/2 — script is NOT mutable" do
    test "sets timeout_ms only" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_c")
      state = %{timeout_ms: 10_000, script_path: "/x/agent.py"}

      {:ok, %{ok: true}, effects} =
        PyAgent.handle_py_configure(%{timeout_ms: 555}, ctx(self_uri, nil, state))

      assert effects == [{:set, :timeout_ms, 555}]
    end

    test "a smuggled :script arg is ignored (only timeout_ms is read)" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_c2")
      state = %{timeout_ms: 10_000}

      {:ok, %{ok: true}, effects} =
        PyAgent.handle_py_configure(
          %{timeout_ms: 42, script: "import os; os.system('rm -rf /')"},
          ctx(self_uri, nil, state)
        )

      # NO :set effect touches :script_path — only timeout_ms.
      assert effects == [{:set, :timeout_ms, 42}]
      refute Enum.any?(effects, fn {_op, key, _v} -> key == :script_path end)
    end
  end

  describe "handle_py_sync_result/2 — persist adapter result + reply" do
    test "a non-nil reply persists last_result + emits a chat.send {:dispatch, %Cmd{}}" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_live")
      session = Ezagent.URI.new!("session://team-alpha/default/s_live")

      args = %{
        result: {:ok, %{text: "pong"}},
        source_session: session,
        user_text: "ping",
        in_msg_id: "msg-1"
      }

      {:ok, %{ok: true}, effects} =
        PyAgent.handle_py_sync_result(args, ctx(self_uri, session, %{}))

      assert {:set, :last_input, "ping"} in effects
      assert {:set, :last_result, "pong"} in effects

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, %Cmd{action: :send} = cmd}] = dispatches
      assert cmd.args.message.body.text == "pong"
    end

    test "a :silent result persists last_input, no reply dispatch" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_silent")
      session = Ezagent.URI.new!("session://team-alpha/default/s1")

      args = %{result: {:ok, :silent}, source_session: session, user_text: "hush", in_msg_id: "m"}

      {:ok, %{ok: true}, effects} =
        PyAgent.handle_py_sync_result(args, ctx(self_uri, session, %{}))

      assert {:set, :last_input, "hush"} in effects
      assert {:set, :last_result, nil} in effects
      refute Enum.any?(effects, &match?({:dispatch, _}, &1))
    end

    # G5 source 2 — a py failure was previously SILENT to the user (only
    # `last_error` + a log line). It now replies with the structured error
    # payload so the shared error surface can render a per-viewer card.
    test "an :error result captures last_error + replies with a STRUCTURED error" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_err")
      session = Ezagent.URI.new!("session://team-alpha/default/s1")

      args = %{
        result: {:error, :not_alive},
        source_session: session,
        user_text: "anything",
        in_msg_id: "m"
      }

      {:ok, %{ok: false, error: :not_alive}, effects} =
        PyAgent.handle_py_sync_result(args, ctx(self_uri, session, %{}))

      assert {:set, :last_input, "anything"} in effects
      assert {:set, :last_error, :not_alive} in effects

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, %Cmd{action: :send} = cmd}] = dispatches
      assert cmd.args.message.body.error == %{"reason" => ["not_alive"]}
      assert cmd.args.message.body.text == "[agent error] not_alive"
    end
  end
end
