defmodule EzagentDomainInstanceMessage.SessionCreator.Materializer do
  @moduledoc false

  alias Ezagent.Invocation
  alias Ezagent.Entity.Session

  # Write `orchestrator_template_uri` + `session_template_uri` to the
  # session's durable working copy before the orchestrator can join.
  def materialize_orchestrator_working_copy(
        %URI{} = session_uri,
        %URI{} = session_template_uri,
        orchestrator_template_uri
      ) do
    prior = Session.read_template_working_copy(session_uri)

    working_copy =
      prior
      |> Map.put(:orchestrator_template_uri, orchestrator_template_uri)
      |> Map.put(:session_template_uri, session_template_uri)

    case Ezagent.Behavior.Session.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  def store_session_orchestrator_uri(%URI{} = session_uri, %URI{} = orchestrator_uri) do
    working_copy =
      session_uri
      |> Session.read_template_working_copy()
      |> Map.put(:orchestrator_uri, orchestrator_uri)

    case Ezagent.Behavior.Session.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  def grant_owner_orchestrator_admin_cap(
        %URI{} = session_uri,
        %URI{} = owner_uri,
        %URI{} = workspace_uri
      ) do
    want = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.Behavior.OrchestratorAdmin,
      action: :restart,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    current =
      EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri)

    if Enum.any?(current, &Session.cap_equal_ignoring_metadata?(&1, want)) do
      :ok
    else
      target = Ezagent.URI.with_action(owner_uri, :identity, :grant_cap)
      cap = %{want | granted_at: DateTime.utc_now()}

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{cap: cap},
          ctx: %{
            caller: owner_uri,
            caps:
              "template-materialize"
              |> Ezagent.SystemPrincipal.uri()
              |> Ezagent.SystemPrincipal.caps(),
            reply: {:caller_inbox, self()}
          }
        })

      case result do
        {:ok, _} -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, {:orchestrator_admin_cap_grant_failed, reason}}
        other -> {:error, {:orchestrator_admin_cap_grant_unexpected, other}}
      end
    end
  end

  def join_session_members(%URI{} = session_uri, members) when is_list(members) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    Enum.reduce_while(members, :ok, fn %URI{} = member_uri, :ok ->
      _ = EzagentDomainInstanceMessage.SessionCreator.demand_spawn_member(member_uri)

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{member: member_uri},
          ctx: %{
            caller: Ezagent.SystemPrincipal.uri("session-internal"),
            caps:
              "session-internal"
              |> Ezagent.SystemPrincipal.uri()
              |> Ezagent.SystemPrincipal.caps(),
            reply: {:caller_inbox, self()}
          }
        })

      case result do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:member_join_failed, member_uri, reason}}}
        other -> {:halt, {:error, {:member_join_unexpected, member_uri, other}}}
      end
    end)
  end
end
