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
           Membership.do_join(
             member_uri,
             member_pid,
             system_mediated_ctx(ctx),
             facets,
             behavior_module
           ) do
      prior = Process.get(provision_key, [])
      Process.put(provision_key, prior ++ effects)
      member_uri
    else
      _ -> nil
    end
  end

  # #161 C.1 (admission-gate over-fire fix) — realizing a member DECLARED in the
  # session's OWN template spec (`member_declarations`, resolved by `declared_role/2`)
  # is SYSTEM-MEDIATED materialization, NOT a caller-initiated cross-owner add: the
  # declaration was vetted at template author/publish + install time, and routing
  # merely lazily provisions it on first reference. Run the member `do_join` under the
  # genesis admin caller — IDENTICAL to `Materializer.join_session_members` /
  # `DefinitionAgents` at session-CREATE (both use `caller: admin_uri` for the same
  # reason) — so the admission gate does NOT pend the session's own declared members
  # just because an ordinary participant's message happened to trigger the lazy
  # provision. Overriding ONLY `:caller` is safe: `do_join_apply` reads
  # `self_uri`/`read`/`transients`, never `ctx.caller`. A genuine cross-owner PULL never
  # reaches here — that is a DIRECT `session.join` with `caller = puller` (still pends);
  # this path fires only for a role found in THIS session's `declared_role/2`.
  defp system_mediated_ctx(ctx), do: Map.put(ctx, :caller, Ezagent.Entity.User.admin_uri())

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
