defmodule Ezagent.EntityPresenter do
  @moduledoc """
  Username & Auth M1 — read-only display helper for Entity URIs.

  `display/1` for a single URI; `display_many/1` for batch resolution
  (one query). Renderers that show many entities at once — chat member
  lists, message history — MUST use `display_many/1` so display-name
  lookup stays O(1) queries, never O(rows). (Design铁律 #2.)

  Falls back to the URI path segment (`entity://user/system/admin` → `admin`)
  when no `entity_profiles` row exists, so unprofiled entities (e.g.
  the bootstrap admin, freshly-spawned agents) still render sanely.

  ## Workspace scoping (Phase 9 PR-6 / SPEC v3 §7.2 — documented exception)

  Lookups are by `entity_uri` which is 3-segment workspace-bound
  (PR-2 / SPEC v3 §3). Looking up `entity://user/team-alpha/alice` will
  NEVER return a profile for `entity://user/team-alpha/alice` — the
  URI key IS the workspace partition. We intentionally skip
  `Ezagent.Persistence.scope_by_workspace/2` here because the URI
  primary key + 3-segment shape already provides per-tenant isolation
  at the query level. Documented in the invariant test exemption
  list.
  """

  import Ecto.Query
  alias EzagentCore.Repo
  alias Ezagent.Entity.Profile

  @doc "Friendly name for one URI. Profile name, else URI path segment."
  @spec display(URI.t() | String.t()) :: String.t()
  def display(uri) do
    uri_str = to_str(uri)

    case Repo.get(Profile, uri_str) do
      %Profile{display_name: name} when is_binary(name) and name != "" -> name
      _ -> fallback(uri_str)
    end
  end

  @doc """
  Batch-resolve a list of URIs. Returns a `%{uri_string => name}` map
  (keys are always strings, regardless of input shape).
  """
  @spec display_many([URI.t() | String.t()]) :: %{String.t() => String.t()}
  def display_many(uris) when is_list(uris) do
    uri_strs = Enum.map(uris, &to_str/1)

    found =
      from(p in Profile,
        where: p.entity_uri in ^uri_strs,
        select: {p.entity_uri, p.display_name}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(uri_strs, fn u -> {u, Map.get(found, u) || fallback(u)} end)
  end

  defp fallback(uri_str) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint.
    # Display fallback: parse errors (malformed cookie) fall back to the
    # raw string per the original semantics.
    try do
      uri_str
      |> Ezagent.URI.new!()
      |> Ezagent.URI.name()
      |> then(fn
        {:ok, name} -> name
        :error -> uri_str
      end)
    rescue
      ArgumentError -> uri_str
    end
  end

  defp to_str(%URI{} = u), do: URI.to_string(u)
  defp to_str(s) when is_binary(s), do: s
end
