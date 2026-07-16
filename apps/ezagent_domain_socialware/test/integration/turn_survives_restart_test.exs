defmodule EzagentDomainSocialware.Integration.TurnSurvivesRestartTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, User}

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :socialware, "restart-#{System.unique_integer([:positive])}")
  end

  defp agent_uri(name), do: Ezagent.URI.entity(:team_alpha, :agent, name)

  defp target(session_uri, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.#{action}")
  end

  defp dispatch(session_uri, action, args) do
    Invocation.dispatch(%Invocation{origin: :trusted_internal,
      target: target(session_uri, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp get_turns(session_uri) do
    {:ok, %{turns: turns, turn_seq: turn_seq}} = Ezagent.Kind.get_slice(session_uri, :turns)
    {turns, turn_seq}
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  test "a dispatched turn survives a cold restart from snapshot" do
    session_uri = session_uri()
    :ok = KindSnapshot.delete(URI.to_string(session_uri))

    {:ok, pid1} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok =
      Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(session_uri, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{expected: [:nl]}} =
             dispatch(session_uri, :dispatch, %{
               turn_id: turn_id,
               subtasks: [%{id: :nl, mention: agent_uri("nl"), prompt: "answer"}]
             })

    wait_until(fn -> not is_nil(KindSnapshot.get(URI.to_string(session_uri))) end)

    {turns_before, 1} = get_turns(session_uri)
    assert turns_before[turn_id].status == :delegating
    assert turns_before[turn_id].expected == MapSet.new([:nl])

    :ok =
      DynamicSupervisor.terminate_child(
        # P5-1b: unified `Entity.Session` runs under instance_message's supervisor.
        EzagentDomainInstanceMessage.SessionSupervisor,
        pid1
      )

    wait_until(fn -> KindRegistry.lookup(session_uri) == :error end)

    {:ok, pid2} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    refute pid1 == pid2

    {turns_after, 1} = get_turns(session_uri)
    assert turns_after == turns_before
  end
end
