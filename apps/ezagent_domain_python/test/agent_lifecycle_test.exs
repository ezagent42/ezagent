defmodule Ezagent.Domain.Python.AgentLifecycleTest do
  @moduledoc """
  Task 1.1 (py-agent plan) — the shared `Domain.Python.AgentLifecycle`
  helper: `ensure_alive(%Spec{})` (idempotent self-heal built on
  `start_subprocess/1`) and `phase_from_signal/1` (phase mapping).

  The live-subprocess assertions are `:uv`-tagged (skipped when uv is
  absent); the pure helper (`phase_from_signal`) runs unconditionally.

  (`subscribe_phase/1` + `phase_topic/1` were DELETED in V5 use-side H1 —
  delete-holes #200: no Kind subscribes to `pty:phase:` anymore; the phase
  reaches the behavior point-to-point via `EzagentActor.Signal.signal/2`.)
  """

  use ExUnit.Case, async: false

  alias Ezagent.Domain.Python
  alias Ezagent.Domain.Python.{AgentLifecycle, Spec}

  defp receive_script do
    Path.expand("support/lifecycle_receive_server.py", __DIR__)
  end

  defp lib_dir do
    Path.join([:code.priv_dir(:ezagent_domain_python), "python"])
  end

  # A py-built %Spec{} — exactly the shape Behavior.PyAgent/Template.PyAgent
  # construct (caller-owned; AgentLifecycle never builds it).
  defp py_spec(handle) do
    %Spec{
      handle: handle,
      command: :uv_script,
      script_path: receive_script(),
      cwd: System.tmp_dir!(),
      env: %{"EZAGENT_PYTHON_LIB_DIR" => lib_dir()},
      test_mode: false,
      ping_timeout_ms: 60_000,
      shutdown_grace_ms: 2_000
    }
  end

  defp test_handle do
    "test://agent-lifecycle/" <> Integer.to_string(System.unique_integer([:positive]))
  end

  setup do
    on_exit(fn ->
      DynamicSupervisor.which_children(EzagentDomainPython.Supervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        if is_pid(pid),
          do: DynamicSupervisor.terminate_child(EzagentDomainPython.Supervisor, pid)
      end)
    end)

    :ok
  end

  describe "phase_from_signal/1" do
    test "maps a well-formed pty_phase signal to {:ok, uri, phase}" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_p")

      for phase <- [:starting, :running, :dead] do
        assert {:ok, ^uri, ^phase} =
                 AgentLifecycle.phase_from_signal({:pty_phase, uri, phase, %{}})
      end
    end

    test "ignores unknown phases and non-pty_phase messages" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/py_p")
      assert :ignore = AgentLifecycle.phase_from_signal({:pty_phase, uri, :bogus, %{}})
      assert :ignore = AgentLifecycle.phase_from_signal({:something_else, uri})
      assert :ignore = AgentLifecycle.phase_from_signal(:nope)
    end
  end

  describe "ensure_alive/1 (live subprocess)" do
    @tag :uv
    test "spawns a live Domain.Python child from a py-built %Spec{}" do
      handle = test_handle()
      refute Python.alive?(handle)

      assert :ok = AgentLifecycle.ensure_alive(py_spec(handle))
      assert Python.alive?(handle)

      # End-to-end: the receive method replies via the canonical arity-4 API.
      assert {:ok, %{"text" => "hi"}} =
               Python.call(handle, "receive", %{"text" => "hi"}, 10_000)
    end

    @tag :uv
    test "is idempotent — a second call does not double-start" do
      handle = test_handle()

      assert :ok = AgentLifecycle.ensure_alive(py_spec(handle))
      assert Python.alive?(handle)

      # Capture the live pid, ensure_alive again, assert SAME process.
      [{pid1, _}] = Registry.lookup(EzagentDomainPython.Registry, Python.handle_key(handle))
      assert :ok = AgentLifecycle.ensure_alive(py_spec(handle))
      [{pid2, _}] = Registry.lookup(EzagentDomainPython.Registry, Python.handle_key(handle))

      assert pid1 == pid2
    end
  end
end
