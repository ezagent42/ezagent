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

  @doc """
  Resolve a single session member URI by its `role_name` facet. `{:ok, uri}` when
  a member holds that role; `:error` when the `:session` slice is unreadable OR no
  member holds the role.

  The session's members live UNDER the `:session` state slice (the same slice
  `Router.owner?/2` reads `:owner_uri` from) as a `%{member_uri => %{role_name:
  ...}}` map — NOT a top-level `:members` slice. `Ezagent.ActionSet.Session.Members`
  (the same module `SessionCreator.DefinitionAgents` uses) is the canonical
  `role_name -> uri` resolver.
  """
  @spec role_uri(URI.t(), String.t()) :: {:ok, URI.t()} | :error
  def role_uri(%URI{} = session_uri, role_name) when is_binary(role_name) do
    with {:ok, members} <- members(session_uri),
         %URI{} = uri <- Ezagent.ActionSet.Session.Members.role_name_to_uri(members, role_name) do
      {:ok, uri}
    else
      _ -> :error
    end
  end

  @doc """
  Read the session's members map with ONE slice read. `{:ok, map}` even when the
  map is empty (slice readable, nobody joined yet); `:error` ONLY when the
  `:session` slice itself cannot be read at all (no live Kind / read miss).
  """
  @spec members(URI.t()) :: {:ok, map()} | :error
  def members(%URI{} = session_uri) do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      {:ok, slice} when is_map(slice) -> {:ok, Map.get(slice, :members, %{})}
      _ -> :error
    end
  end

  @doc """
  Resolve MULTIPLE roles from a SINGLE slice read. Used by loop-safety guards
  that must distinguish "slice unreadable" (own-membership unknowable — caller
  should fail CLOSED) from "slice readable, a given role just isn't filled yet"
  (that role simply contributes nothing to the resolved list). Returns `:error`
  ONLY when the members slice itself cannot be read; a readable-but-partially-
  filled team still returns `{:ok, list}` (possibly missing some role_names).

  Yields `%URI{}` structs (NOT stringified URIs) so callers compare canonically
  rather than keying on a fragile string form (uri_query.scan `uri_string_key`).
  """
  @spec role_uris(URI.t(), [String.t()]) :: {:ok, [URI.t()]} | :error
  def role_uris(%URI{} = session_uri, role_names) when is_list(role_names) do
    case members(session_uri) do
      {:ok, members} ->
        resolved =
          Enum.flat_map(role_names, fn role_name ->
            case Ezagent.ActionSet.Session.Members.role_name_to_uri(members, role_name) do
              %URI{} = uri -> [uri]
              nil -> []
            end
          end)

        {:ok, resolved}

      :error ->
        :error
    end
  end
end
