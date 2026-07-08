defmodule Ezagent.PluginPy.BufferedFanoutE2ETest do
  @moduledoc """
  PR #1259 codex review item 3 — the buffered-then-drained fan-out END-TO-END:

      session.send → :not-ready py member (cold provision still running)
        → receive cast BUFFERED via PendingDelivery
        → member flips :ready (subprocess up)
        → buffer DRAINS → the member processes the message
        → its reply lands back in the session.

  This is the full production shape of fix Ⓑ: create returns before the
  member's subprocess exists, a first message routed in that window is not
  lost, and it is answered by a LIVE subprocess after the drain. The cold
  provision is stood in by a script that sleeps before serving `python.ping`
  (deterministic; no dependency download).

  `:uv`-tagged — needs a real Domain.Python subprocess.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message, Workspace}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Domain.Python
  alias Ezagent.Entity.User

  @moduletag :uv

  # Sleeps BEFORE registering the ping handler — the not-ready window a first
  # message must survive. 6s: comfortably longer than the join+send setup.
  @slow_reply_py """
  # /// script
  # requires-python = ">=3.11"
  # dependencies = []
  # ///
  import os, sys, time

  time.sleep(6)
  sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])
  from ezagent_python import method, run


  @method("receive")
  def receive(params):
      return {"text": "drained:" + params.get("text", "")}


  if __name__ == "__main__":
      run()
  """

  setup do
    case System.find_executable("uv") do
      nil ->
        {:skip, "uv not on PATH"}

      _ ->
        # Prod-like readiness budget (500ms default; test.exs sets 5s) so
        # `create_agent` returns fast and the send lands INSIDE the ~6s
        # not-ready provision window.
        prev_budget = Application.get_env(:ezagent_core, :spawn_await_ready_ms)
        Application.put_env(:ezagent_core, :spawn_await_ready_ms, 200)

        on_exit(fn ->
          if is_nil(prev_budget) do
            Application.delete_env(:ezagent_core, :spawn_await_ready_ms)
          else
            Application.put_env(:ezagent_core, :spawn_await_ready_ms, prev_budget)
          end
        end)

        ws_name = "py-drain-#{System.unique_integer([:positive])}"
        {:ok, _ws_pid} = Workspace.create(ws_name, %{})
        workspace_uri = URI.new!("workspace://#{ws_name}")

        admin_uri = User.admin_uri()

        admin_ctx = %{
          caller: admin_uri,
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
        }

        {:ok,
         ws_name: ws_name,
         workspace_uri: workspace_uri,
         admin_uri: admin_uri,
         admin_ctx: admin_ctx}
    end
  end

  test "a message sent while the py member is provisioning buffers, drains on ready, and is answered",
       %{
         ws_name: ws_name,
         workspace_uri: workspace_uri,
         admin_uri: admin_uri,
         admin_ctx: admin_ctx
       } do
    # ---- 1. Create the slow-provisioning py member (returns FAST) -------
    name = "drainbot#{System.unique_integer([:positive])}"

    assert {:ok, %{agent_uri: %URI{} = agent_uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{
                 flavor: "py",
                 name: name,
                 cwd: "",
                 with_pty: false,
                 flavor_config: %{"script" => @slow_reply_py, "timeout_ms" => "10000"}
               },
               admin_ctx
             )

    on_exit(fn ->
      _ = Python.stop(agent_uri)
      _ = Ezagent.Kind.terminate(agent_uri)
    end)

    # ---- 2. Session + members, INSIDE the provision window --------------
    session_uri =
      URI.new!("session://#{ws_name}/default/drain-#{System.unique_integer([:positive])}")

    {:ok, _} = Ezagent.SpawnRegistry.spawn(session_uri)
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

    case Ezagent.KindRegistry.lookup(admin_uri) do
      {:ok, _} -> :ok
      :error -> {:ok, _} = Ezagent.SpawnRegistry.spawn(admin_uri)
    end

    join(session_uri, admin_uri)
    join(session_uri, agent_uri)

    session_topic = SessionBehavior.session_events_topic(session_uri)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

    # ---- 3. Send while the member is still NOT ready --------------------
    # The buffering precondition (what makes this the buffered-then-drained
    # path, not a plain delivery): the member's subprocess is still inside
    # its ~6s sleep, so its Kind is :not_ready and the receive cast buffers.
    assert Ezagent.ReadyGate.status(agent_uri) == :not_ready,
           "test invariant: the send must land inside the provision window " <>
             "(agent already #{inspect(Ezagent.ReadyGate.status(agent_uri))})"

    inbound_text = "buffered-hello-#{System.unique_integer([:positive])}"

    inbound_msg =
      Message.new(admin_uri, %{text: inbound_text, attachments: []}, mentions: [agent_uri])

    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
        mode: :cast,
        args: %{message: inbound_msg},
        ctx: %{caller: admin_uri, caps: admin_ctx.caps, reply: :ignore}
      })

    # ---- 4. The member becomes ready AFTERWARDS and the reply arrives ----
    reply_text = wait_for_sender_reply(agent_uri, "drained:" <> inbound_text, 60_000)

    assert reply_text == "drained:" <> inbound_text,
           "the message sent during the not-ready window must be buffered, " <>
             "drained on ready, and answered; got #{inspect(reply_text)}"

    # The member did flip ready (drain precondition held end-to-end).
    assert Ezagent.ReadyGate.status(agent_uri) == :ready
    assert Python.alive?(agent_uri)
  end

  # --- helpers ---------------------------------------------------------------

  defp join(session, member) do
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session)}?action=session.join"),
        mode: :cast,
        args: %{member: member},
        ctx: %{
          caller: member,
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: :ignore
        }
      })

    Process.sleep(50)
  end

  defp wait_for_sender_reply(%URI{} = target_uri, want_text, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    target_str = URI.to_string(target_uri)
    do_wait(target_str, want_text, deadline)
  end

  defp do_wait(target_str, want_text, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:chat_message, _session, %Message{sender: sender, body: body}} ->
        text = body_text(body)

        if URI.to_string(sender) == target_str and text == want_text do
          text
        else
          do_wait(target_str, want_text, deadline)
        end

      _other ->
        do_wait(target_str, want_text, deadline)
    after
      remaining -> nil
    end
  end

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""
end
