defmodule Ezagent.Workspace.MemberCaps do
  @moduledoc false

  alias Ezagent.{Capability, Identity}
  alias Ezagent.ActionSet.Workspace

  @doc false
  @spec grant_effects(URI.t(), URI.t()) :: [term()]
  def grant_effects(
        %URI{scheme: "workspace"} = workspace_uri,
        %URI{scheme: "entity"} = member_uri
      ) do
    if Ezagent.URI.type?(member_uri, :user) do
      [Identity.Grant.grant_cap_effect(member_uri, cap(workspace_uri), authorization())]
    else
      []
    end
  end

  def grant_effects(_workspace_uri, _member_uri), do: []

  @doc false
  @spec revoke_effects(URI.t(), URI.t()) :: {:ok, [term()]} | {:error, term()}
  def revoke_effects(
        %URI{scheme: "workspace"} = workspace_uri,
        %URI{scheme: "entity"} = member_uri
      ) do
    if Ezagent.URI.type?(member_uri, :user) do
      logical_cap = cap(workspace_uri)

      case Identity.Grant.resolve_revocation_artifact(member_uri, logical_cap) do
        {:ok, artifact} ->
          {:ok,
           [
             Identity.Grant.revoke_cap_returning_effect(
               member_uri,
               artifact,
               authorization(),
               :member_create_session_revoke
             )
           ]}

        {:error, :cap_not_held} ->
          {:ok, []}

        {:error, :effective_caps_read_failed} = error ->
          error
      end
    else
      {:ok, []}
    end
  end

  def revoke_effects(_workspace_uri, _member_uri), do: {:ok, []}

  defp cap(%URI{scheme: "workspace"} = workspace_uri) do
    %Capability{
      kind: :workspace,
      behavior: Workspace,
      action: :create_session,
      instance: workspace_uri,
      workspace_uri: workspace_uri,
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp authorization, do: {:admin, Ezagent.Entity.User.admin_uri()}
end
