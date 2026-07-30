defmodule EzagentCli.SessionSocialwareFacade do
  @moduledoc "Remote CLI projection for a session's socialware materialization."

  alias Ezagent.Entity.Session
  alias EzagentCli.FacadeRegistry
  alias EzagentDomainInstanceMessage.SessionCreator

  @doc "Registers the owner-gated retry operation on the running runtime."
  @spec register_all() :: :ok
  def register_all do
    FacadeRegistry.register(:session, :reinstall_socialware, &reinstall/1, %{
      opts: [session: :uri],
      about: "Re-run the declared socialware role materialization for an owned session"
    })
  end

  defp reinstall(%{options: options}) do
    with {:ok, caller} <- EzagentCli.Exec.authenticated_principal(),
         {:ok, session_uri} <- session_uri(Map.get(options, :session)),
         {:ok, owner} <- Session.owner(session_uri),
         :ok <- require_owner(caller, owner),
         %URI{} = workspace_uri <- Ezagent.Capability.workspace_of(session_uri),
         {:ok, summary} <-
           SessionCreator.install_session_socialware(session_uri, {workspace_uri, caller}) do
      {:ok, summary}
    else
      :any -> {:error, :install_requires_workspace}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_socialware_reinstall_result, other}}
    end
  end

  defp session_uri(%URI{scheme: "session"} = uri), do: {:ok, uri}
  defp session_uri(_), do: {:error, :session_uri_required}

  defp require_owner(caller, owner) when caller == owner, do: :ok
  defp require_owner(_caller, _owner), do: {:error, :session_owner_required}
end
