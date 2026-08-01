defmodule Ezagent.Workspace.WorkspaceReads do
  @moduledoc """
  The single caller-authorizing read chokepoint for a workspace's session
  and agent LISTs.

  ## Why this exists

  Workspace session-list reads were caller-less:
  `EzagentDomainInstanceMessage.list_sessions(workspace_uri)` filters the
  global registry by workspace ONLY, so any caller who could name a
  workspace enumerated EVERY session in it — including private sessions
  they were never a member of (an existence leak). Workspace agent-list
  reads had the same hole (a workspace-only filter over the entity
  registry). `WorkspaceReads` is the chokepoint, modelled on
  `Ezagent.Socialware.SessionReads` (the conversation-plane read
  chokepoint): every principal-facing workspace session/agent-LIST read
  routes through here, is authorized FIRST, and only then touches the
  listing.

  ## Contract (binding)

  `sessions/2` and `agents/2` take `caller` FIRST and authorize BEFORE
  any read:

    1. WORKSPACE authorization — `caller` must be a well-formed identity
       principal (`Ezagent.URI.bare_principal?/1`) AND the workspace must
       be inside the caller's cap-derived visible set
       (`Ezagent.Workspace.Listing.list_workspaces_for/2`, the SAME
       SPEC 2026-05-27-workspace-cap-based-visibility §3.3 predicate the
       web surfaces use). Any failure → `[]` (fail closed) — never a
       degraded workspace-only listing.
    2. PER-ROW visibility — from the durable workspace-scoped listing a row
       is kept ONLY when the caller may see it. For a session: the caller is
       present in the session facade's live-or-cold member listing, is an
       owner/member according to the shared live-first
       `SessionReads.authorized?/2` predicate, OR the session is public
       (`PublicView.web_anon_access?/1`). The durable member listing keeps cold
       sessions visible without force-spawning them; the live-first check
       preserves immediate revocation for running sessions. For an agent: the
       caller OWNS or MANAGES the agent, OR — ONLY when the CALLER is itself a
       declared workspace member — the agent is on the workspace's shared
       roster (a declared member agent). The shared-roster disjunct keys on the
       CALLER's membership, never the agent's (F2, read-plane PR-4 rework): a
       cap-scoped non-member gets NO roster.
    3. REQUIRED facades pre-resolve (F6, read-plane PR-4 rework) —
       `sessions/2` validates the REQUIRED membership predicate facade
       (`SessionReads.authorized?/2`) and the durable session-list facade
       (`list_persisted_sessions/1` + `list_sessions/2`) BEFORE
       fetching/filtering; when either is unavailable the whole read fails
       closed to `[]` and does NOT fall through to the independent
       public-session predicate. A down `PublicView` merely means no public
       rows are added.

  ## Dependency direction (runtime DI)

  The workspace domain sits BELOW the session/socialware domains
  (`ezagent_domain_session` depends on `ezagent_domain_workspace`, never
  the reverse — a compile-time reference would be a cycle), so the
  session-side listing + predicates are resolved at RUNTIME via
  `Application` env DI — the same pattern as
  `Ezagent.Workspace.Provisioning.resolve_session_facade/0` — guarded by
  `Code.ensure_loaded?/1` + `function_exported?/3`. An unavailable facade
  fails CLOSED (`[]`). The agent-side listing
  (`Ezagent.Entity.Agent.list_in_workspace/1`) sits BELOW this domain (a
  declared dep), so it needs no cycle-breaking DI; it uses the same
  guarded-DI shape purely so tests can inject the base listing and an
  unavailable facade fails closed identically.
  """

  alias Ezagent.Workspace.Listing

  @doc """
  Authorized, per-row-filtered session list for `caller` in `workspace_uri`.

  Authorizes `caller` for the workspace BEFORE reading, then returns ONLY
  the workspace-scoped sessions the caller may see (owner/member OR
  public), as `[URI.t()]` in the base listing's order. Fail-closed: a
  nil/malformed/unauthorized caller, a non-workspace scope, or an
  unavailable session-side facade all return `[]`.
  """
  @spec sessions(URI.t() | term(), URI.t() | term()) :: [URI.t()]
  def sessions(caller, workspace_uri)

  def sessions(%URI{} = caller, %URI{scheme: "workspace"} = workspace_uri) do
    with :ok <- authorize_workspace(caller, workspace_uri),
         :ok <- session_reads_available?(),
         {:ok, {scoped, member_visible}} <- workspace_scoped_sessions(workspace_uri, caller) do
      member_visible = MapSet.new(member_visible, &Ezagent.URI.canonical!/1)
      Enum.filter(scoped, &visible_to?(caller, &1, member_visible))
    else
      _ -> []
    end
  end

  def sessions(_caller, _workspace_uri), do: []

  @doc """
  Authorized, per-row-filtered agent list for `caller` in `workspace_uri`.

  Authorizes `caller` for the workspace BEFORE reading (the SAME
  `authorize_workspace/2` gate as `sessions/2`), then returns ONLY the
  workspace-scoped agents the caller may see, as `[URI.t()]` in the base
  listing's order. Per row, an agent is kept when ANY of:

    1. OWNS — the caller is the agent's owner/creator per the EXISTING
       data-owner rule (`Ezagent.ActionSet.ApiKeys.data_owner/1`: the
       `:api_keys` slice's `creator_uri`, `Ezagent.AgentLineage`
       fallback) — the same predicate `IdentityData`'s manage affordances
       already use;
    2. MANAGES — the caller's live-loaded caps
       (`Ezagent.EntityCaps.load/1`, live-first like
       `workspace_visible?/2`) satisfy the SAME instance-scoped Manage
       gate `Ezagent.Domain.Agent.read_config/3` enforces
       (`cap(:agent, Manage, :read_cascade)` — satisfied by the
       creator's at-create `:any`-action Manage cap, an explicit manage
       grant, or the ws-admin wildcard) — checked ONLY through the
       sanctioned `Ezagent.Identity.caps_authorize?/2` chokepoint, never
       a hand-rolled cap match (invariant p3);
    3. VISIBLE TO WORKSPACE MEMBERS — the agent is itself a DECLARED
       member of the workspace (the existing rule: workspace membership,
       the same membership disjunct SPEC
       2026-05-27-workspace-cap-based-visibility §3.3(a) grants
       principals, applied to the agent row) AND — F2, read-plane PR-4
       rework — the CALLER is itself a declared workspace member. A
       declared member agent is part of the workspace's shared roster,
       visible to the workspace's members only; an undeclared agent is
       private to its owner/managers. Keying the disjunct on the
       CALLER's membership closes the bypass where a principal holding
       any one narrow workspace-scoped cap (which admits the workspace
       into their `list_workspaces_for/2` visible set) could read the
       WHOLE shared roster without any relationship to it.

  Fail-closed: a nil/malformed/unauthorized caller, a non-workspace
  scope, or an unavailable agent-listing facade all return `[]`.
  """
  @spec agents(URI.t() | term(), URI.t() | term()) :: [URI.t()]
  def agents(caller, workspace_uri)

  def agents(%URI{} = caller, %URI{scheme: "workspace"} = workspace_uri) do
    with :ok <- authorize_workspace(caller, workspace_uri),
         {:ok, scoped} <- workspace_scoped_agents(workspace_uri) do
      members = workspace_member_uris(workspace_uri)
      caller_is_member = caller_declared_member?(caller, members)
      Enum.filter(scoped, &agent_visible_to?(caller, &1, members, caller_is_member))
    else
      _ -> []
    end
  end

  def agents(_caller, _workspace_uri), do: []

  @doc """
  Is `caller` authorized for workspace-scoped LIST reads in
  `workspace_uri`?

  This is the SAME workspace-level gate `sessions/2` and `agents/2`
  apply BEFORE any read (well-formed identity principal AND the
  workspace inside the caller's cap-derived visible set). Exposed so the
  sibling caller-authorizing list chokepoints
  (`Ezagent.Workspace.UserReads`, `Ezagent.Session.TemplateReads`) reuse
  the one predicate instead of copy-pasting a security boundary.
  """
  @spec authorized_workspace?(URI.t() | term(), URI.t() | term()) :: boolean()
  def authorized_workspace?(caller, workspace_uri) do
    authorize_workspace(caller, workspace_uri) == :ok
  end

  @doc """
  Is `caller` a DECLARED member of `workspace_uri` (present in the
  workspace store's member list)?

  A point check (NOT an enumeration) — the caller's own membership, the
  same fact `agents/2` computes once per call to gate the shared-roster
  disjunct (F2). Read live from the workspace store on every call.
  """
  @spec declared_member?(URI.t() | term(), URI.t() | term()) :: boolean()
  def declared_member?(%URI{} = caller, %URI{scheme: "workspace"} = workspace_uri) do
    caller_declared_member?(caller, workspace_member_uris(workspace_uri))
  end

  def declared_member?(_caller, _workspace_uri), do: false

  # ----- workspace authorization (BEFORE any read) ----------------------

  defp authorize_workspace(%URI{} = caller, %URI{} = workspace_uri) do
    if Ezagent.URI.bare_principal?(caller) and workspace_visible?(caller, workspace_uri) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  # The caller's cap-derived workspace view (SPEC §3.3 — admin shortcut ∪
  # membership ∪ cap-scope) must contain the workspace; everyone else is
  # denied. Caps are loaded live so a fresh grant is seen immediately.
  defp workspace_visible?(%URI{} = caller, %URI{} = workspace_uri) do
    target = URI.to_string(workspace_uri)

    caller
    |> Ezagent.EntityCaps.load()
    |> then(&Listing.list_workspaces_for(caller, &1))
    |> Enum.any?(fn ws -> uri_string(Map.get(ws, :uri)) == target end)
  rescue
    _ -> false
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(_), do: nil

  # ----- workspace-scoped base listing (runtime DI — see moduledoc) -----

  defp workspace_scoped_sessions(%URI{} = workspace_uri, %URI{} = caller) do
    facade = session_listing_facade()

    if Code.ensure_loaded?(facade) and
         function_exported?(facade, :list_persisted_sessions, 1) and
         function_exported?(facade, :list_sessions, 2) do
      {:ok,
       {facade.list_persisted_sessions(workspace_uri),
        facade.list_sessions(workspace_uri, caller)}}
    else
      {:error, {:session_listing_unavailable, facade}}
    end
  end

  defp session_listing_facade do
    Application.get_env(
      :ezagent_domain_workspace,
      :session_listing_facade,
      EzagentDomainInstanceMessage
    )
  end

  # ----- per-row visibility (owner/member OR public) --------------------

  defp visible_to?(%URI{} = caller, %URI{} = session_uri, member_visible) do
    MapSet.member?(member_visible, Ezagent.URI.canonical!(session_uri)) or
      member_or_owner?(caller, session_uri) or public_session?(session_uri)
  end

  # F6 (read-plane PR-4 rework) — the membership predicate facade is a
  # REQUIRED dependency of `sessions/2`: resolve and validate it BEFORE
  # the base listing is fetched/filtered. Unavailable → the whole read
  # fails closed to `[]` at the `with` — we do NOT fall through to the
  # independent public-session predicate (a public row is not a
  # substitute for the membership check). A down `PublicView` facade is
  # NOT required: it only means no public rows are added.
  defp session_reads_available? do
    facade = session_reads_facade()

    if Code.ensure_loaded?(facade) and function_exported?(facade, :authorized?, 2) do
      :ok
    else
      {:error, {:session_reads_unavailable, facade}}
    end
  end

  # The SHARED live-first owner/member predicate from the conversation
  # read chokepoint — reused so row visibility here is byte-equivalent to
  # the conversation-plane gate by construction.
  defp member_or_owner?(%URI{} = caller, %URI{} = session_uri) do
    facade = session_reads_facade()

    Code.ensure_loaded?(facade) and function_exported?(facade, :authorized?, 2) and
      facade.authorized?(caller, session_uri)
  end

  defp session_reads_facade do
    Application.get_env(
      :ezagent_domain_workspace,
      :session_reads_facade,
      Ezagent.Socialware.SessionReads
    )
  end

  defp public_session?(%URI{} = session_uri) do
    facade = public_view_facade()

    Code.ensure_loaded?(facade) and function_exported?(facade, :web_anon_access?, 1) and
      facade.web_anon_access?(session_uri)
  end

  defp public_view_facade do
    Application.get_env(
      :ezagent_domain_workspace,
      :public_view_facade,
      Ezagent.Socialware.PublicView
    )
  end

  # ----- workspace-scoped agent base listing ----------------------------

  # `Ezagent.Entity.Agent.list_in_workspace/1` — the EXISTING
  # snapshot-sourced (live AND dormant), tenant-bounded agent enumerator
  # (membership-cap unification R1.4). It sits BELOW this domain (a
  # declared dep of `ezagent_domain_workspace`), so the DI indirection is
  # NOT cycle-breaking — it gives tests the same fake-facade seam as
  # `session_listing_facade/0` and keeps the fail-closed shape identical.
  defp workspace_scoped_agents(%URI{} = workspace_uri) do
    facade = agent_listing_facade()

    if Code.ensure_loaded?(facade) and function_exported?(facade, :list_in_workspace, 1) do
      {:ok, facade.list_in_workspace(workspace_uri)}
    else
      {:error, {:agent_listing_unavailable, facade}}
    end
  end

  defp agent_listing_facade do
    Application.get_env(
      :ezagent_domain_workspace,
      :agent_listing_facade,
      Ezagent.Entity.Agent
    )
  end

  # ----- per-row agent visibility (owns OR manages OR shared roster) --

  # F2 (read-plane PR-4 rework): the shared-roster disjunct is gated on
  # the CALLER's declared workspace membership (`caller_is_member`,
  # computed ONCE per `agents/2` call) — never on the agent's own
  # membership alone. Owns/manages disjuncts are unchanged: an owner or
  # manager sees their agent WITHOUT needing workspace membership.
  defp agent_visible_to?(%URI{} = caller, %URI{} = agent_uri, members, caller_is_member) do
    owns_agent?(caller, agent_uri) or manages_agent?(caller, agent_uri) or
      (caller_is_member and declared_workspace_member?(agent_uri, members))
  end

  # A malformed row is never visible (fail closed).
  defp agent_visible_to?(_caller, _row, _members, _caller_is_member), do: false

  # The CALLER's own declared membership (F2). Same membership fact as
  # `declared_workspace_member?/2`, named for the caller side so the
  # per-row predicate reads as the caller→workspace relationship it is.
  defp caller_declared_member?(%URI{} = caller, members) when is_list(members) do
    declared_workspace_member?(caller, members)
  end

  defp caller_declared_member?(_caller, _members), do: false

  # OWNS — the caller is the agent's creator per the existing data-owner
  # rule. `data_owner/1` never raises on a cold/unknown agent (the
  # live-slice miss falls through to the lineage lookup); the rescue is
  # belt-and-braces fail-closed.
  defp owns_agent?(%URI{} = caller, %URI{} = agent_uri) do
    case Ezagent.ActionSet.ApiKeys.data_owner(agent_uri) do
      %URI{} = owner -> uri_string(owner) == URI.to_string(caller)
      _ -> false
    end
  rescue
    _ -> false
  end

  # MANAGES — the caller's live-loaded caps satisfy the SAME needed-cap
  # shape `Ezagent.Domain.Agent.read_config/3` +
  # `read_credential_status/3` enforce (`cap(:agent, Manage,
  # :read_cascade)`, instance-scoped): the creator's at-create `:any`
  # Manage cap, an explicit manage grant, and the ws-admin wildcard all
  # match. REUSED via `Ezagent.Identity.caps_authorize?/2` — the
  # sanctioned chokepoint owner; no cap-shape is ever re-inspected here.
  defp manages_agent?(%URI{} = caller, %URI{} = agent_uri) do
    needed = %{
      kind: :agent,
      behavior: Ezagent.ActionSet.Manage,
      action: :read_cascade,
      instance: Ezagent.URI.instance(agent_uri),
      workspace_uri: Ezagent.Capability.workspace_of(agent_uri)
    }

    caps = Ezagent.EntityCaps.load(caller)
    Ezagent.Identity.caps_authorize?(caller, caps, needed)
  rescue
    _ -> false
  end

  # VISIBLE TO WORKSPACE MEMBERS — the existing rule: an agent DECLARED a
  # member of the workspace is visible to the workspace's members (the
  # §3.3(a) membership disjunct, applied to the agent row).
  defp declared_workspace_member?(%URI{} = agent_uri, members) when is_list(members) do
    target = URI.to_string(agent_uri)
    Enum.any?(members, fn member -> uri_string(member) == target end)
  end

  # The workspace's declared member URIs, read ONCE per `agents/2` call
  # (not per row) from the workspace store — this module IS the
  # store-owner tier for the workspace plane (same as `Listing`).
  defp workspace_member_uris(%URI{} = workspace_uri) do
    with {:ok, name} <- Ezagent.URI.name(workspace_uri),
         %{} = ws <- Ezagent.Workspace.Store.get_by_name(name) do
      Map.get(ws, :members, [])
    else
      _ -> []
    end
  rescue
    _ -> []
  end
end
