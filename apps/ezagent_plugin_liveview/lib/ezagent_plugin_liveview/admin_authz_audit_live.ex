defmodule EzagentPluginLiveview.AdminAuthzAuditLive do
  @moduledoc """
  `/admin/audit/authz` — live stream of CapBAC `:granted` / `:denied`
  events.

  Design 2 from `docs/notes/caps-e2e-design.md` §5: makes the cap
  system viscerally visible. Operator sees every cap check fire in
  real time — answers Allen's "我其实没有太感受到当前 caps 有什么
  作用" by SHOWING caps working.

  ## Mechanism

  Mount attaches `:telemetry` handlers for `[:ezagent, :authz,
  :granted]` + `[:ezagent, :authz, :denied]` events emitted by
  `Ezagent.Kind.Runtime.authz_check/4` (dispatch step 5.5).
  Handler `send`s the meta to the LV pid; `handle_info/2` prepends
  to a bounded stream (default 100 events).

  Auto-detaches on terminate (handler IDs are per-pid).

  ## Admin gate

  Same `@is_admin?` pattern as other admin LVs.

  ## Limitations

  - In-memory only; events lost on LV close
  - One handler per LV — operator opening multiple tabs creates
    independent streams (no global ring buffer)
  - Telemetry handlers run in-process with the emitter; a slow
    `send` could in theory back up dispatch. In practice `send` is
    cheap (mailbox is local).
  """

  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  @max_events 100

  @impl true
  def mount(_params, _session, socket) do
    if Map.get(socket.assigns, :is_admin?) do
      if connected?(socket) do
        handler_id_granted = "authz-audit-granted-#{inspect(self())}"
        handler_id_denied = "authz-audit-denied-#{inspect(self())}"

        :telemetry.attach(
          handler_id_granted,
          [:ezagent, :authz, :granted],
          &__MODULE__.on_authz_event/4,
          {self(), :granted}
        )

        :telemetry.attach(
          handler_id_denied,
          [:ezagent, :authz, :denied],
          &__MODULE__.on_authz_event/4,
          {self(), :denied}
        )

        {:ok,
         socket
         |> assign(:events, [])
         |> assign(:filter, "all")
         |> assign(:handler_ids, [handler_id_granted, handler_id_denied])}
      else
        {:ok,
         socket
         |> assign(:events, [])
         |> assign(:filter, "all")
         |> assign(:handler_ids, [])}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Admin Authz Audit is restricted to admin entities."))
       |> push_navigate(to: "/sessions")}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    for h <- Map.get(socket.assigns, :handler_ids, []) do
      :telemetry.detach(h)
    end

    :ok
  end

  # ----- Telemetry handler (runs in emitter's process) -----------------------

  def on_authz_event(_event_name, _measurements, meta, {target_pid, result}) do
    send(target_pid, {:authz_event, result, meta, DateTime.utc_now()})
  end

  @impl true
  def handle_info({:authz_event, result, meta, ts}, socket) do
    new_event = %{
      ts: ts,
      result: result,
      caller: Map.get(meta, :caller),
      kind_module: Map.get(meta, :kind_module),
      action: Map.get(meta, :action),
      target: Map.get(meta, :target),
      needed: Map.get(meta, :needed)
    }

    events =
      [new_event | socket.assigns.events]
      |> Enum.take(@max_events)

    {:noreply, assign(socket, :events, events)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", %{"filter" => f}, socket) do
    {:noreply, assign(socket, :filter, f)}
  end

  def handle_event("clear", _, socket) do
    {:noreply, assign(socket, :events, [])}
  end

  # ----- Render --------------------------------------------------------------

  defp visible(events, "all"), do: events
  defp visible(events, "granted"), do: Enum.filter(events, &(&1.result == :granted))
  defp visible(events, "denied"), do: Enum.filter(events, &(&1.result == :denied))

  defp fmt(%URI{} = u), do: URI.to_string(u)
  defp fmt(nil), do: "(system)"
  defp fmt(other), do: inspect(other)

  defp fmt_action(nil), do: "(nil)"
  defp fmt_action(a) when is_atom(a), do: ":" <> Atom.to_string(a)
  defp fmt_action(a), do: inspect(a)

  defp fmt_kind(nil), do: "(nil)"
  defp fmt_kind(mod) when is_atom(mod), do: inspect(mod)
  defp fmt_kind(other), do: inspect(other)

  defp result_badge(:granted),
    do: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200"

  defp result_badge(:denied), do: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visible_events, visible(assigns.events, assigns.filter))
      |> assign(:max_events, @max_events)

    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(
          Map.get(assigns, :current_entity_uri) || Ezagent.URI.parse!("entity://user/system/admin")
        )
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:admin}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={Map.get(assigns, :current_workspace_uri)}
      workspaces={Map.get(assigns, :workspaces, [])}
      workspace_name={Map.get(assigns, :workspace_name)}
      is_admin?={Map.get(assigns, :is_admin?, false)}
      is_system_member?={Map.get(assigns, :is_system_member?, false)}
      cmdk_nav_routes={Map.get(assigns, :cmdk_nav_routes, [])}
    >
      <:body>
        <AdminShell.admin_shell current_path="/admin/audit/authz" active_section={:authz_audit}>
          <:main>
            <div class="px-6 py-6 max-w-7xl mx-auto">
              <header class="mb-6">
                <h1 class="text-xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-100">
                  {gettext("Capability authz audit")}
                </h1>
                <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
                  {gettext(
                    "Live stream of every CapBAC check fired by Invocation.dispatch/1 step 5.5. Last %{n} events.",
                    n: @max_events
                  )}
                </p>
              </header>

              <.flash_group flash={@flash} />

              <div class="flex items-center justify-between mb-3">
                <div class="flex items-center gap-2">
                  <form phx-change="filter">
                    <select
                      name="filter"
                      class="text-xs font-mono px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900"
                    >
                      <option value="all" selected={@filter == "all"}>all ({length(@events)})</option>
                      <option value="granted" selected={@filter == "granted"}>
                        granted ({Enum.count(@events, &(&1.result == :granted))})
                      </option>
                      <option value="denied" selected={@filter == "denied"}>
                        denied ({Enum.count(@events, &(&1.result == :denied))})
                      </option>
                    </select>
                  </form>
                </div>

                <button
                  phx-click="clear"
                  class="text-xs font-mono px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900 hover:bg-zinc-100 dark:hover:bg-zinc-800"
                >
                  {gettext("Clear")}
                </button>
              </div>

              <div
                :if={@visible_events == []}
                class="text-sm italic text-zinc-500 text-center py-8 border border-dashed border-zinc-200 dark:border-zinc-800 rounded"
              >
                {gettext(
                  "No events yet. Trigger an action in another tab — every Invocation.dispatch/1 will appear here."
                )}
              </div>

              <table :if={@visible_events != []} class="w-full text-xs border-collapse">
                <thead>
                  <tr class="border-b border-zinc-300 dark:border-zinc-700 text-left uppercase tracking-wider text-zinc-500">
                    <th class="py-2 px-2 font-medium">Time</th>
                    <th class="py-2 px-2 font-medium">Result</th>
                    <th class="py-2 px-2 font-medium">Caller</th>
                    <th class="py-2 px-2 font-medium">Kind</th>
                    <th class="py-2 px-2 font-medium">Action</th>
                    <th class="py-2 px-2 font-medium">Target</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={e <- @visible_events}
                    class="border-b border-zinc-100 dark:border-zinc-800 hover:bg-zinc-50 dark:hover:bg-zinc-900"
                  >
                    <td class="py-1 px-2 font-mono text-[10px] text-zinc-500">
                      {Calendar.strftime(e.ts, "%H:%M:%S")}
                    </td>
                    <td class="py-1 px-2">
                      <span class={[
                        "inline-block px-1.5 py-0.5 text-[10px] font-mono rounded uppercase",
                        result_badge(e.result)
                      ]}>
                        {e.result}
                      </span>
                    </td>
                    <td class="py-1 px-2 font-mono break-all">{fmt(e.caller)}</td>
                    <td class="py-1 px-2 font-mono">{fmt_kind(e.kind_module)}</td>
                    <td class="py-1 px-2 font-mono">{fmt_action(e.action)}</td>
                    <td class="py-1 px-2 font-mono break-all">{fmt(e.target)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
