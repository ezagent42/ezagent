defmodule EzagentPluginLiveview.CommandPaletteComponent do
  @moduledoc """
  V1 UI PR-2 (SPEC §2.5) — CmdK command palette as a `Phoenix.LiveComponent`.

  The `command_palette/1` function component in `ide_shell.ex` was a
  complete modal markup with no behavior — no JS open-trigger, no event
  handlers, no data source. This LiveComponent is the live home for
  CmdK: open-state, query, results, and the four event handlers all
  live HERE, in ONE place, so every `ide_shell` LV that renders it
  gets a working palette without duplicating handlers.

  ## phx-target={@myself} on EVERY binding (SPEC §2.5 — BLOCKER)

  Every event binding in `render/1` carries `phx-target={@myself}`.
  Without it, `phx-change` / `phx-click` / `phx-window-keydown` route
  to the PARENT LiveView, which has no matching `handle_event/3` →
  crash or silent no-op. The component owns its events only because
  every binding is targeted at `@myself`.

  ## Canonical events (SPEC §2.5)

  | Event        | Trigger                          | Effect |
  |--------------|----------------------------------|--------|
  | `cmdk_open`  | global JS push (`app.js`, §2.4)  | open the modal |
  | `cmdk_close` | overlay click / Esc              | close the modal |
  | `cmdk_query` | search input `phx-change`        | re-rank results |
  | `cmdk_select`| result row `phx-click` + `phx-value-key` | navigate |

  ## Data flow (SPEC §2.2 / §2.3)

  - **Nav results** — `@nav_routes` is delivered DOWN from the
    `ezagent_web` `on_mount` assign (`:cmdk_nav_routes`). The
    component never calls `EzagentWeb.Router`.
  - **Entity / session results** — built from
    `Ezagent.UI.UriOptions.entities_and_sessions/2`, the same
    workspace-scoped, caller-authorized enrichment layer `uri_picker`
    uses.

  Both are mapped into `Ezagent.UI.CommandSource.result()` shape and
  ranked by the pure `CommandSource.search/2`. The component holds a
  `%{key => result}` map (`:result_index`) so `cmdk_select` is an O(1)
  lookup.

  ## Open-trigger (SPEC §2.4)

  The open behavior is app-global, so the trigger is plain global JS in
  `app.js` (NOT a `phx-hook` — a hook needs a mount-point element).
  The component's root `<div>` carries a `data-cmdk-open` attribute
  holding a serialized `JS.push("cmdk_open", target: @myself)`. The
  `app.js` listener for `ezagent:open-command-palette` (and the ⌘K
  keybinding) reads that attribute off `#cmdk` and `execJS`-es it —
  routing `cmdk_open` to THIS component regardless of which LV hosts
  it. Esc-to-close stays on the component's `phx-window-keydown`.

  ## V1 scope (SPEC §2.6)

  Nav + entity results only. Action results (Source 3) are V2 — this
  component surfaces no `BehaviorRegistry` actions.
  """

  use Phoenix.LiveComponent

  alias Ezagent.UI.{CommandSource, UriOptions}
  alias EzagentDomainUi.Primitives

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:candidates, [])
     |> assign(:result_index, %{})}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Rebuild candidates whenever the parent re-renders the component
    # (workspace switch, nav-route change). Keeping this in update/2
    # means the candidate set tracks the current workspace without a
    # per-keystroke rebuild — `cmdk_query` only re-ranks.
    candidates = build_candidates(socket.assigns)

    {:ok,
     socket
     |> assign(:candidates, candidates)
     |> assign(:result_index, Map.new(candidates, &{&1.key, &1}))
     |> assign(:results, CommandSource.search(socket.assigns.query, candidates))}
  end

  @impl true
  def handle_event("cmdk_open", _params, socket) do
    {:noreply,
     socket
     |> assign(:open, true)
     |> assign(:query, "")
     |> assign(:results, CommandSource.search("", socket.assigns.candidates))}
  end

  def handle_event("cmdk_close", _params, socket) do
    {:noreply, assign(socket, :open, false)}
  end

  def handle_event("cmdk_query", %{"q" => query}, socket) when is_binary(query) do
    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:results, CommandSource.search(query, socket.assigns.candidates))}
  end

  def handle_event("cmdk_query", _params, socket), do: {:noreply, socket}

  def handle_event("cmdk_select", %{"key" => key}, socket) do
    case Map.fetch(socket.assigns.result_index, key) do
      # V1: both :nav and :entity results navigate to `target`. The
      # branch exists so V2 :action results slot in without reshaping
      # this clause.
      {:ok, %{kind: kind, target: target}} when kind in [:nav, :entity] ->
        {:noreply,
         socket
         |> assign(:open, false)
         |> push_navigate(to: target)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cmdk_select", _params, socket), do: {:noreply, socket}

  # --- candidate assembly ----------------------------------------------------

  # Map nav routes + entity/session options into CommandSource.result()
  # shape. Nav routes arrive enriched (label/path/icon/group) from the
  # ezagent_web on_mount assign; entity options arrive from UriOptions.
  defp build_candidates(assigns) do
    nav_results(Map.get(assigns, :nav_routes, [])) ++
      entity_results(
        Map.get(assigns, :current_entity_uri),
        Map.get(assigns, :current_workspace_uri)
      )
  end

  defp nav_results(nav_routes) when is_list(nav_routes) do
    Enum.map(nav_routes, fn route ->
      %{
        key: "nav:" <> route.path,
        kind: :nav,
        label: route.label,
        target: route.path,
        icon: route.icon,
        group: route.group
      }
    end)
  end

  defp nav_results(_), do: []

  # SPEC §2.2 target-URL contract:
  #   entity://agent/... → /identities/agents/<url-encoded-uri>
  #   entity://user/...  → /identities  (no per-user detail route)
  #   session://...      → /sessions?session=<url-encoded-uri>
  defp entity_results(caller_uri, workspace_uri)
       when not is_nil(caller_uri) and not is_nil(workspace_uri) do
    caller_uri
    |> UriOptions.entities_and_sessions(workspace_uri)
    |> Enum.map(fn option ->
      %{
        key: "entity:" <> option.uri,
        kind: :entity,
        label: option.label,
        target: entity_target(option),
        icon: entity_icon(option),
        group: entity_group(option)
      }
    end)
  end

  defp entity_results(_caller_uri, _workspace_uri), do: []

  defp entity_target(%{kind: :session, uri: uri}),
    do: "/sessions?session=" <> URI.encode_www_form(uri)

  defp entity_target(%{kind: :entity, flavor: flavor, uri: uri}) when is_binary(flavor),
    do: "/identities/agents/" <> URI.encode_www_form(uri)

  # entity://user/... — no per-user detail route exists; land on the
  # Identities list (SPEC §2.2).
  defp entity_target(%{kind: :entity, uri: _uri}), do: "/identities"

  defp entity_icon(%{kind: :session}), do: "message-square"
  defp entity_icon(%{kind: :entity}), do: "users"
  defp entity_icon(_), do: "dot"

  defp entity_group(%{kind: :session}), do: "Sessions"
  defp entity_group(%{kind: :entity}), do: "Entities"
  defp entity_group(_), do: "Entities"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      data-cmdk-open={Phoenix.LiveView.JS.push("cmdk_open", target: @myself)}
      class={[
        "fixed inset-0 z-50 flex items-start justify-center pt-20",
        not @open && "hidden"
      ]}
      phx-window-keydown="cmdk_close"
      phx-key="escape"
      phx-target={@myself}
    >
      <div
        class="absolute inset-0 bg-zinc-900/40 backdrop-blur-sm"
        phx-click="cmdk_close"
        phx-target={@myself}
      />
      <div class="relative z-10 w-full max-w-xl mx-4 bg-white dark:bg-zinc-900 rounded-lg shadow-2xl overflow-hidden">
        <form phx-change="cmdk_query" phx-submit="cmdk_query" phx-target={@myself}>
          <input
            type="text"
            name="q"
            value={@query}
            placeholder="搜索 sessions / entities ..."
            autocomplete="off"
            autofocus
            class="w-full px-4 py-3 text-sm bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 border-b border-zinc-200 dark:border-zinc-800 focus:outline-none"
          />
        </form>
        <div class="max-h-96 overflow-y-auto">
          <div
            :if={@results == []}
            class="px-4 py-8 text-center text-xs text-zinc-500 dark:text-zinc-400"
          >
            {(@query == "" && "输入开始搜索") || "没有结果"}
          </div>
          <button
            :for={r <- @results}
            type="button"
            phx-click="cmdk_select"
            phx-value-key={r.key}
            phx-target={@myself}
            class="w-full px-4 py-2 text-left text-xs text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 flex items-center gap-2 border-b border-zinc-100 dark:border-zinc-900"
          >
            <Primitives.icon name={r.icon || "dot"} size="xs" />
            <span class="font-mono">{r.label}</span>
            <span
              :if={r.group}
              class="ml-auto text-[10px] text-zinc-400 dark:text-zinc-600 uppercase"
            >
              {r.group}
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
