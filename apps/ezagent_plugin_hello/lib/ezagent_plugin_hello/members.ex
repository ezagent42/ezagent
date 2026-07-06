defmodule EzagentPluginHello.Members do
  @moduledoc """
  Resolve a hello session member URI by its `role_name` facet. Replaces the old
  `orch_`/`hello_`/`concierge_` URI-prefix convention now that members are
  spawned by the framework `Definition.roles` materialization
  (`SessionCreator.materialize_template_team/4`) with PLANNED (UUID) URIs — the
  member URI is no longer derivable from the session name, so the routing-stable
  handle is the `role_name` facet recorded on the (entity × session) membership
  edge at `session.join`.
  """

  # The session's members live UNDER the `:session` state slice (the same slice
  # `Router.owner?/2` reads `:owner_uri` from) as a `%{member_uri => %{role_name:
  # ...}}` map — NOT a top-level `:members` slice. `Ezagent.ActionSet.Session.Members`
  # (the same module `SessionCreator.DefinitionAgents` uses) is the canonical
  # `role_name -> uri` resolver.
  @spec role_uri(URI.t(), String.t()) :: {:ok, URI.t()} | :error
  def role_uri(%URI{} = session_uri, role_name) when is_binary(role_name) do
    with {:ok, slice} when is_map(slice) <- Ezagent.Kind.get_slice(session_uri, :session),
         members when is_map(members) <- Map.get(slice, :members, %{}),
         %URI{} = uri <- Ezagent.ActionSet.Session.Members.role_name_to_uri(members, role_name) do
      {:ok, uri}
    else
      _ -> :error
    end
  end
end
