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

  Domain.Pty PR-D (2026-05-21) — per SPEC §5.3 the kludgy
  "Open terminal (in Sessions)" jump button is replaced with an
  INLINE collapsible terminal panel (`<details>` element). The panel
  is rendered ONLY when `Ezagent.Domain.Pty.alive?/1` returns true
  for this agent — per `feedback_ui_no_misleading_buttons` we don't
  surface terminal UI when there's nothing behind it. The panel also
  links to the standalone `/identities/agents/:uri/terminal`
  (TerminalLive) for full-window focus.

  Inline terminal event seam: `pty_input` keystrokes dispatch through
  `?action=pty.write`; `pty_resize` is a no-op (TUI manages its own
  resize server-side); `{:pty_output, _, chunk}` PubSub messages are
  forwarded to xterm via `push_event "pty_chunk"`.
  """
  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  alias EzagentDomainUi.Pty.Terminal
  alias EzagentDomainUi.Pty.TerminalSeam
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

          # Domain.Pty — subscribe to this agent's PTY output stream
          # via the shared `TerminalSeam` (the ONE seam reused by
          # TerminalLive + AdminLive) so the inline terminal (when
          # expanded by the operator) can render fresh chunks.
          # Subscription is cheap even when the `<details>` is
          # collapsed; if PTY isn't alive the topic has no broadcaster.
          TerminalSeam.subscribe(agent_uri)
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

    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the `:error` failure contract.
    try do
      case Ezagent.URI.parse!(decoded) do
        %URI{scheme: "entity", host: "agent", path: "/" <> name} = uri
        when is_binary(name) and name != "" ->
          {:ok, uri}

        _ ->
          :error
      end
    rescue
      ArgumentError -> :error
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

  # PTY-backed agent flavors expose non-empty detail through the
  # Domain.Agent lifecycle facade. Keep the UI behavior-driven so new
  # PTY-backed flavors inherit the terminal surface without another
  # flavor string gate here.
  defp status_has_pty_detail?(%{phase: :alive, detail: detail}) when is_map(detail),
    do: map_size(detail) > 0

  defp status_has_pty_detail?(_status), do: false

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

  # Domain.Pty — fan-out PTY stdout/stderr chunks from the
  # `Ezagent.Domain.Pty.Server` PubSub broadcast through to xterm via
  # the shared `TerminalSeam`. The xterm hook in
  # `EzagentDomainUi.Pty.Terminal.mount/1` listens for `pty_chunk`.
  def handle_info({:pty_output, _agent_uri, chunk}, socket) when is_binary(chunk) do
    {:noreply, TerminalSeam.push_chunk(socket, chunk)}
  end

  @impl true
  def handle_event("restart", _params, socket) do
    # V-2 fix (audit 2026-05-23) — restart now routes through
    # `Ezagent.Behavior.Lifecycle` `:terminate` dispatch instead of a
    # direct `Process.exit/2` on a PtyServer pid. This restores all
    # three principles the old path bypassed:
    #
    #   - P14 (dispatch is the only path) — `Invocation.dispatch/1`
    #   - P15 (cap check) — step 5.5 enforces caller cap on the
    #     `?action=lifecycle.terminate` target URI
    #   - P22 (audit) — telemetry handler `cast`s an audit row async
    #
    # The Agent Kind's supervisor uses the `:permanent` restart spec, so
    # terminating the worker brings it back automatically — the operator
    # observes a brief "Restarting..." then the fresh status. The actual
    # `DynamicSupervisor.terminate_child` is scheduled in a detached
    # Task by `Behavior.Lifecycle` so the dispatch reply wins the race
    # (the Behavior runs INSIDE the target's GenServer).
    target =
      URI.new!(URI.to_string(socket.assigns.agent_uri) <> "?action=lifecycle.terminate")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: lifecycle_ctx(socket)
         }) do
      {:ok, _} ->
        # Allow supervisor restart to settle before re-reading the status
        # (Behavior.Lifecycle schedules termination with a 20ms yield, then
        # supervisor restart is sub-100ms; 500ms is a safe operator-visible
        # refresh window — same as the pre-V-2 path).
        Process.send_after(self(), :refresh, 500)

        {:noreply,
         socket
         |> assign(:status, %{phase: :not_found, flavor: status_flavor(socket), detail: nil})
         |> assign(:flash_error, nil)}

      {:error, :unauthorized} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext(
             "Restart denied — your account lacks the lifecycle.terminate cap on this agent."
           )
         )}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("Restart failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # Domain.Pty — inline terminal keystroke seam, via the shared
  # `TerminalSeam` (the ONE seam reused by `EzagentPluginLiveview.AdminLive`
  # and `TerminalLive`). The xterm hook pushes `pty_input` per keystroke.
  def handle_event("pty_input", %{"bytes" => bytes}, socket) when is_binary(bytes) do
    case TerminalSeam.dispatch_input(socket.assigns.agent_uri, bytes, pty_ctx(socket)) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_error, TerminalSeam.input_error_message(reason))}
    end
  end

  # TUI manages its own resize on the server side via :exec.winsz/3 —
  # matches admin_live convention. Kept as a handler so the hook's
  # pushEvent doesn't generate `[unhandled]` warnings.
  def handle_event("pty_resize", _params, socket), do: {:noreply, socket}

  # SPEC caps-cleanup-v1 §4.4 — admin caps now live in the User
  # Kind's slice (seeded by SystemPrincipal at boot); no special
  # admin branch needed. Anonymous mount falls back to
  # `system://lv-anon-mount` (empty caps).
  defp pty_ctx(socket) do
    {caller, caps} = resolve_caller(socket)
    %{caller: caller, caps: caps, reply: :ignore}
  end

  # Builds the dispatch ctx for `:lifecycle.terminate`. Same caller
  # resolution as `pty_ctx/1`; reply mode differs.
  defp lifecycle_ctx(socket) do
    {caller, caps} = resolve_caller(socket)
    %{caller: caller, caps: caps, reply: :sync}
  end

  defp resolve_caller(socket) do
    case socket.assigns[:current_entity_uri] do
      nil ->
        {Ezagent.SystemPrincipal.uri("lv-anon-mount"),
         Ezagent.SystemPrincipal.caps("system://lv-anon-mount")}

      caller ->
        {caller, Ezagent.Identity.list_caps_for(caller)}
    end
  end

  # Preserve flavor in the optimistic post-restart status so the LV doesn't
  # flicker "unknown flavor" between the dispatch and the next :refresh.
  defp status_flavor(socket) do
    case Map.get(socket.assigns, :status) do
      %{flavor: f} when is_binary(f) -> f
      _ -> nil
    end
  end

  @impl true
  def render(%{not_found: true} = assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || Ezagent.URI.parse!("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspace_name={@workspace_name}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri_str}
          current_path="/identities/agents"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title={gettext("Agent URI invalid")} />
          <p>
            <code>{@bad_uri}</code>
          </p>
          <p>
            <a href="/identities/agents" class="text-blue-600 dark:text-blue-400 hover:text-blue-700">
              ← {gettext("Agents")}
            </a>
          </p>
        </div>
      </:main_window>

        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || Ezagent.URI.parse!("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspace_name={@workspace_name}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri_str}
          current_path="/identities/agents"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title={gettext("Agent: %{uri}", uri: URI.to_string(@agent_uri))}>
            <:subtitle>
              <a href="/identities/agents" class="text-blue-600 dark:text-blue-400 hover:text-blue-700">
                ← {gettext("Agents")}
              </a>
              <span class="ml-4 text-zinc-500">{gettext("auto-refresh every 2s")}</span>
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
            <% status_has_pty_detail?(@status) -> %>
              <% s = @status.detail %>
              <.card class="mt-6">
                <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">
                  {gettext("Running (%{flavor})", flavor: @status.flavor || gettext("unknown flavor"))}
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
                        {if s.running, do: gettext("yes"), else: gettext("no")}
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
                            {p.name}: {if p.fired?, do: gettext("fired"), else: gettext("waiting")}
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
                  <.button
                    variant="outline"
                    size="sm"
                    type="button"
                    phx-click="restart"
                    id="restart-btn"
                    class="text-rose-600 dark:text-rose-400 border-rose-600 dark:border-rose-400 hover:bg-rose-50 dark:hover:bg-rose-950"
                    data-confirm={gettext("Restart PtyServer for this agent? (supervisor will respawn)")}
                  >{gettext("Restart")}</.button>
                </div>
              </.card>

              <%!-- Domain.Pty PR-D (2026-05-21) — inline terminal panel.
                   Replaces the previous "Open terminal (in Sessions)"
                   jump (kludgy — chat panel competing for focus). Only
                   rendered when PTY is alive (per `feedback_ui_no_misleading_buttons`
                   we don't show "Terminal" UI when there's nothing
                   behind it). Collapsed `<details>` so the terminal
                   doesn't take focus when the operator just wanted to
                   eyeball status. --%>
              <.card :if={Ezagent.Domain.Pty.alive?(@agent_uri)} id="agent-inline-terminal" class="mt-6">
                <details class="text-zinc-900 dark:text-zinc-100">
                  <summary class="cursor-pointer text-sm font-medium select-none">
                    {gettext("Terminal")}
                    <span class="ml-2 text-xs text-zinc-500 dark:text-zinc-400">
                      {gettext("(click to expand · live PTY)")}
                    </span>
                  </summary>
                  <div class="mt-3 space-y-2">
                    <div class="text-xs">
                      <a
                        href={"/identities/agents/" <> URI.encode_www_form(URI.to_string(@agent_uri)) <> "/terminal"}
                        class="text-blue-600 dark:text-blue-400 hover:text-blue-700 no-underline"
                      >
                        {gettext("Open in full page")} →
                      </a>
                    </div>
                    <%!-- The ONE unified terminal panel — same component
                         the standalone TerminalLive page and the :pty
                         SessionView render. Inline surface → header
                         omitted (the `<details>` summary already labels
                         it) + a fixed height so it sits in the card. --%>
                    <div class="rounded-md overflow-hidden">
                      <Terminal.panel agent_uri={@agent_uri} header={:none} class="h-[420px]" />
                    </div>
                  </div>
                </details>
              </.card>

              <%!-- Phase 8b §1.10 — CC Bridges (v2) panel relocated from admin_live --%>
              <.card id="cc-bridge-panel" class="mt-6">
                <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">{gettext("CC Bridge (v2)")}</h2>
                <p :if={is_nil(@bridge_entry)} class="text-xs text-zinc-500">
                  {gettext(
                    "No WS bridge connected for this agent. Local-pty agents only need a bridge if the Python sidecar is configured to mount /cc_socket."
                  )}
                </p>
                <table :if={@bridge_entry} class="w-full text-xs">
                  <tbody>
                    <tr>
                      <td class="py-0.5 w-52 text-zinc-500">status</td>
                      <td class="text-emerald-600 dark:text-emerald-400 font-semibold">{gettext("connected")}</td>
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
                <h2 class="text-sm font-medium mb-2 text-zinc-200">{gettext("Recent PTY output (last 50 lines)")}</h2>
                <pre class="font-mono text-[11px] whitespace-pre-wrap m-0 max-h-[360px] overflow-y-auto text-zinc-200">{Enum.join(s.recent_output, "\n")}</pre>
              </.card>
            <% @status.phase == :alive -> %>
              <%!-- echo / curl / other flavors — Kind alive, no
                   PTY/bridge layer to introspect. --%>
              <.card class="mt-6">
                <h2 class="text-sm font-medium mb-2 text-emerald-600 dark:text-emerald-400">
                  {gettext("Running (%{flavor})", flavor: @status.flavor || gettext("unknown flavor"))}
                </h2>
                <p class="text-xs text-zinc-500">
                  {gettext("Agent Kind is alive. This flavor has no PTY/bridge layer to introspect.")}
                </p>
              </.card>
            <% true -> %>
              <%!-- :error or any other phase --%>
              <.card class="mt-6">
                <h2 class="text-sm font-medium mb-2 text-rose-600 dark:text-rose-400">
                  {gettext("Status error")}
                </h2>
                <p class="text-xs">{inspect(@status.detail)}</p>
              </.card>
          <% end %>
        </div>
      </:main_window>

        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
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
  defp phase_header(:not_found), do: gettext("Not running")
  defp phase_header(:registered), do: gettext("Registered (not yet instantiated)")
  defp phase_header(other), do: to_string(other)

  defp phase_help_text(%{phase: :not_found}, _agent_uri) do
    gettext(
      "No Kind registered at this URI. If you just clicked Restart, wait a moment. Otherwise, add a cc.agent template for this agent_uri in a Workspace."
    )
  end

  defp phase_help_text(%{phase: :registered, detail: %{note: note}}, _agent_uri)
       when is_binary(note) do
    gettext(
      "Agent Kind alive but lifecycle helper says: %{note}. For cc agents this usually means the PtyServer hasn't started yet (boot race or instantiate failed).",
      note: note
    )
  end

  defp phase_help_text(%{phase: :registered}, _agent_uri) do
    gettext("Agent Kind alive but the deeper lifecycle layer is not running yet.")
  end

  defp phase_help_text(_status, _agent_uri), do: ""
end
