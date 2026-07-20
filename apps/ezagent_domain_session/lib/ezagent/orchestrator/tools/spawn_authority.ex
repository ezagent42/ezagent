defmodule Ezagent.Orchestrator.Tools.SpawnAuthority do
  @moduledoc false

  @doc false
  @spec grant(URI.t(), URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant(%URI{} = member_uri, %URI{} = controller_uri, %URI{} = workspace_uri) do
    with :ok <- Ezagent.Identity.TargetAuthority.ensure(controller_uri, member_uri),
         :ok <-
           EzagentDomainInstanceMessage.SessionCreator.Materializer.grant_owner_participant_teardown_cap(
             member_uri,
             controller_uri,
             workspace_uri
           ),
         :ok <-
           Ezagent.Workspace.grant_creator_manage_cap(
             :agent,
             member_uri,
             workspace_uri,
             controller_uri
           ) do
      :ok
    end
  end
end
