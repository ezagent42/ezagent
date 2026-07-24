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

  alias Ezagent.Workspace.Store

  @doc """
  List all live Workspace URIs (those registered under the `workspace://`
  scheme), via the public `Ezagent.Kind.list_instances/0` operator plane.
  """
  @spec list_workspaces() :: [URI.t()]
  def list_workspaces do
    Ezagent.Kind.list_instances()
    |> Enum.map(fn {uri_str, _meta} -> Ezagent.URI.new!(uri_str) end)
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
    caps = caps_to_list(caps)

    # The principal-generation gate is paid exactly once before either the
    # URI/member admin shortcut or any cap-derived workspace scope is used.
    # Previously every cap called authorize/3 independently; a long-lived
    # operator with N caps therefore reloaded N holder caps N times (O(N²))
    # and the umbrella precommit suite eventually timed out. The self-license
    # is the holder-axis proof; target caps below still pass authorize/3 on
    # their own target axis.
    if principal_current?(caller_uri, caps) do
      cond do
        uri_or_membership_admin?(caller_uri) ->
          Store.list_all()

        current_cap_admin?(caller_uri, caps) ->
          Store.list_all()

        true ->
          caller_str = caller_uri_string(caller_uri)
          all = Store.list_all()
          ws_uri_strs = current_workspace_uri_strs(caller_uri, caps)

          Enum.filter(all, fn ws ->
            member_match?(ws, caller_str) or cap_scope_match?(ws, ws_uri_strs)
          end)
      end
    else
      []
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

  defp principal_current?(%URI{} = caller_uri, caps) do
    caps
    |> Enum.filter(fn
      %Ezagent.Capability{} = cap ->
        Ezagent.Capability.action_of(cap) == :self_license

      _ ->
        false
    end)
    |> Enum.any?(&current_authorizing_cap?(caller_uri, &1))
  end

  defp principal_current?(_caller_uri, _caps), do: false

  # Passing an empty cap set makes AdminAuthority evaluate only the
  # structural URI/system-membership predicates. The self-license gate above
  # ensures those shortcuts cannot revive a generation-bumped principal.
  defp uri_or_membership_admin?(caller_uri) do
    Ezagent.Identity.AdminAuthority.admin?(caller_uri, [])
  end

  # Cap-based admin is accepted only when the exact admin-shaped artifact is
  # current on both axes. Structural prefiltering is not itself authority; it
  # only avoids re-running the holder gate for irrelevant caps.
  defp current_cap_admin?(%URI{} = caller_uri, caps) do
    Enum.any?(caps, fn
      %Ezagent.Capability{} = cap ->
        Ezagent.Identity.AdminAuthority.admin?(nil, [cap]) and
          current_authorizing_cap?(caller_uri, cap)

      _ ->
        false
    end)
  end

  defp current_cap_admin?(_caller_uri, _caps), do: false

  # Extract concrete workspace scopes and verify at most until the first
  # current cap per workspace. This retains the target-generation gate while
  # avoiding the old O(N²) all-cap holder reload for every artifact.
  defp current_workspace_uri_strs(%URI{} = caller_uri, caps) do
    caps
    |> Enum.reject(fn
      %Ezagent.Capability{} = cap ->
        Ezagent.Capability.action_of(cap) == :self_license

      _ ->
        false
    end)
    |> Enum.group_by(fn
      %Ezagent.Capability{workspace_uri: %URI{} = uri} -> URI.to_string(uri)
      _ -> nil
    end)
    |> Map.delete(nil)
    |> Enum.flat_map(fn {workspace_uri, scoped_caps} ->
      if Enum.any?(scoped_caps, &current_authorizing_cap?(caller_uri, &1)),
        do: [workspace_uri],
        else: []
    end)
  end

  defp current_workspace_uri_strs(_caller_uri, _caps), do: []

  defp caps_to_list(caps) when is_list(caps), do: caps
  defp caps_to_list(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp caps_to_list(_), do: []

  # A workspace-scope match is an authority use, not a metadata query. Verify
  # every candidate against both the authenticated holder and the candidate's
  # own concrete target before its workspace dimension can affect visibility.
  # This preserves the established rule that, for example, a current Session
  # cap scoped to W can surface W, while making a generation-N cap inert as
  # soon as that Session/Workspace target advances to generation N+1.
  defp current_authorizing_cap?(%URI{} = caller_uri, %Ezagent.Capability{} = cap) do
    needed = %{
      kind: cap.kind,
      behavior: cap.behavior,
      action: Ezagent.Capability.action_of(cap),
      instance: cap.instance,
      workspace_uri: cap.workspace_uri
    }

    match?({:ok, ^cap}, Ezagent.Cap.authorize(caller_uri, [cap], needed))
  rescue
    _ -> false
  end

  defp current_authorizing_cap?(_caller_uri, _cap), do: false
end
