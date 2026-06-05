defmodule EzagentWeb.WorkspaceSwitchController do
  @moduledoc """
  Workspace switcher endpoint — Phase 9 PR-8 (SPEC v3 §6.4 amendment 3
  + §13.2).

  Permission-gated branching, NOT always-logout. The user's membership
  in `workspace://system` determines the UX:

  - **System member** → context swap. `:current_workspace_uri` is
    updated to the target while `:current_entity_uri` stays as
    `entity://user/system/admin`. The §6.5 invariant
    (`current_workspace_uri == entity_workspace_uri(current_entity_uri)`)
    is intentionally relaxed for system members per §13.2.
  - **Regular user** → denial page. Shows a "Sign in to <ws>" prompt
    that POSTs to /logout?return_to=/login?workspace=<ws>, so the
    decision to lose the current session is conscious.
  - **No-op when already in target workspace** → just redirect back
    to /sessions.
  - **Regular user → any other workspace** → denial page (see
    `do_switch/3` cond). This subsumes the former
    "hidden target" branch: post-SPEC 2026-05-27-workspace-cap-based-visibility,
    `workspace://system` is no longer flagged by a field; a regular
    user attempting to switch to it lands on the denial page like
    any other cross-workspace attempt.

  Note: the system-member branch is the SECOND sanctioned writer of
  `:current_workspace_uri` outside `SessionPrincipal.put/3` (the
  first). The §6.5 invariant test allows this controller path
  explicitly.
  """
  use EzagentWeb, :controller

  def switch(conn, %{"workspace" => target_workspace})
      when is_binary(target_workspace) and target_workspace != "" do
    current_entity_uri = get_session(conn, :current_entity_uri)

    case Ezagent.Workspace.Store.get_by_name(target_workspace) do
      nil ->
        conn
        |> put_flash(
          :error,
          gettext("Unknown workspace: %{name}", name: target_workspace)
        )
        |> redirect(to: ~p"/sessions")

      workspace ->
        # SPEC 2026-05-27-workspace-cap-based-visibility — the former
        # `%{visible: false}` early-exit clause is GONE (field
        # deleted). Regular users attempting to switch to
        # `workspace://system` (or any workspace they don't belong
        # to) hit the denial branch in `do_switch/3`'s `cond`. System
        # members context-swap into `workspace://system` via the
        # first branch.
        do_switch(conn, workspace, current_entity_uri)
    end
  end

  def switch(conn, _params) do
    conn
    |> put_flash(:error, gettext("Missing workspace parameter."))
    |> redirect(to: ~p"/sessions")
  end

  defp do_switch(conn, workspace, current_entity_uri)
       when is_binary(current_entity_uri) do
    caller_uri = Ezagent.URI.new!(current_entity_uri)
    caller_workspace = Ezagent.URI.entity_workspace_uri(caller_uri)
    target_uri = Ezagent.URI.workspace(workspace.name)

    cond do
      Ezagent.URI.name?(caller_workspace, :system) ->
        # System-member context swap — SPEC §13.2. Keep
        # :current_entity_uri (admin stays admin); swap workspace
        # slot. This is the SECOND sanctioned writer for the
        # workspace slot — see session_principal_test.exs allow list.
        conn
        |> put_session(:current_workspace_uri, URI.to_string(target_uri))
        |> put_flash(
          :info,
          gettext("Operating on workspace %{name}", name: workspace.name)
        )
        |> redirect(to: ~p"/sessions")

      URI.to_string(caller_workspace) == URI.to_string(target_uri) ->
        # Already in this workspace — no-op.
        redirect(conn, to: ~p"/sessions")

      true ->
        # Regular user trying to switch to a different workspace —
        # render the denial page (SPEC §6.4 amendment 3). User must
        # consciously choose to log out + re-auth via the "Sign in to
        # <ws>" link.
        conn
        |> put_view(EzagentWeb.WorkspaceSwitchHTML)
        |> render("denied.html",
          target_workspace: workspace.name,
          caller_uri: current_entity_uri
        )
    end
  end

  defp do_switch(conn, _workspace, _no_session) do
    # No current session at all — bounce to login.
    redirect(conn, to: "/login")
  end
end
