defmodule Ezagent.Domain.Python.Server.PhaseTest do
  @moduledoc """
  PTY-phase-state-machine 2026-05-26 follow-up (b) — verify that
  `Ezagent.Domain.Python.Server` broadcasts canonical phase
  transitions on `pty:phase:<agent_uri>` when the handle is a URI.

  Per Allen's directive — the same three phases as PtyServer:

    * `:starting` — after `init/1` accepted args, before the python.ping
                    handshake completes
    * `:running`  — after ping pong success (test_mode short-circuits)
    * `:dead`     — on spawn / ping failure or subprocess death

  V5 A1b-rest: the `phase/1` query (`:sys.get_state` reach-in) is
  DROPPED — live phase reaches operators exclusively through this
  PubSub broadcast; there is no state query to test any more.

  Test mode (`Spec.test_mode: true`) short-circuits the real
  `:exec.run/2` + ping handshake — sufficient for exercising the
  phase broadcast plumbing without needing `uv` installed.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Domain.Python
  alias Ezagent.Domain.Python.Server, as: PyServer
  alias Ezagent.Domain.Python.Spec

  defp fresh_uri do
    URI.new!("entity://team-alpha/agent/test_pyphase-#{System.unique_integer([:positive])}")
  end

  defp test_spec(handle) do
    %Spec{
      handle: handle,
      command: ["/usr/bin/false"],
      cwd: System.tmp_dir!(),
      test_mode: true
    }
  end

  defp subscribe_phase(uri) do
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, PyServer.phase_topic(uri))
    uri
  end

  setup do
    on_exit(fn ->
      # Clean up any servers this test started.
      DynamicSupervisor.which_children(EzagentDomainPython.Supervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        if is_pid(pid),
          do: DynamicSupervisor.terminate_child(EzagentDomainPython.Supervisor, pid)
      end)
    end)

    :ok
  end

  describe "phase_topic/1" do
    test "matches PtyServer's topic shape exactly (one subscriber for both flavors)" do
      uri = URI.new!("entity://team-alpha/agent/test_topic")

      assert PyServer.phase_topic(uri) ==
               Ezagent.Domain.Pty.Server.phase_topic(uri)
    end
  end

  describe "init (test_mode) — broadcast sequence for URI handle" do
    test "emits :starting THEN :running in order" do
      uri = fresh_uri()
      subscribe_phase(uri)

      assert {:ok, _pid} = Python.start_subprocess(test_spec(uri))

      assert_receive {:pty_phase, ^uri, :starting, %{os_pid: _, at: _}}, 1_000
      assert_receive {:pty_phase, ^uri, :running, %{os_pid: nil, at: _}}, 1_000
    end
  end

  describe "init (test_mode) — binary handle SKIPS broadcast" do
    test "binary handle works but does NOT publish on the URI topic" do
      # When the handle is a binary (used by facade-level tests), we
      # skip the broadcast entirely — there's no agent URI to derive
      # a topic from, and the binary key isn't a LV/Sandbox concern.
      bin_handle =
        "test://server-phase-bin/" <> Integer.to_string(System.unique_integer([:positive]))

      # Subscribe to a URI-shaped topic — should never receive anything
      probe_uri = URI.new!("entity://team-alpha/agent/test_pyphase-probe")
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, PyServer.phase_topic(probe_uri))

      assert {:ok, _pid} = Python.start_subprocess(test_spec(bin_handle))

      refute_receive {:pty_phase, _, _, _}, 200
    end
  end

  describe "terminate/2 — :dead broadcast" do
    test "emits :dead exactly once when stopped gracefully via Python.stop/1" do
      uri = fresh_uri()
      subscribe_phase(uri)

      {:ok, _pid} = Python.start_subprocess(test_spec(uri))

      assert_receive {:pty_phase, ^uri, :starting, _}, 1_000
      assert_receive {:pty_phase, ^uri, :running, _}, 1_000

      :ok = Python.stop(uri)

      assert_receive {:pty_phase, ^uri, :dead, %{reason: _, at: _}}, 1_000
      refute_receive {:pty_phase, ^uri, :dead, _}, 200
    end
  end
end
