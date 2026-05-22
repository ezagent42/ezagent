defmodule EzagentPluginLiveview.TerminalLive do
  @moduledoc """
  Domain.Pty PR-D (2026-05-21) — standalone PTY terminal page for an
  agent.

  URL: `/identities/agents/:uri/terminal` (sibling to
  `/identities/agents/:uri/caps` and `/:uri/api-keys`). Per SPEC §10
  decision 2 + §13 the route is resource-first; the LV's `:uri` path
  segment carries a URL-encoded canonical entity URI string.

  ## Lifecycle integration (SPEC §6)

  `Ezagent.Domain.Agent.lifecycle_status/1` is the sanctioned facade.
  Render branches by `status.phase`:

    * `:alive` — render the xterm.js terminal (component owned by
      `EzagentDomainUi.Pty.Terminal`).
    * `:registered` — Kind alive but no `PtyServer`; show "Not yet
      started" with a brief explanation.
    * `:not_found` — friendly 404 "Agent doesn't exist".

  ## Bridge pattern (SPEC §13)

  Same `parse_agent_uri/1` shape as `AgentDetailLive`/`EntityCapsLive`:
  URL-decode → `URI.new/1` → pattern-match on `entity://agent/...`.
  Once mounted, only the `%URI{}` struct flows through the LV.

  ## PTY data plumbing

  The xterm hook (`phx-hook="PtyTerminal"`) lives in
  `EzagentDomainUi.Pty.Terminal`; the host LV owns the event seam:

    * `pty_input` (xterm → LV) → `?action=pty.write` dispatch
    * `pty_resize` (xterm → LV) → currently a no-op (TUI handles its
      own resize via `:exec.winsz/3` on the server; matches admin_live)
    * `{:pty_output, agent_uri, chunk}` (Server PubSub → LV) →
      `push_event(socket, "pty_chunk", %{bytes: chunk})` (xterm renders)

  Mount also asks `Ezagent.Domain.Pty.Server.snapshot_buffer/1` for the
  current buffer and pushes it as an initial `pty_chunk` so a fresh
  page load shows the existing screen state immediately (ttyd-style;
  same fix as PR #128).
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component
  alias EzagentDomainUi.Pty.Terminal
  alias EzagentDomainUi.Pty.TerminalSeam

  @refresh_ms 2_000

  @impl true
  def mount(%{"uri" => encoded_uri}, _session, socket) do
    case parse_agent_uri(encoded_uri) do
      {:ok, agent_uri} ->
        if connected?(socket) do
          # Subscribe to the agent's PTY output stream via the shared
          # `TerminalSeam` — the ONE seam reused by AgentDetailLive +
          # AdminLive so the subscribe/replay/fan-out plumbing isn't
          # copy-pasted.
          TerminalSeam.subscribe(agent_uri)

          # 2s polling matches AgentDetailLive — gives the operator
          # immediate feedback when the PTY phase changes (e.g. they
          # just clicked "instantiate" elsewhere).
          :timer.send_interval(@refresh_ms, :refresh)
        end

        socket =
          socket
          |> assign(:agent_uri, agent_uri)
          |> assign(:status, load_status(agent_uri))
          |> assign(:pty_alive?, Ezagent.Domain.Pty.alive?(agent_uri))
          |> assign(:refresh_seconds, div(@refresh_ms, 1000))

        # ttyd-style initial buffer replay — only meaningful when the
        # PtyServer is alive. `TerminalSeam.push_initial_buffer/2`
        # returns the socket unchanged if no server exists for this URI.
        socket =
          if connected?(socket) do
            TerminalSeam.push_initial_buffer(socket, agent_uri)
          else
            socket
          end

        {:ok, socket}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Invalid agent URI"))
         |> push_navigate(to: "/identities")}
    end
  end

  defp parse_agent_uri(encoded) do
    decoded = URI.decode_www_form(encoded)

    case URI.new(decoded) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest} = uri}
      when is_binary(rest) and rest != "" ->
        {:ok, uri}

      _ ->
        :error
    end
  end

  defp load_status(agent_uri) do
    Ezagent.Domain.Agent.lifecycle_status(agent_uri)
  end

  @impl true
  def handle_info(:refresh, socket) do
    agent_uri = socket.assigns.agent_uri

    {:noreply,
     socket
     |> assign(:status, load_status(agent_uri))
     |> assign(:pty_alive?, Ezagent.Domain.Pty.alive?(agent_uri))}
  end

  # PTY chunk fan-out from the Server's PubSub broadcast — via the
  # shared TerminalSeam.
  def handle_info({:pty_output, _agent_uri, chunk}, socket) when is_binary(chunk) do
    {:noreply, TerminalSeam.push_chunk(socket, chunk)}
  end

  @impl true
  def handle_event("pty_input", %{"bytes" => bytes}, socket) when is_binary(bytes) do
    case TerminalSeam.dispatch_input(socket.assigns.agent_uri, bytes, ctx(socket)) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, TerminalSeam.input_error_message(reason))}
    end
  end

  # No-op — TUI handles its own resize on the server side via :exec.winsz/3.
  # Matches the admin_live convention.
  def handle_event("pty_resize", _params, socket), do: {:noreply, socket}

  # Caller context for dispatch — pulls caps from the live session.
  defp ctx(socket) do
    caller = socket.assigns[:current_entity_uri] || Ezagent.Entity.User.admin_uri()

    caps =
      if URI.to_string(caller) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
        Ezagent.Entity.User.admin_caps()
      else
        Ezagent.Identity.list_caps_for(caller)
      end

    %{caller: caller, caps: caps, reply: :ignore}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(
          Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin")
        )
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri_str}
          current_path={current_path(@agent_uri)}
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
      <:main_window>
        <div class="h-full flex flex-col bg-zinc-50 dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100">
          <div class="px-4 py-3 border-b border-zinc-200 dark:border-zinc-800 flex items-center justify-between shrink-0">
            <div class="flex items-center gap-3 min-w-0">
              <a
                href={"/identities/agents/" <> URI.encode_www_form(URI.to_string(@agent_uri))}
                class="text-xs text-blue-600 dark:text-blue-400 hover:text-blue-700 no-underline shrink-0"
              >
                ← {gettext("Agent")}
              </a>
              <span class="text-sm font-mono text-zinc-700 dark:text-zinc-300 truncate">
                {URI.to_string(@agent_uri)}
              </span>
            </div>
            <div class="text-xs text-zinc-500 dark:text-zinc-400 shrink-0">
              {gettext("Phase:")}
              <span class={phase_class(@status.phase)}>
                <span class="font-mono">{@status.phase}</span>
              </span>
            </div>
          </div>

          <%= cond do %>
            <% @status.phase == :alive and @pty_alive? -> %>
              <%!-- The ONE unified terminal panel — same component
                   the inline AgentDetailLive panel and the :pty
                   SessionView render. Full-page surface → header
                   omitted (this LV already shows the agent URI in its
                   own toolbar above) + `flex-1` to fill the window. --%>
              <Terminal.panel agent_uri={@agent_uri} header={:none} class="flex-1 min-h-0" />
            <% @status.phase in [:registered, :alive] -> %>
              <%!-- :registered = cc kind alive but PtyServer not yet
                   up; :alive without pty = echo/curl/etc. — Kind is up
                   but there's no PTY for this flavor. Both surface the
                   same "no terminal here" UX rather than showing a
                   misleading empty xterm. --%>
              <div class="flex-1 flex items-center justify-center p-8">
                <div class="text-center max-w-md">
                  <h2 class="text-base font-medium text-zinc-700 dark:text-zinc-200 mb-2">
                    {gettext("Terminal not available")}
                  </h2>
                  <p class="text-sm text-zinc-500 dark:text-zinc-400">
                    {pty_unavailable_help(@status.flavor)}
                    {gettext("Auto-refreshing every %{seconds}s.", seconds: @refresh_seconds)}
                  </p>
                </div>
              </div>
            <% true -> %>
              <div class="flex-1 flex items-center justify-center p-8">
                <div class="text-center max-w-md">
                  <h2 class="text-base font-medium text-zinc-700 dark:text-zinc-200 mb-2">
                    {gettext("Agent not found")}
                  </h2>
                  <p class="text-sm text-zinc-500 dark:text-zinc-400">
                    {gettext("No Kind registered at this URI. Check that the agent URI is correct or instantiate the agent's template first.")}
                  </p>
                </div>
              </div>
          <% end %>
        </div>
      </:main_window>

        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  defp current_path(%URI{} = uri),
    do: "/identities/agents/" <> URI.encode_www_form(URI.to_string(uri)) <> "/terminal"

  defp phase_class(:alive), do: "text-emerald-600 dark:text-emerald-400"
  defp phase_class(:registered), do: "text-amber-600 dark:text-amber-400"
  defp phase_class(_), do: "text-rose-600 dark:text-rose-400"

  # Operator-facing help text — matches the flavor's actual lifecycle
  # so we explain "why no terminal" specifically rather than generic.
  defp pty_unavailable_help("cc"),
    do:
      gettext(
        "The PTY process for this cc agent isn't running yet. It will start when the agent's template is instantiated."
      )

  defp pty_unavailable_help(flavor) when flavor in ["echo", "curl"],
    do:
      gettext(
        "This flavor (%{flavor}) doesn't run under a PTY. Terminal view is only available for agents whose template starts a Ezagent.Domain.Pty.Server.",
        flavor: flavor
      )

  defp pty_unavailable_help(_),
    do:
      gettext(
        "This agent isn't backed by a Ezagent.Domain.Pty.Server. Terminal view requires a PTY-backed agent flavor."
      )
end
