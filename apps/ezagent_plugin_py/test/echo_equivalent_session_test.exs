defmodule Ezagent.PluginPy.EchoEquivalentSessionTest do
  @moduledoc """
  P2 headline test — echo-equivalence through a SESSION (not a direct
  `Python.call`). Proves the deleted echo plugin's behavior is now
  reproducible as an operator-script py-agent running the shipped
  `priv/python/echo.py`:

      user --chat.send--> session --chat.receive--> py-agent (echo.py)
        --reply--> chat.send back into the session --> user sees the same text

  This is the real verification of echo retirement: a chat round-trip, the same
  flow the OpenAI `/v1/chat/completions` default path and the world session UI
  exercise — NOT a synchronous `Python.call`.

  `:uv`-tagged — needs a real Domain.Python subprocess.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message, Workspace}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Domain.Python
  alias Ezagent.Entity.User

  @moduletag :uv

  @echo_py File.read!(
             Path.join([
               :code.priv_dir(:ezagent_plugin_py),
               "python",
               "echo.py"
             ])
           )

  setup do
    case System.find_executable("uv") do
      nil ->
        {:skip, "uv not on PATH"}

      _ ->
        ws_name = "py-echo-#{System.unique_integer([:positive])}"
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

  test "an echo.py py-agent echoes a chat message back into the session",
       %{
         ws_name: ws_name,
         workspace_uri: workspace_uri,
         admin_uri: admin_uri,
         admin_ctx: admin_ctx
       } do
    # ---- 1. Create the echo-equivalent py-agent via the REAL path -------
    name = "echobot#{System.unique_integer([:positive])}"

    assert {:ok, %{agent_uri: %URI{} = agent_uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{
                 flavor: "py",
                 name: name,
                 cwd: "",
                 with_pty: false,
                 flavor_config: %{"script" => @echo_py, "timeout_ms" => "10000"}
               },
               admin_ctx
             )

    on_exit(fn ->
      _ = Python.stop(agent_uri)
      _ = Ezagent.Kind.terminate(agent_uri)
    end)

    # Async provision (fix Ⓑ): `instantiate/3` defers subprocess start to
    # `activate/2`, so poll for liveness rather than asserting it synchronously.
    assert wait_alive(agent_uri, 30_000)

    # ---- 2. Stand up a session + join admin + the py-agent --------------
    session_uri = URI.new!("session://#{ws_name}/default/echo-#{System.unique_integer([:positive])}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(session_uri)
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

    case Ezagent.KindRegistry.lookup(admin_uri) do
      {:ok, _} -> :ok
      :error -> {:ok, _} = Ezagent.SpawnRegistry.spawn(admin_uri)
    end

    join(session_uri, admin_uri)
    join(session_uri, agent_uri)

    # ---- 3. Subscribe to the session stream BEFORE the send -------------
    session_topic = SessionBehavior.session_events_topic(session_uri)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

    # ---- 4. admin sends a chat message mentioning the py-agent ----------
    inbound_text = "hello-py-echo-#{System.unique_integer([:positive])}"

    inbound_msg =
      Message.new(admin_uri, %{text: inbound_text, attachments: []}, mentions: [agent_uri])

    :ok =
      Invocation.dispatch(%Invocation{origin: :trusted_internal,
        target: URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
        mode: :cast,
        args: %{message: inbound_msg},
        ctx: %{caller: admin_uri, caps: admin_ctx.caps, reply: :ignore}
      })

    # ---- 5. The py-agent's reply (the SAME text) appears on the stream --
    reply_text = wait_for_sender_reply(agent_uri, inbound_text, 60_000)

    assert reply_text == inbound_text,
           "the echo.py py-agent must echo #{inspect(inbound_text)} back into the " <>
             "session; got #{inspect(reply_text)}"
  end

  # --- helpers ---------------------------------------------------------------

  defp join(session, member) do
    :ok =
      Invocation.dispatch(%Invocation{origin: :trusted_internal,
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

  defp wait_alive(uri, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_alive(uri, deadline)
  end

  defp do_wait_alive(uri, deadline) do
    cond do
      Python.alive?(uri) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(200) && do_wait_alive(uri, deadline)
    end
  end
end
