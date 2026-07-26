defmodule Ezagent.ActionSet.Session.Members do
  @moduledoc false

  alias Ezagent.Routing.Legend

  @anon_user_name_prefix "anon-"

  @doc "Whether the URI resolves to a passive data actor that cannot join."
  @spec passive_actor?(URI.t()) :: boolean()
  def passive_actor?(%URI{} = uri) do
    match?({:ok, true}, Ezagent.UriQuery.resolve(:passive, uri))
  end

  def passive_actor?(_), do: false

  @doc "The owner value produced by a grant intent, including first-user claim."
  @spec owner_after_intent(URI.t(), URI.t() | nil) :: URI.t() | nil
  def owner_after_intent(%URI{} = member_uri, prior_owner) do
    if is_nil(prior_owner) and user_uri?(member_uri) and not anon_member?(member_uri),
      do: member_uri,
      else: prior_owner
  end

  @doc """
  Heuristic combining two INDEPENDENT facts: `monitors` (a `ref => uri` map) has
  SOME entry for `member_uri`, AND the calling process is among the monitors of
  the live Kind at `current_uri`. It does NOT tie the two together — the stored
  ref for `member_uri` is not checked to be the ref actually monitoring the
  current Kind, so a stale `member_uri` entry plus any unrelated live
  self-monitor can return a false positive. Treat it as a fast rejoin
  pre-check, not a proof of a correct live monitor.
  """
  @spec monitor_ref_for_current?(map(), URI.t(), URI.t() | String.t()) :: boolean()
  def monitor_ref_for_current?(monitors, %URI{} = member_uri, current_uri) do
    has_uri_entry? =
      Enum.any?(monitors, fn {_ref, uri} ->
        URI.to_string(uri) == URI.to_string(member_uri)
      end)

    has_uri_entry? and self_monitors?(current_uri)
  end

  defp self_monitors?(uri) do
    Ezagent.Kind.monitored_by?(uri)
  end

  @doc "Merge the recognized member facets (`:role_name`, `:in_session_template`, `:source_template_uri`) from `facets` into a member's `meta` map, skipping any whose value is `nil` (so absent facets don't overwrite)."
  @spec put_member_facets(map(), map()) :: map()
  def put_member_facets(meta, facets) when is_map(meta) and is_map(facets) do
    meta
    |> maybe_put_facet(:role_name, Map.get(facets, :role_name))
    |> maybe_put_facet(:in_session_template, Map.get(facets, :in_session_template))
    |> maybe_put_facet(:source_template_uri, Map.get(facets, :source_template_uri))
  end

  defp maybe_put_facet(map, _key, nil), do: map
  defp maybe_put_facet(map, key, value), do: Map.put(map, key, value)

  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(_), do: false

  @doc false
  @spec anon_member?(term()) :: boolean()
  def anon_member?(%URI{scheme: "entity"} = uri) do
    user_uri?(uri) and
      case uri |> URI.to_string() |> String.split("/") |> List.last() do
        nil -> false
        name -> String.starts_with?(name, @anon_user_name_prefix)
      end
  end

  def anon_member?(_), do: false

  @doc "Defensively drop any recognized facet whose value fails its type check (`:role_name` binary, `:in_session_template` boolean, `:source_template_uri` a `%URI{}`) — unrecognized/absent keys pass through untouched."
  @spec sanitize_facets(map()) :: map()
  def sanitize_facets(facets) when is_map(facets) do
    facets
    |> drop_facet_unless(:role_name, &is_binary/1)
    |> drop_facet_unless(:in_session_template, &is_boolean/1)
    |> drop_facet_unless(:source_template_uri, &match?(%URI{}, &1))
  end

  defp drop_facet_unless(map, key, pred) do
    case Map.fetch(map, key) do
      {:ok, value} -> if pred.(value), do: map, else: Map.delete(map, key)
      :error -> map
    end
  end

  @doc "Whether `role_name` is already held by a DIFFERENT member: `:ok` if free or held by `member_uri` itself (or `role_name` is nil); `{:error, {:role_name_taken, role_name}}` if another member holds it."
  @spec role_name_conflict(map(), URI.t(), String.t() | nil) ::
          :ok | {:error, {:role_name_taken, String.t()}}
  def role_name_conflict(_members, _member_uri, nil), do: :ok

  def role_name_conflict(members, %URI{} = member_uri, role_name)
      when is_map(members) and is_binary(role_name) do
    case role_name_to_uri(members, role_name) do
      nil ->
        :ok

      %URI{} = holder ->
        if uri_eq?(holder, member_uri), do: :ok, else: {:error, {:role_name_taken, role_name}}
    end
  end

  defp uri_eq?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)

  @doc "The member URI whose `:role_name` facet equals `role_name`, or `nil` if no member holds that role."
  @spec role_name_to_uri(map(), String.t()) :: URI.t() | nil
  def role_name_to_uri(members, role_name) when is_map(members) and is_binary(role_name) do
    Enum.find_value(members, nil, fn
      {%URI{} = uri, %{role_name: ^role_name}} -> uri
      _ -> nil
    end)
  end

  @doc "The legend registry (role-name → member-set aliases) stored on a chat slice, or `%{}` when none."
  @spec legends_of(map()) :: Legend.registry()
  def legends_of(chat_slice) when is_map(chat_slice) do
    Map.get(chat_slice, :legends, %{})
  end

  @doc "Resolve a legend `name` against the chat slice's legend registry to its entry (`{:ok, entry}`), or `:error` if undefined."
  @spec resolve_legend(map(), String.t()) :: {:ok, Legend.entry()} | :error
  def resolve_legend(chat_slice, name) when is_map(chat_slice) and is_binary(name) do
    Legend.resolve(legends_of(chat_slice), name)
  end

  @doc "Fold a chat slice's members + legends into a flat list of `{:legend, name, member_uris}` and `{:member, uri, meta}` entries (resolving each legend's roles to URIs) — the display/iteration view of a session's roster."
  @spec fold_members(map()) :: [
          {:legend, String.t(), [URI.t()]} | {:member, URI.t(), map()}
        ]
  def fold_members(chat_slice) when is_map(chat_slice) do
    members = Map.get(chat_slice, :members, %{})
    legends = legends_of(chat_slice)
    Legend.fold_members(members, legends, fn role -> role_name_to_uri(members, role) end)
  end
end
