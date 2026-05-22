defmodule EzagentWeb.CommandRoutes do
  @moduledoc """
  V1 UI PR-2 (SPEC §2.2 Source 1) — palette-eligible navigation routes.

  The CmdK command palette's nav results are a projection of the
  Phoenix Router. Router routes are static (compile-time known) but a
  raw `%Phoenix.Router.Route{}` carries no human label — only a path,
  a verb, and the LV module. `command_routes/0` filters the router to
  the L1/L2 `live` pages (no path params) and attaches a curated
  `%{label, path, icon, group}` per route from a hand-maintained map
  keyed by path.

  ## Dependency-direction (SPEC §2.2 — BLOCKER fix)

  This module — and `command_routes/0` — live in `ezagent_web`, the
  TOP tier. `Ezagent.UI.CommandSource` (Tier-2 `ezagent_domain_ui`)
  and `EzagentPluginLiveview.CommandPaletteComponent` (Tier-3
  `ezagent_plugin_liveview`) sit BELOW `ezagent_web` in the dependency
  graph and MUST NOT call `EzagentWeb.Router`.

  Nav data therefore flows DOWN only: `EzagentWeb.LiveAuth` installs an
  `on_mount` hook that calls `command_routes/0` and assigns
  `:cmdk_nav_routes` onto the socket; the LV inherits the assign and
  passes it into the LiveComponent. The component never reaches up.

  ## The curated map

  `@nav_catalog` is the single source of truth for which routes the
  palette surfaces and how they read. A `live` route whose path is NOT
  a key here is excluded — this is deliberate: it keeps deep / noisy
  routes (caps editors, per-entity detail pages) out of the palette
  and gives every surfaced route a hand-written label. Adding a new
  L1/L2 page to the palette is a one-line edit here.
  """

  @typedoc """
  An enriched nav route — what `command_routes/0` returns. Distinct
  from a raw `%Phoenix.Router.Route{}`: it carries the human-facing
  fields the palette renders.
  """
  @type nav_route :: %{
          label: String.t(),
          path: String.t(),
          icon: String.t(),
          group: String.t()
        }

  # Curated label/icon/group per palette-eligible path. Keys MUST be
  # parameter-free `live` route paths that exist in EzagentWeb.Router.
  # Icon names are the logical names EzagentDomainUi.Primitives.icon/1
  # understands (see its `heroicon_for/1` clauses).
  @nav_catalog %{
    "/sessions" => %{label: "Sessions", icon: "message-square", group: "Navigate"},
    "/identities" => %{label: "Identities", icon: "users", group: "Navigate"},
    "/identities/users" => %{label: "Users", icon: "users", group: "Navigate"},
    "/identities/agents" => %{label: "Agents", icon: "users", group: "Navigate"},
    "/routing" => %{label: "Routing", icon: "route", group: "Navigate"},
    "/plugins" => %{label: "Plugins", icon: "puzzle", group: "Navigate"},
    "/workspaces" => %{label: "Workspaces", icon: "dashboard", group: "Navigate"},
    "/profile" => %{label: "Profile", icon: "users", group: "Navigate"},
    "/admin" => %{label: "Admin dashboard", icon: "dashboard", group: "Admin"},
    "/admin/logs" => %{label: "Observability", icon: "activity", group: "Admin"},
    "/admin/registry" => %{label: "Registry", icon: "puzzle", group: "Admin"},
    "/admin/snapshots" => %{label: "Snapshots", icon: "folder", group: "Admin"},
    "/admin/settings" => %{label: "Settings", icon: "settings", group: "Admin"}
  }

  @doc """
  Palette-eligible nav routes — enriched, not raw route structs.

  Filters `EzagentWeb.Router.__routes__/0` to `GET` `live` routes
  without path params (L1/L2 pages), keeps only those present in the
  curated `@nav_catalog`, and merges in the curated
  `label`/`icon`/`group`. Sorted by group then label so the palette's
  initial (empty-query) ordering is stable.
  """
  @spec command_routes() :: [nav_route()]
  def command_routes do
    EzagentWeb.Router.__routes__()
    |> Enum.filter(&palette_eligible?/1)
    |> Enum.flat_map(&enrich/1)
    |> Enum.uniq_by(& &1.path)
    |> Enum.sort_by(&{&1.group, &1.label})
  end

  # A route is palette-eligible when it is a GET `live` route with a
  # static (parameter-free) path. `EzagentWeb.Router.__routes__/0`
  # yields plain maps (not `%Phoenix.Router.Route{}` structs) — `plug`
  # for a live route is `Phoenix.LiveView.Plug`; a path param appears
  # as a `:segment` in the path string.
  defp palette_eligible?(%{verb: :get, plug: Phoenix.LiveView.Plug, path: path}),
    do: is_binary(path) and not String.contains?(path, ":")

  defp palette_eligible?(_route), do: false

  # Attach the curated fields. A live route not in @nav_catalog is
  # dropped (returns []) — the catalog is the allowlist.
  defp enrich(%{path: path}) do
    case Map.fetch(@nav_catalog, path) do
      {:ok, meta} -> [Map.put(meta, :path, path)]
      :error -> []
    end
  end
end
