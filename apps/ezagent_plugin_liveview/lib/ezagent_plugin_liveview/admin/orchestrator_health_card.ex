defmodule EzagentPluginLiveview.Admin.OrchestratorHealthCard do
  @moduledoc """
  Right pane: compact per-session orchestrator-instance health card.

  Sits above `MemberPanel` in the `/sessions` view-mode right sidebar.
  Replaces the cc-orchestrator template *seed* status shown on
  `/plugins` (system-level boot health) with the *per-session instance*
  health operators actually need when triaging.

  Stateless. Parent (`AdminLive`) computes the health value via
  `Ezagent.Orchestrator.Health.classify/1` and passes it in. The
  Restart button is gated on (a) status == `:crashed` AND (b) the
  caller holding an instantiate cap on the orchestrator template — the
  actual cap check happens at dispatch step 5.5, but we ALSO hide the
  button when no cap is held so the operator doesn't see a control
  they cannot use.

  ## Three status states

    * `:alive` — green badge, orchestrator URI clickable (links to the
      agent detail page).
    * `:crashed` — red badge, URI clickable, Restart button rendered.
    * `:not_spawned` — gray badge, URI rendered as plain text (no live
      agent page to navigate to).

  ## Restart action

  Fires `restart_orchestrator` phx-click with `phx-value-uri` carrying
  the orchestrator URI. `AdminLive.handle_event/3` dispatches
  `template://agent/<workspace>/cc-orchestrator?action=template.instantiate`
  with `instance_name: <derived>`. CapBAC step 5.5 enforces the caller
  has the `Behavior.Template :instantiate` cap on that template URI;
  on `:unauthorized` we surface the error via flash_error.
  """

  use Phoenix.Component

  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Primitives
  use EzagentDomainUi.Components

  attr :health, :map, required: true
  attr :can_restart?, :boolean, default: false
  attr :flash_error, :string, default: nil

  def orchestrator_health_card(assigns) do
    ~H"""
    <section
      id="orchestrator-health-card"
      class="m-3 mb-0 rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-3"
    >
      <div class="flex items-center justify-between mb-2">
        <h3 class="text-[10px] uppercase tracking-wide text-zinc-500">
          {gettext("Orchestrator")}
        </h3>
        <.status_badge status={@health.status} />
      </div>

      <%!-- Cap-denial surface for the Restart action (parent sets
            flash_error to a string when restart_orchestrator hits
            :unauthorized / :cross_workspace_denied). Pre-cleared on
            successful click. --%>
      <p
        :if={@flash_error}
        id="orchestrator-health-flash-error"
        role="alert"
        class="mb-2 text-[11px] text-rose-600 dark:text-rose-400"
      >
        {@flash_error}
      </p>

      <%!-- URI row. For :alive / :crashed we link to the agent detail
            page; for :not_spawned the entity doesn't exist so we render
            as plain mono text (no dead link). --%>
      <div class="font-mono text-[10px] text-zinc-500 dark:text-zinc-400 break-all leading-snug">
        <.link
          :if={@health.status in [:alive, :crashed]}
          id="orchestrator-health-uri-link"
          navigate={"/identities/agents/" <> URI.encode_www_form(URI.to_string(@health.uri))}
          class="text-blue-600 dark:text-blue-400 hover:text-blue-700 dark:hover:text-blue-300"
        >
          {URI.to_string(@health.uri)}
        </.link>
        <span :if={@health.status == :not_spawned} id="orchestrator-health-uri-text">
          {URI.to_string(@health.uri)}
        </span>
      </div>

      <%!-- Optional last-activity row (snapshot updated_at). Only shown
            when a snapshot exists — i.e. ever spawned (alive after
            restart, or crashed). --%>
      <p
        :if={@health.snapshot_updated_at}
        class="mt-1 text-[10px] text-zinc-500 dark:text-zinc-400"
      >
        {gettext("last activity")}:
        <span class="font-mono">{DateTime.to_iso8601(@health.snapshot_updated_at)}</span>
      </p>

      <%!-- Restart button — :crashed only, AND only when the caller
            holds a cap that would let the dispatch through. CapBAC
            still runs at step 5.5; this guard is purely so the
            operator doesn't see a button that always fails. --%>
      <div :if={@health.status == :crashed and @can_restart?} class="mt-2">
        <.button
          type="button"
          variant="primary"
          size="sm"
          phx-click="restart_orchestrator"
          phx-value-uri={URI.to_string(@health.uri)}
          id="restart-orchestrator-button"
        >
          <.icon name="refresh" size="xs" class="mr-1" /> {gettext("Restart orchestrator")}
        </.button>
      </div>
    </section>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(%{status: :alive} = assigns) do
    ~H"""
    <.badge variant="success" class="text-[10px]">{gettext("alive")}</.badge>
    """
  end

  defp status_badge(%{status: :crashed} = assigns) do
    ~H"""
    <.badge variant="danger" class="text-[10px]">{gettext("crashed")}</.badge>
    """
  end

  defp status_badge(%{status: :not_spawned} = assigns) do
    ~H"""
    <.badge variant="default" class="text-[10px]">{gettext("not spawned")}</.badge>
    """
  end
end
