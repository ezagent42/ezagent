defmodule EzagentPluginLiveview.Admin.OrchestratorRestart do
  @moduledoc """
  Orchestrator restart action + flash text for AdminLive — extracted
  verbatim from `EzagentPluginLiveview.AdminLive` (#25 Phase-3, PR-3Q).

  `flash_text/1` derives the orchestrator-status flash from session
  metadata; `restart/3` runs the §6 atomicity REPAIR
  (`EzagentDomainInstanceMessage.repair_orchestrator/2`) and returns the
  `{:noreply, socket}` the `handle_event` clause expects. The
  `OrchestratorAdmin :restart` cap is checked by the caller's
  `handle_event` clause before this runs.
  """

  import Phoenix.Component, only: [assign: 3]
  use Gettext, backend: EzagentPluginLiveview.Gettext

  alias EzagentPluginLiveview.Admin.SessionContext

  @doc """
  Flash text for an orchestrator status in session `meta`, or `nil` when
  there is nothing to surface (`:ready`, plain `:no_orchestrator`
  sessions, or non-failure states).
  """
  def flash_text(meta) when is_map(meta) do
    case Map.get(meta, :orchestrator_status) do
      :ready ->
        nil

      :failed ->
        reason = Map.get(meta, :orchestrator_error)

        # `:no_orchestrator` (plain session) is NOT an error — suppress.
        if reason == :no_orchestrator do
          nil
        else
          gettext("Orchestrator failed: %{reason}; click Restart to retry.",
            reason: inspect(reason)
          )
        end

      _ ->
        nil
    end
  end

  def flash_text(_), do: nil

  @doc """
  Restart (REPAIR) the orchestrator for `session_uri`. Returns
  `{:noreply, socket}` with the session context re-classified on success
  or the appropriate `:orchestrator_flash_error` on failure.
  """
  def restart(socket, health, session_uri) do
    # 2026-05-31 orchestrator-startup-atomicity §6 — Restart is now a
    # REPAIR. The old path dispatched `template.instantiate` + respawned
    # the PTY but NEVER set `orchestrator_template_uri` (OTU), so it could
    # not fix the nil-OTU sessions (`main`, `orch-feishu-7429`) that were
    # the whole reason for the SPEC. `EzagentDomainInstanceMessage.repair_orchestrator/2`
    # RE-MATERIALIZES the OTU from the session's template THEN runs the §5
    # atomic readiness gate (cap grants + MCP registration + member join).
    # The OrchestratorAdmin :restart cap was already checked in the
    # `handle_event` clause above.
    result = EzagentDomainInstanceMessage.repair_orchestrator(session_uri, health.workspace_uri)

    case result do
      {:ok, ^session_uri, _meta} ->
        # Re-classify; success path lands `:alive` (or a new `:crashed`
        # if the fresh worker died immediately — itself a useful signal).
        {:noreply,
         socket
         |> SessionContext.assign_session_context(session_uri)
         |> assign(:orchestrator_flash_error, nil)}

      {:error, :unauthorized} ->
        {:noreply,
         assign(
           socket,
           :orchestrator_flash_error,
           gettext("Unauthorized — you may not restart this orchestrator.")
         )}

      {:error, :cross_workspace_denied} ->
        {:noreply,
         assign(
           socket,
           :orchestrator_flash_error,
           gettext(
             "Cross-workspace denied — orchestrator lives in workspace %{workspace}.",
             workspace: URI.to_string(health.workspace_uri)
           )
         )}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :orchestrator_flash_error,
           gettext("Restart failed: %{reason}", reason: inspect(reason))
         )}
    end
  end
end
