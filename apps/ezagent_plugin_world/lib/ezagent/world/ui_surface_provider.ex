defmodule Ezagent.World.UiSurfaceProvider do
  @moduledoc """
  The **World-side** plugin-UI-surface contract — the home for the Layer-2
  left-rail nav (`nav_surfaces/0`) and Layer-3 per-session conversation tabs
  (`session_tabs/0`) that a plugin contributes to the world shell.

  ## Why this lives in world, not core

  `nav_surfaces/0` / `session_tabs/0` are **World-UI concepts**: their ONLY
  consumer is the world shell (the left-rail sidebar entry + the per-session
  conversation tab). They are NOT part of the generic `Ezagent.Plugin` core
  contract — core is the transport/runtime tier and knows nothing about a
  sidebar (decision 2026-06-30, user choice (a)). So world owns the convention
  here; core's `Ezagent.Plugin` no longer carries these callbacks or their
  shape gate.

  `config_surface/0` (the `/plugins` config-page icon) STAYS on core
  `Ezagent.Plugin` — it is unrelated to this module.

  ## How a plugin contributes — duck-typed, no compile dep

  A plugin declares a surface by defining a plain public function
  `nav_surfaces/0` and/or `session_tabs/0` on its plugin-contract module. World
  reads them by **enumerating installed plugins** (`Ezagent.PluginRegistry.list_all/0`,
  the core plugin-IDENTITY catalog) and guarding each call with
  `function_exported?(plugin_module, :nav_surfaces, 0)` BEFORE invoking — an
  absent function simply contributes nothing ("没装就没入口"). This keeps a
  plugin's compile graph free of any `ezagent_plugin_world` dependency (world is
  the UI host that sits ABOVE plugins; a plugin must not depend on it).

  This `@behaviour` therefore DOCUMENTS the convention and is `@impl`-usable by
  world's OWN code / test fixtures (which legitimately depend on world). A
  plugin is NOT required to `@behaviour Ezagent.World.UiSurfaceProvider`; doing
  so would force a backwards plugin→world compile arrow. Cross-plugin
  enforcement is therefore READ-TIME: world filters every entry through
  `valid_nav_surface?/1` / `valid_session_tab?/1` (fail-closed — a malformed
  entry is skipped, the UI is never crashed).

  Both callbacks are `@optional_callbacks` and default to `[]` by convention
  (absent function ⇒ no contribution).
  """

  @typedoc """
  Left-rail (Layer-2) top-level nav entries a plugin contributes to the world
  sidebar — the "顶层建筑" position, peer to Sessions / Identities / Workspaces.
  Each entry is `%{label, path}` (optional `:icon`).

  World's sidebar merges every INSTALLED plugin's `nav_surfaces/0` into its
  static nav via `Ezagent.PluginRegistry.list_all/0` — an uninstalled plugin
  contributes nothing ("没插件就没入口"). Distinct from core
  `Ezagent.Plugin.config_surface/0`, which only feeds the `/plugins` config
  page, NOT the top-level nav.
  """
  @type nav_surface :: %{
          required(:label) => String.t(),
          required(:path) => String.t(),
          optional(:icon) => String.t()
        }

  @typedoc """
  Layer-3 per-session conversation tab. `condition` (`:always` default, or a
  1-arity `(session_uri -> boolean())` world evaluates per session) gates
  visibility — kanban shows the tab for a session BOUND to a board.
  """
  @type session_tab :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          optional(:condition) => (String.t() -> boolean()) | :always
        }

  @doc """
  Layer-2 left-rail top-level nav entries this plugin contributes to the world
  sidebar. Default `[]` by convention (absent function ⇒ no entry). World reads
  it via `function_exported?/3` and filters each entry through
  `valid_nav_surface?/1`.
  """
  @callback nav_surfaces() :: [nav_surface()]

  @doc """
  Layer-3 per-session conversation tabs this plugin contributes. Default `[]`
  by convention. World evaluates each `:condition` per session and filters each
  entry through `valid_session_tab?/1`.
  """
  @callback session_tabs() :: [session_tab()]

  @optional_callbacks nav_surfaces: 0, session_tabs: 0

  @doc """
  Read-time shape predicate for one `nav_surfaces/0` entry.

  `true` iff the entry is `%{label, path}` of binaries with an OPTIONAL binary
  `:icon`. World filters every contributed entry through this (fail-closed) so a
  malformed entry is skipped rather than crashing the sidebar serializer.
  """
  @spec valid_nav_surface?(term()) :: boolean()
  def valid_nav_surface?(%{label: label, path: path} = surface)
      when is_binary(label) and is_binary(path) do
    case Map.get(surface, :icon) do
      nil -> true
      icon -> is_binary(icon)
    end
  end

  def valid_nav_surface?(_), do: false

  @doc """
  Read-time shape predicate for one `session_tabs/0` entry.

  `true` iff the entry is `%{id, label}` of binaries with an OPTIONAL
  `:condition` that is `:always` or a 1-arity predicate. World filters every
  contributed entry through this (fail-closed) so a malformed entry is skipped
  rather than crashing the conversation view switcher.
  """
  @spec valid_session_tab?(term()) :: boolean()
  def valid_session_tab?(%{id: id, label: label} = tab)
      when is_binary(id) and is_binary(label) do
    case Map.get(tab, :condition) do
      nil -> true
      :always -> true
      fun -> is_function(fun, 1)
    end
  end

  def valid_session_tab?(_), do: false
end
