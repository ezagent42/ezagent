defmodule EzagentDomainInstanceMessage.SessionCreator.Listing do
  @moduledoc false

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

  defp session_in_workspace?(%URI{} = session_uri, workspace_name) do
    case Ezagent.URI.workspace_name(session_uri) do
      {:ok, ^workspace_name} -> true
      _ -> false
    end
  end

  defp session_in_workspace?(_, _), do: false
end
