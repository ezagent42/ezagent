defmodule Ezagent.Behavior.PyAgentTest do
  @moduledoc """
  Task 1.2 (py-agent plan) — `Behavior.PyAgent`: the single `:receive`
  method dispatches `Domain.Python.call(handle, "receive", …)` and on a
  non-nil reply emits a `chat.send` `{:dispatch, %Cmd{}}`; a raising script
  → `last_error` set, no crash; `:configure` sets `timeout_ms` ONLY (not the
  script); `:reset` clears `last_*`.

  Pure handler tests run unconditionally; the live end-to-end `:receive`
  reply test is `:uv`-tagged.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Behavior.PyAgent
  alias Ezagent.{Cmd, Message}
  alias Ezagent.Domain.Python
  alias Ezagent.Domain.Python.Spec

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

  defp msg(sender, text) do
    Message.new(sender, %{text: text, attachments: []})
  end

  describe "macro-derived metadata" do
    test "exactly the 3 documented actions" do
      assert MapSet.new(PyAgent.actions()) == MapSet.new([:receive, :reset, :configure])
    end

    test "required_caps/0 uses the :py_agent kind axis" do
      caps = PyAgent.required_caps()
      assert caps.receive.kind == :py_agent
      assert caps.reset.kind == :py_agent
      assert caps.configure.kind == :py_agent
    end

    test "state_slice is :py_agent" do
      assert PyAgent.state_slice() == :py_agent
    end
  end

  describe "handle_reset/2" do
    test "clears last_input/result/error via :set effects" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_r")
      {:ok, %{ok: true}, effects} = PyAgent.handle_reset(%{}, ctx(self_uri, nil, %{}))

      assert {:set, :last_input, nil} in effects
      assert {:set, :last_result, nil} in effects
      assert {:set, :last_error, nil} in effects
    end
  end

  describe "handle_configure/2 — script is NOT mutable" do
    test "sets timeout_ms only" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_c")
      state = %{timeout_ms: 10_000, script_path: "/x/agent.py"}

      {:ok, %{ok: true}, effects} =
        PyAgent.handle_configure(%{timeout_ms: 555}, ctx(self_uri, nil, state))

      assert effects == [{:set, :timeout_ms, 555}]
    end

    test "a smuggled :script arg is ignored (only timeout_ms is read)" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_c2")
      state = %{timeout_ms: 10_000}

      {:ok, %{ok: true}, effects} =
        PyAgent.handle_configure(
          %{timeout_ms: 42, script: "import os; os.system('rm -rf /')"},
          ctx(self_uri, nil, state)
        )

      # NO :set effect touches :script_path — only timeout_ms.
      assert effects == [{:set, :timeout_ms, 42}]
      refute Enum.any?(effects, fn {_op, key, _v} -> key == :script_path end)
    end
  end

  describe "handle_receive/2 — loop safety + error capture" do
    test "ignores a message it sent itself" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_self")
      session = Ezagent.URI.new!("session://team-alpha/default/s1")

      {:ok, %{ignored: :self_message}, []} =
        PyAgent.handle_receive(%{message: msg(self_uri, "hi")}, ctx(self_uri, session, %{}))
    end

    test "a not-alive subprocess captures :not_alive to last_error, no crash" do
      self_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_dead")
      session = Ezagent.URI.new!("session://team-alpha/default/s1")
      sender = Ezagent.URI.new!("entity://team-alpha/user/alice")
      # python_handle points at a handle with no live subprocess → :not_alive.
      state = %{python_handle: self_uri, timeout_ms: 1_000}

      {:ok, %{ok: false, error: :not_alive}, effects} =
        PyAgent.handle_receive(
          %{message: msg(sender, "anything")},
          ctx(self_uri, session, state)
        )

      assert {:set, :last_input, "anything"} in effects
      assert {:set, :last_error, :not_alive} in effects
      # No reply dispatch on error.
      refute Enum.any?(effects, &match?({:dispatch, _}, &1))
    end
  end

  describe "handle_receive/2 — live end-to-end reply (uv)" do
    @tag :uv
    test "a non-nil reply emits a chat.send {:dispatch, %Cmd{}}" do
      handle = Ezagent.URI.new!("entity://team-alpha/agent/py_live")
      session = Ezagent.URI.new!("session://team-alpha/default/s_live")
      sender = Ezagent.URI.new!("entity://team-alpha/user/bob")

      start_receive_subprocess(handle)

      on_exit(fn -> Python.stop(handle) end)

      state = %{python_handle: handle, timeout_ms: 10_000}

      {:ok, %{ok: true}, effects} =
        PyAgent.handle_receive(
          %{message: msg(sender, "ping")},
          ctx(handle, session, state)
        )

      assert {:set, :last_result, "ping"} in effects

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, %Cmd{action: :send} = cmd}] = dispatches
      assert cmd.args.message.body.text == "ping"
    end
  end

  defp start_receive_subprocess(handle) do
    script = Path.expand("../../support/echo_receive.py", __DIR__)
    lib = Path.join([:code.priv_dir(:ezagent_domain_python), "python"])

    spec = %Spec{
      handle: handle,
      command: :uv_script,
      script_path: script,
      cwd: System.tmp_dir!(),
      env: %{"EZAGENT_PYTHON_LIB_DIR" => lib},
      test_mode: false,
      ping_timeout_ms: 60_000
    }

    {:ok, _pid} = Python.start_subprocess(spec)
  end
end
