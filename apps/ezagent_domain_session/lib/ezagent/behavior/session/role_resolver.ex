defmodule Ezagent.ActionSet.Session.RoleResolver do
  @moduledoc false

  alias Ezagent.ActionSet.Session.RouteProvisioner

  @doc false
  @spec resolve(String.t(), URI.t() | nil, map(), term(), module()) :: URI.t() | [URI.t()] | nil
  def resolve(role_name, workspace_uri, ctx, provision_key, behavior_module)
      when is_binary(role_name) do
    case RouteProvisioner.resolve_role(role_name, ctx, provision_key, behavior_module) do
      %URI{} = uri -> uri
      :pending -> []
      nil -> resolve_b2(role_name, workspace_uri)
    end
  end

  defp resolve_b2(role_name, %URI{} = workspace_uri) do
    Ezagent.Workspace.ResponsibilityAssignment.holders(workspace_uri, role_name)
  end

  defp resolve_b2(_role_name, _workspace_uri), do: []
end
