defmodule EzagentDomainInstanceMessage.SessionCreator.Listing do
  @moduledoc false

  alias Ezagent.Entity.Session
  alias Ezagent.Identity
  alias Ezagent.KindRegistry

  @spec list_sessions :: [URI.t()]
  def list_sessions do
    KindRegistry.list_all()
    |> Enum.flat_map(fn {uri_str, _pid} ->
      case Ezagent.URI.parse(uri_str) do
        {:ok, %URI{} = uri} -> if Ezagent.URI.scheme?(uri, :session), do: [uri], else: []
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(&URI.to_string/1)
  end

  @spec list_sessions(URI.t()) :: [URI.t()]
  def list_sessions(%URI{scheme: "workspace"} = workspace_uri) do
    workspace_name = Ezagent.URI.name!(workspace_uri)

    list_sessions()
    |> Enum.filter(&session_in_workspace?(&1, workspace_name))
  end

  @doc """
  Workspace-scoped session listing filtered by membership.

  Returns only sessions in `workspace_uri` where `caller_uri` is a member.
  Admin callers (checked via `Ezagent.Identity.admin?/1`) bypass the
  membership filter and see all sessions in the workspace — this supports
  operator management surfaces without leaking cross-workspace data (the
  workspace scope is still enforced).

  A non-URI or `nil` caller is fail-closed (empty list) — anonymous or
  unauthenticated callers cannot be members of any session.
  """
  @spec list_sessions(URI.t(), URI.t() | nil) :: [URI.t()]
  def list_sessions(%URI{scheme: "workspace"} = workspace_uri, %URI{} = caller_uri) do
    workspace_sessions = list_sessions(workspace_uri)

    if Identity.admin?(caller_uri) do
      workspace_sessions
    else
      caller_str = URI.to_string(caller_uri)

      Enum.filter(workspace_sessions, fn session_uri ->
        session_uri
        |> Session.session_member_uris()
        |> Enum.any?(&(URI.to_string(&1) == caller_str))
      end)
    end
  end

  def list_sessions(%URI{}, _caller_uri), do: []

  @doc """
  Live PLUS durably-persisted sessions in the workspace — the listing the world
  operator console shows, so a session survives a cold server restart (the plain
  `list_sessions/1` is live-registry only, for internal live-membership queries).
  A listed-but-cold session revives on open (`ConversationActions.do_self_join`
  calls `LocalRuntime.ensure_live/1`).
  """
  @spec list_persisted_sessions(URI.t()) :: [URI.t()]
  def list_persisted_sessions(%URI{scheme: "workspace"} = workspace_uri) do
    workspace_name = Ezagent.URI.name!(workspace_uri)

    (list_sessions() ++ persisted_session_uris())
    |> Enum.uniq_by(&URI.to_string/1)
    |> Enum.filter(&session_in_workspace?(&1, workspace_name))
    |> Enum.sort_by(&URI.to_string/1)
  end

  def list_persisted_sessions(_), do: []

  # Session URIs from durable snapshots (kind_type "session") — the substrate does
  # NOT auto-respawn every session on boot (the cold-restart respawn gap), so the
  # live registry alone under-reports after a restart.
  defp persisted_session_uris do
    Ezagent.Ecto.KindSnapshot.list_all()
    |> Enum.flat_map(fn snap ->
      with "session" <- Map.get(snap, :kind_type),
           uri_str when is_binary(uri_str) <- Map.get(snap, :uri),
           {:ok, %URI{} = uri} <- Ezagent.URI.parse(uri_str),
           true <- Ezagent.URI.scheme?(uri, :session) do
        [uri]
      else
        _ -> []
      end
    end)
  rescue
    _ -> []
  end

  @doc false
  @spec agent_live_sessions(URI.t()) :: {:ok, [URI.t()]} | {:error, term()}
  def agent_live_sessions(%URI{} = agent_uri) do
    case Ezagent.URI.workspace_of(agent_uri) do
      %URI{} = workspace_uri ->
        target = URI.to_string(agent_uri)

        sessions =
          workspace_uri
          |> list_sessions()
          |> Enum.filter(fn session_uri ->
            session_uri
            |> Session.session_member_uris()
            |> Enum.any?(&(URI.to_string(&1) == target))
          end)

        {:ok, sessions}

      :any ->
        {:error, :invalid_agent_uri}
    end
  end

  def agent_live_sessions(_), do: {:error, :invalid_agent_uri}

  @doc false
  @spec agent_in_live_session?(URI.t()) :: {:ok, boolean()} | {:error, term()}
  def agent_in_live_session?(%URI{} = agent_uri) do
    case agent_live_sessions(agent_uri) do
      {:ok, sessions} -> {:ok, sessions != []}
      {:error, _reason} = error -> error
    end
  end

  defp session_in_workspace?(%URI{} = session_uri, workspace_name) do
    case Ezagent.URI.workspace_name(session_uri) do
      {:ok, ^workspace_name} -> true
      _ -> false
    end
  end

  defp session_in_workspace?(_, _), do: false
end
