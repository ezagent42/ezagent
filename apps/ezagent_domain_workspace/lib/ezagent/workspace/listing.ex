defmodule Ezagent.Workspace.Listing do
  @moduledoc """
  Workspace listing + cap-derived per-caller visibility queries —
  extracted verbatim from `Ezagent.Workspace` (#25 Phase-3, PR-3U).

  Pure read/query layer: no mutation, no dispatch, no member/cap writes
  (the #685 CapBAC membership path stays in `Ezagent.Workspace`). The
  facade keeps `list_workspaces/0`, `list_all/0`, `list_workspaces_for/2`
  as `defdelegate`s into this module so all callers (live_auth, mix
  tasks, invariant tests) are unchanged.
  """

  alias Ezagent.KindRegistry
  alias Ezagent.Workspace.Store

  @doc """
  List all live Workspace URIs (those registered in KindRegistry under
  the `workspace://` scheme).
  """
  @spec list_workspaces() :: [URI.t()]
  def list_workspaces do
    KindRegistry.list_all()
    |> Enum.map(fn {uri_str, _pid} -> Ezagent.URI.new!(uri_str) end)
    |> Enum.filter(&Ezagent.URI.scheme?(&1, :workspace))
    |> Enum.sort_by(&URI.to_string/1)
  end

  @doc """
  List all persisted workspaces — SYSTEM-INTERNAL use only
  (Loader rehydration, agent-flavor resolution, audit mix tasks,
  invariant tests).

  SPEC 2026-05-27-workspace-cap-based-visibility §4.2: operator-facing
  surfaces (LiveViews, web auth mounts, plugin-author UIs) MUST use
  `list_workspaces_for/2` — the cap-derived per-caller view. The
  `list_visible/0` field-based filter and the `list_persisted/0`
  alias are both DELETED in this SPEC.
  """
  @spec list_all() :: [map()]
  def list_all, do: Store.list_all()

  @doc """
  Cap-derived per-caller workspace listing — the SINGLE operator-facing
  query (SPEC 2026-05-27-workspace-cap-based-visibility §3.3).

  Returns workspaces the caller can act on, computed as:

      list_workspaces_for(caller_uri, caps) =
        if   admin_shortcut(caller_uri, caps)  -- 4-predicate UNION
        then list_all()
        else union(
               member_of_workspaces(caller_uri),  -- (a) membership
               workspaces_for_caps(caps)          -- (b) cap-scope
             )

  Where `admin_shortcut/2` is the 4-predicate UNION encoded by
  `Ezagent.Identity.AdminAuthority.admin?/2`:

  - bootstrap-wildcard cap (`kind:any/behavior:any/action:any/instance:any/workspace_uri:any`)
  - structural cross-workspace admin cap
    (`kind:workspace/behavior:Workspace/action:any/instance:any/workspace_uri:any`)
  - caller's URI host is `system` (admin-created in `workspace://system`)
  - caller is a member of `workspace://system` (promoted via the LV
    admin flow)

  ## Inputs

  - `caller_uri` — `%URI{}` of the caller (`entity://user/<ws>/<name>`
    typical; `entity://agent/...` accepted). Malformed callers
    return `[]` defensively per SPEC §3.6.
  - `caps` — caller's loaded cap set (`MapSet.t() | [Capability.t()]`).
    Supplied by upstream (`live_auth.ex`, mix tasks, etc.); this
    function does NOT re-fetch from `Identity` slice.

  ## Output

  `[Workspace.Store.decoded()]` sorted by name ASC. Same shape as
  the former `list_visible/0` minus the deleted `:visible` key.

  ## Caps with `workspace_uri: :any` from non-admin callers

  Per SPEC §3.3.b + OQ-5: caps with `workspace_uri: :any` contribute
  NOTHING to the non-admin cap-scope branch. The admin shortcut is
  the legitimate way to surface all workspaces; a non-admin holding
  a session-wildcard cap should not see every workspace in the
  system. This is deliberately NARROWER than
  `Capability.cross_workspace?/2`'s first clause — see SPEC §3.3
  "Relationship" subsection.
  """
  @spec list_workspaces_for(URI.t() | nil, MapSet.t() | [Ezagent.Capability.t()]) :: [map()]
  def list_workspaces_for(caller_uri, caps) do
    if Ezagent.Identity.AdminAuthority.admin?(caller_uri, caps) do
      Store.list_all()
    else
      caller_str = caller_uri_string(caller_uri)
      all = Store.list_all()
      ws_uri_strs = caps_workspace_uri_strs(caps)

      all
      |> Enum.filter(fn ws ->
        member_match?(ws, caller_str) or cap_scope_match?(ws, ws_uri_strs)
      end)
    end
  end

  # `%URI{}` → "entity://...". `nil` / non-URI → `nil` (membership
  # check short-circuits to false). Per SPEC §3.6 defensive contract:
  # malformed callers see no workspaces via the membership branch,
  # cap-scope still applies independently.
  defp caller_uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp caller_uri_string(_), do: nil

  defp member_match?(_ws, nil), do: false

  defp member_match?(%{members: members}, caller_str)
       when is_list(members) and is_binary(caller_str) do
    Enum.any?(members, fn m -> URI.to_string(m) == caller_str end)
  end

  defp member_match?(_, _), do: false

  defp cap_scope_match?(%{uri: %URI{} = ws_uri}, ws_uri_strs) when is_list(ws_uri_strs) do
    URI.to_string(ws_uri) in ws_uri_strs
  end

  defp cap_scope_match?(_, _), do: false

  # Extract concrete `%URI{}` `workspace_uri` values from caps, drop
  # `:any` (per SPEC §3.3.b — wildcards do NOT contribute to the
  # non-admin cap-scope branch). Returns the URIs as strings for O(1)
  # `in/2` lookup.
  defp caps_workspace_uri_strs(caps) do
    caps
    |> caps_to_list()
    |> Enum.flat_map(fn
      %Ezagent.Capability{workspace_uri: %URI{} = uri} -> [URI.to_string(uri)]
      %Ezagent.Capability{workspace_uri: _} -> []
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp caps_to_list(caps) when is_list(caps), do: caps
  defp caps_to_list(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp caps_to_list(_), do: []
end
