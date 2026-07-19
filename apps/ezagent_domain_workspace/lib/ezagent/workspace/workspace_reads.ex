defmodule Ezagent.Workspace.WorkspaceReads do
  @moduledoc """
  The single caller-authorizing read chokepoint for a workspace's session
  LIST.

  ## Why this exists

  Workspace session-list reads were caller-less:
  `EzagentDomainInstanceMessage.list_sessions(workspace_uri)` filters the
  global registry by workspace ONLY, so any caller who could name a
  workspace enumerated EVERY session in it — including private sessions
  they were never a member of (an existence leak). `WorkspaceReads` is the
  chokepoint, modelled on `Ezagent.Socialware.SessionReads` (the
  conversation-plane read chokepoint): every principal-facing workspace
  session-LIST read routes through here, is authorized FIRST, and only
  then touches the listing.

  ## Contract (binding)

  `sessions/2` takes `caller` FIRST and authorizes BEFORE any read:

    1. WORKSPACE authorization — `caller` must be a well-formed identity
       principal (`Ezagent.URI.bare_principal?/1`) AND the workspace must
       be inside the caller's cap-derived visible set
       (`Ezagent.Workspace.Listing.list_workspaces_for/2`, the SAME
       SPEC 2026-05-27-workspace-cap-based-visibility §3.3 predicate the
       web surfaces use). Any failure → `[]` (fail closed) — never a
       degraded workspace-only listing.
    2. PER-ROW visibility — from the workspace-scoped listing a session
       row is kept ONLY when the caller may see it: the caller is an
       owner/member of the session (the shared live-first
       `SessionReads.authorized?/2` predicate — REUSED, never copied; a
       security boundary must not be copy-pasted), OR the session is
       public (`PublicView.web_anon_access?/1`).

  ## Dependency direction (runtime DI)

  The workspace domain sits BELOW the session/socialware domains
  (`ezagent_domain_session` depends on `ezagent_domain_workspace`, never
  the reverse — a compile-time reference would be a cycle), so the
  session-side listing + predicates are resolved at RUNTIME via
  `Application` env DI — the same pattern as
  `Ezagent.Workspace.Provisioning.resolve_session_facade/0` — guarded by
  `Code.ensure_loaded?/1` + `function_exported?/3`. An unavailable facade
  fails CLOSED (`[]`).
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
         {:ok, scoped} <- workspace_scoped_sessions(workspace_uri) do
      Enum.filter(scoped, &visible_to?(caller, &1))
    else
      _ -> []
    end
  end

  def sessions(_caller, _workspace_uri), do: []

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

  defp workspace_scoped_sessions(%URI{} = workspace_uri) do
    facade = session_listing_facade()

    if Code.ensure_loaded?(facade) and function_exported?(facade, :list_sessions, 1) do
      {:ok, facade.list_sessions(workspace_uri)}
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

  defp visible_to?(%URI{} = caller, %URI{} = session_uri) do
    member_or_owner?(caller, session_uri) or public_session?(session_uri)
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
end
