defmodule EzagentPluginLiveview.AgentDetailLive do
  @moduledoc """
  Phase 5 PR 3: per-agent PTY status detail at `/identities/agents/:uri`.

  Path segment is URI-encoded `entity://agent/...`. Auto-refresh every 2s
  so operator sees stdout flowing without a manual reload.

  Restart button stops the PtyServer; DynamicSupervisor restarts it
  per `:permanent` restart spec.

  Phase 8c PR-H — inline `style=""` violations replaced with
  `EzagentDomainUi` atoms + Tailwind tokens so a future Tailwind theme
  swap can't break this page.
  """
  use Phoenix.LiveView
  alias EzagentDomainUi.IdeShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  @impl true
  def mount(%{"uri" => encoded_uri}, _session, socket) do
    case parse_agent_uri(encoded_uri) do
      {:ok, agent_uri} ->
        if connected?(socket) do
          # 2-second polling matches operator scan rate without
          # hammering :sys.get_state on a busy PTY.
          :timer.send_interval(2000, :refresh)
        end

        {:ok,
         socket
         |> assign(:not_found, false)
         |> assign(:agent_uri, agent_uri)
         |> assign(:flash_error, nil)
         |> assign(:status, load_status(agent_uri))
         |> assign(:bridge_entry, load_bridge_entry(agent_uri))}

      _ ->
        {:ok, assign(socket, :not_found, true) |> assign(:bad_uri, encoded_uri)}
    end
  end

  # PR #141 + #145: entity:// scheme; agent URIs are entity://agent/<flavor>_<name>.
  defp parse_agent_uri(encoded) do
    decoded = URI.decode_www_form(encoded)

    case URI.new(decoded) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> name} = uri}
      when is_binary(name) and name != "" ->
        {:ok, uri}

      _ ->
        :error
    end
  end

  # V1 acceptance fix (2026-05-21) — per ezagent-developer skill
  # invariant 8: Domain UI MUST NOT import Plugin module functions.
  # Domain.Agent.lifecycle_status/1 is the sanctioned facade — it
  # pattern-matches the agent flavor and dispatches to the owning
  # plugin's lifecycle helper internally. Response shape:
  # %{phase: :alive | :registered | :not_found | ..., flavor: String.t() | nil, detail: map() | nil}.
  defp load_status(agent_uri) do
    Ezagent.Domain.Agent.lifecycle_status(agent_uri)
  end

  # Phase 8b §1.10 — CC Bridges (v2) panel moved here from admin_live.
  # Per-agent so the operator can see "is this agent's WS bridge live?"
  # while looking at the agent's other status data. Returns `nil` if
  # the BridgeRegistry has no entry for this agent (most likely cause:
  # PtyServer is running but the Python MCP bridge inside claude
  # hasn't connected back via `/cc_socket` yet, or has disconnected).
  defp load_bridge_entry(agent_uri) do
    if Code.ensure_loaded?(EzagentPluginCc.BridgeRegistry) do
      EzagentPluginCc.BridgeRegistry.list_connected()
      |> Enum.find(fn {uri, _entry} ->
        URI.to_string(uri) == URI.to_string(agent_uri)
      end)
      |> case do
        {_uri, entry} -> entry
        nil -> nil
      end
    else
      nil
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply,
     socket
     |> assign(:status, load_status(socket.assigns.agent_uri))
     |> assign(:bridge_entry, load_bridge_entry(socket.assigns.agent_uri))}
  end

  @impl true
  def handle_event("restart", _params, socket) do
    # cc-specific operation — restart is currently only meaningful for
    # cc-flavored agents (it restarts the PtyServer). Other flavors
    # won't surface the Restart button in render/1. Direct plugin
    # reference here is the documented exception per invariant 8:
    # there's no domain-wide "restart agent" abstraction yet (V2
    # work — see Lifecycle Behavior contract in v2-feedback-log).
    case Ezagent.Domain.Pty.lookup(socket.assigns.agent_uri) do
      {:ok, pid} ->
        # Supervisor terminates → restart via :permanent restart spec.
        # GenServer.stop(:normal) would suppress restart; use :shutdown
        # to signal "restart-please, no crash logged".
        Process.exit(pid, :shutdown)

        # Allow restart to settle before re-reading.
        Process.send_after(self(), :refresh, 500)

        {:noreply,
         socket
         |> assign(:status, %{phase: :not_found, flavor: "cc", detail: nil})
         |> assign(:flash_error, nil)}

      :error ->
        {:noreply, assign(socket, :flash_error, "no live PtyServer for this agent")}
    end
  end

  @impl true
  def render(%{not_found: true} = assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <IdeShell.ide_shell
      current_entity_uri={@current_entity_uri_str}
      current_path="/identities/agents"
      status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
    >
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title="Agent URI invalid" />
          <p>
            <code>{@bad_uri}</code>
          </p>
          <p>
            <a href="/identities/agents" class="text-blue-600 dark:text-blue-400 hover:text-blue-700">
              ← Agents
            </a>
          </p>
        </div>
      </:main_window>
    </IdeShell.ide_shell>
    """
  end

  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <IdeShell.ide_shell
      current_entity_uri={@current_entity_uri_str}
      current_path="/identities/agents"
      status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
    >
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title={"Agent: " <> URI.to_string(@agent_uri)}>
            <:subtitle>
              <a href="/identities/agents" class="text-blue-600 dark:text-blue-400 hover:text-blue-700">
                ← Agents
              </a>
              <span class="ml-4 text-zinc-500">auto-refresh every 2s</span>
            </:subtitle>
          </.page_header>

          <p :if={@flash_error} class="text-rose-600 dark:text-rose-400 text-xs mt-3">
            {@flash_error}
          </p>

          <%!-- V1 acceptance fix (2026-05-21) — new status shape:
               %{phase: :alive | :registered | :not_found | :error,
                 flavor: String.t() | nil, detail: map() | nil}
               per Ezagent.Domain.Agent. --%>
          <%= cond do %>
            <% @status.phase in [:not_found, :registered] -> %>
              <.card class="mt-6">
                <h2 class="text-sm text-rose-600 dark:text-rose-400 font-medium mb-2">
                  {phase_header(@status.phase)}
                </h2>
                <p class="text-xs">
                  {phase_help_text(@status, @agent_uri)}
                </p>
              </.card>
            <% @status.phase == :alive and @status.flavor == "cc" -> %>
              <% s = @status.detail %>
              <.card class="mt-6">
                <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">
                  Running (cc)
                </h2>
                <table class="w-full text-xs">
                  <tbody>
                    <tr>
                      <td class="py-0.5 w-52 text-zinc-500">os_pid</td>
                      <td class="font-mono">{s.os_pid || "—"}</td>
                    </tr>
                    <tr>
                      <td class="py-0.5 text-zinc-500">cwd</td>
                      <td class="font-mono text-[11px]">{s.cwd}</td>
                    </tr>
                    <tr>
                      <td class="py-0.5 text-zinc-500">running</td>
                      <td class={
                        if s.running,
                          do: "text-emerald-600 dark:text-emerald-400 font-semibold",
                          else: "text-rose-600 dark:text-rose-400"
                      }>
                        {if s.running, do: "yes", else: "no"}
                      </td>
                    </tr>
                    <tr>
                      <td class="py-0.5 text-zinc-500">test_mode</td>
                      <td>{s.test_mode}</td>
                    </tr>
                    <tr>
                      <td class="py-0.5 text-zinc-500">auto_prompts</td>
                      <td>
                        <%= for p <- s.auto_prompts || [] do %>
                          <span class={
                            if p.fired?,
                              do: "text-emerald-600 dark:text-emerald-400 mr-2",
                              else: "text-zinc-500 mr-2"
                          }>
                            {p.name}: {if p.fired?, do: "fired", else: "waiting"}
                          </span>
                        <% end %>
                      </td>
                    </tr>
                    <tr>
                      <td class="py-0.5 text-zinc-500">buffer_bytes</td>
                      <td>{s.buffer_bytes}</td>
                    </tr>
                  </tbody>
                </table>

                <div class="mt-3 flex gap-2">
                  <a
                    href="/sessions"
                    class="inline-flex items-center justify-center px-3.5 py-1.5 rounded-md text-xs font-medium bg-emerald-600 text-emerald-50 hover:bg-emerald-700 dark:hover:bg-emerald-500 shadow-sm no-underline"
                  >📺 Open terminal (in Sessions)</a>
                  <.button
                    variant="outline"
                    size="sm"
                    type="button"
                    phx-click="restart"
                    id="restart-btn"
                    class="text-rose-600 dark:text-rose-400 border-rose-600 dark:border-rose-400 hover:bg-rose-50 dark:hover:bg-rose-950"
                    data-confirm="Restart PtyServer for this agent? (supervisor will respawn)"
                  >Restart</.button>
                </div>
              </.card>

              <%!-- Phase 8b §1.10 — CC Bridges (v2) panel relocated from admin_live --%>
              <.card id="cc-bridge-panel" class="mt-6">
                <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">CC Bridge (v2)</h2>
                <p :if={is_nil(@bridge_entry)} class="text-xs text-zinc-500">
                  No WS bridge connected for this agent. Local-pty agents only need a bridge if
                  the Python sidecar is configured to mount <code>/cc_socket</code>.
                </p>
                <table :if={@bridge_entry} class="w-full text-xs">
                  <tbody>
                    <tr>
                      <td class="py-0.5 w-52 text-zinc-500">status</td>
                      <td class="text-emerald-600 dark:text-emerald-400 font-semibold">connected</td>
                    </tr>
                    <tr>
                      <td class="py-0.5 text-zinc-500">connected_at</td>
                      <td class="text-zinc-500">{DateTime.to_iso8601(@bridge_entry.connected_at)}</td>
                    </tr>
                    <tr>
                      <td class="py-0.5 text-zinc-500">client</td>
                      <td class="font-mono text-[11px]">{client_label(@bridge_entry)}</td>
                    </tr>
                  </tbody>
                </table>
              </.card>

              <.card :if={is_map(s) and Map.get(s, :recent_output, []) != []} class="mt-6 bg-zinc-900 dark:bg-zinc-950 border-zinc-700 dark:border-zinc-800">
                <h2 class="text-sm font-medium mb-2 text-zinc-200">Recent PTY output (last 50 lines)</h2>
                <pre class="font-mono text-[11px] whitespace-pre-wrap m-0 max-h-[360px] overflow-y-auto text-zinc-200"><%= for line <- s.recent_output do %>{line}
<% end %></pre>
              </.card>
            <% @status.phase == :alive -> %>
              <%!-- echo / curl / other flavors — Kind alive, no
                   PTY/bridge layer to introspect. --%>
              <.card class="mt-6">
                <h2 class="text-sm font-medium mb-2 text-emerald-600 dark:text-emerald-400">
                  Running ({@status.flavor || "unknown flavor"})
                </h2>
                <p class="text-xs text-zinc-500">
                  Agent Kind is alive. This flavor has no PTY/bridge layer to introspect.
                </p>
              </.card>
            <% true -> %>
              <%!-- :error or any other phase --%>
              <.card class="mt-6">
                <h2 class="text-sm font-medium mb-2 text-rose-600 dark:text-rose-400">
                  Status error
                </h2>
                <p class="text-xs">{inspect(@status.detail)}</p>
              </.card>
          <% end %>
        </div>
      </:main_window>
    </IdeShell.ide_shell>
    """
  end

  # Phase 8b §1.10 — CC Bridges client_label helper. Mirrors the shape
  # the admin_live debug_panel used before relocation.
  defp client_label(%{info: %{claude_info: %{"name" => name, "version" => v}}}),
    do: "#{name} #{v}"

  defp client_label(%{info: %{claude_info: %{"name" => name}}}), do: name
  defp client_label(_), do: "—"

  # V1 acceptance fix (2026-05-21) — header text for non-running
  # lifecycle phases. "Not running" matches the pre-fix wording the
  # operator already knows.
  defp phase_header(:not_found), do: "Not running"
  defp phase_header(:registered), do: "Registered (not yet instantiated)"
  defp phase_header(other), do: to_string(other)

  defp phase_help_text(%{phase: :not_found}, _agent_uri) do
    "No Kind registered at this URI. If you just clicked Restart, wait a moment. " <>
      "Otherwise, add a cc.agent template for this agent_uri in a Workspace."
  end

  defp phase_help_text(%{phase: :registered, detail: %{note: note}}, _agent_uri)
       when is_binary(note) do
    "Agent Kind alive but lifecycle helper says: #{note}. For cc agents this usually " <>
      "means the PtyServer hasn't started yet (boot race or instantiate failed)."
  end

  defp phase_help_text(%{phase: :registered}, _agent_uri) do
    "Agent Kind alive but the deeper lifecycle layer is not running yet."
  end

  defp phase_help_text(_status, _agent_uri), do: ""
end
