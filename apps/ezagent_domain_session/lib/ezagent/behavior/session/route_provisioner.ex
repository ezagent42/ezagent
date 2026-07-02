defmodule Ezagent.ActionSet.Session.RouteProvisioner do
  @moduledoc false

  alias Ezagent.KindRegistry
  alias Ezagent.ActionSet.Session.{Members, Membership}
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateTeam

  @doc false
  @spec resolve_role(String.t(), map(), term(), module()) :: URI.t() | nil
  def resolve_role(role_name, ctx, provision_key, behavior_module) when is_binary(role_name) do
    members = ctx[:read].(:members, %{})

    case Members.role_name_to_uri(members, role_name) do
      %URI{} = uri -> uri
      nil -> provision_declared_role(role_name, ctx, provision_key, behavior_module)
    end
  end

  defp provision_declared_role(role_name, ctx, provision_key, behavior_module) do
    session_uri = ctx[:self_uri]
    workspace_uri = workspace_uri_for_session(session_uri)
    owner_uri = ctx[:read].(:owner_uri, nil) || Ezagent.Entity.User.admin_uri()

    with %{} = declaration <- declared_role(role_name, ctx[:read].(:template_working_copy, %{})),
         {:ok, %URI{} = member_uri, facets} <-
           TemplateTeam.provision_declared_member(
             session_uri,
             workspace_uri,
             owner_uri,
             declaration
           ),
         {:ok, member_pid} <- KindRegistry.lookup(member_uri),
         {:ok, _result, effects} <-
           Membership.do_join(member_uri, member_pid, ctx, facets, behavior_module) do
      prior = Process.get(provision_key, [])
      Process.put(provision_key, prior ++ effects)
      member_uri
    else
      _ -> nil
    end
  end

  defp workspace_uri_for_session(%URI{} = session_uri) do
    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, %URI{} = workspace_uri} -> workspace_uri
      :error -> Ezagent.Capability.workspace_of(session_uri)
    end
  end

  defp declared_role(role_name, working_copy)
       when is_binary(role_name) and is_map(working_copy) do
    working_copy
    |> Map.get(:member_declarations, [])
    |> Enum.find(fn
      %{role_name: ^role_name} -> true
      %{"role_name" => ^role_name} -> true
      _ -> false
    end)
  end
end
