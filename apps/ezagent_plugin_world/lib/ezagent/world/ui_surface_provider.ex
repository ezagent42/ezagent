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
  here; core's `Ezagent.Plugin` deliberately does not carry these callbacks or
  their shape gate.

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

  ## The `:presenter_caps` socket-assign contract (caps injection, #1476)

  A plugin's `actions_module.handle_dispatch/3` needs the caller's CURRENT caps
  to build dispatch ctx, but it must NOT call `Ezagent.World.PresenterCaps`
  directly — that would be the same backwards plugin→world compile arrow the
  duck-typed seam above avoids. So WORLD computes the caps and INJECTS them:
  before every hand-off, world (`WorldLive`'s `world:dispatch` chokepoint — and
  any other world-aware caller, e.g. ezagent_web's `KanbanPublishedReadAdapter`
  for a `share_link` web path) assigns `PresenterCaps.load(socket)` into the
  `:presenter_caps` socket assign. The plugin reads `socket.assigns.presenter_caps`
  — a world-populated value, peer to `current_entity_uri` / `current_workspace_uri`
  — with zero compile dep on world. This keeps the `presenter_caps_dispatch_gate`
  invariant enforced on world's side (caps always originate from
  `PresenterCaps.load/1`, never the raw mount snapshot). The data seams
  (`data_builder.state_for/2`, `session_view.state_builder.session_state_for/2`)
  instead receive world-computed `caller_caps` in their explicit ctx map — same
  principle, different carrier.
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

  @typedoc """
  A caller-scoped refresh projection for a renderer currently mounted in World.
  `target` tells the generic shell which URI to subscribe to; `state_builder`
  exports `refresh_state/2` and returns JSON-safe partial state.
  """
  @type refresh_surface :: %{
          required(:id) => String.t(),
          required(:component) => String.t(),
          required(:target) => {:route, atom()} | {:assign, atom()},
          required(:state_builder) => module()
        }

  @callback pages() :: [map()]
  @callback refresh_surfaces() :: [refresh_surface()]

  @optional_callbacks nav_surfaces: 0, session_tabs: 0, pages: 0, refresh_surfaces: 0

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

  @doc """
  Read-time shape predicate for one `unfurl` renderer entry a plugin declares in
  its `pages/0` `:unfurl` field (the world-generic "link unfurl bubble" seam,
  mirroring the `plugin-page-renderers` manifest).

  `true` iff the entry is `%{id, pattern, renderer: %{source, export}}` where
  `id` is a lowercase-underscore key, `pattern` is a NON-EMPTY binary (a regex
  source string compiled on the JS side), and `renderer.source` / `renderer.export`
  satisfy the same import constraints as a page renderer's `source` (under
  `assets/src/`, no `..`, `.ts`/`.tsx` extension) with `export` a non-empty
  binary. NOTE: an unfurl renderer has NO `full_bleed` field (it is a chat
  bubble, not a full-bleed page), so this deliberately does not reuse
  `validate_renderer/2`. World filters every contributed entry through this
  (fail-closed) so a malformed entry keeps the whole page declaration out.
  """
  @spec valid_unfurl_renderer?(term()) :: boolean()
  def valid_unfurl_renderer?(%{
        id: id,
        pattern: pattern,
        renderer: %{source: source, export: export}
      }) do
    valid_key?(id) and is_binary(pattern) and pattern != "" and
      valid_renderer_source?(source) and is_binary(export) and export != ""
  end

  def valid_unfurl_renderer?(_), do: false

  @doc "Strict, fail-closed validation for a standalone refresh surface."
  @spec valid_refresh_surface?(term()) :: boolean()
  def valid_refresh_surface?(%{
        id: id,
        component: component,
        target: target,
        state_builder: builder
      }) do
    valid_key?(id) and valid_key?(component) and valid_refresh_target?(target) and
      exports?(builder, :refresh_state, 2)
  end

  def valid_refresh_surface?(_), do: false

  defp valid_refresh_target?({:route, key}) when is_atom(key), do: true
  defp valid_refresh_target?({:assign, key}) when is_atom(key), do: true
  defp valid_refresh_target?(_), do: false
  @doc "Strict, fail-closed validation for a plugin-owned page declaration."
  @spec validate_page(term()) :: :ok | {:error, [atom()]}
  def validate_page(page) when is_map(page) do
    errors =
      []
      |> invalid_unless(:key, valid_key?(Map.get(page, :key)))
      |> invalid_unless(:route, valid_route?(Map.get(page, :route), :index))
      |> invalid_unless(:detail_route, valid_route?(Map.get(page, :detail_route), :detail))
      |> invalid_unless(:nav, valid_nav_surface?(Map.get(page, :nav)))
      |> invalid_unless(:data_builder, exports?(Map.get(page, :data_builder), :state_for, 2))
      |> invalid_unless(
        :renderer_families,
        valid_renderer_families?(Map.get(page, :renderer_families))
      )
      |> invalid_unless(:actions, valid_actions?(Map.get(page, :actions)))
      |> invalid_unless(
        :actions_module,
        exports?(Map.get(page, :actions_module), :handle_dispatch, 3)
      )
      |> validate_session_view(Map.get(page, :session_view))
      |> validate_renderer(Map.get(page, :renderer))
      |> validate_unfurl(Map.get(page, :unfurl))
      |> Enum.reverse()

    if errors == [], do: :ok, else: {:error, errors}
  end

  def validate_page(_), do: {:error, [:declaration]}

  @doc """
  Boolean, fail-closed form of `validate_page/1` (`true` iff it returns `:ok`).

  The page-declaration counterpart to `valid_nav_surface?/1` /
  `valid_session_tab?/1`, for callers that only need a yes/no verdict. The
  registry (`PluginPageRegistry.resolve/1`) uses the detailed `validate_page/1`
  instead, because it must record WHY a declaration was rejected; this predicate
  is the convenience wrapper for plain guards and tests that discard that detail.
  """
  @spec valid_page?(term()) :: boolean()
  def valid_page?(page), do: validate_page(page) == :ok

  defp invalid_unless(errors, _field, true), do: errors
  defp invalid_unless(errors, field, false), do: [field | errors]

  defp valid_key?(key),
    do: is_binary(key) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, key)

  defp valid_route?({path, kind}, expected_kind),
    do: kind == expected_kind and is_binary(path) and String.starts_with?(path, "/")

  defp valid_route?(_, _), do: false

  defp valid_renderer_families?(families) when is_list(families) and families != [] do
    Enum.all?(families, fn
      {family, title} when is_binary(family) and is_binary(title) ->
        family != "" and title != ""

      _ ->
        false
    end) and Enum.uniq_by(families, &elem(&1, 0)) == families
  end

  defp valid_renderer_families?(_), do: false

  defp valid_actions?(actions) when is_list(actions) and actions != [] do
    Enum.all?(actions, fn action ->
      is_binary(action) and Regex.match?(~r/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/, action)
    end) and Enum.uniq(actions) == actions
  end

  defp valid_actions?(_), do: false

  defp exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp exports?(_, _, _), do: false

  defp validate_session_view(errors, nil), do: errors

  defp validate_session_view(errors, %{id: id, state_builder: builder}) do
    errors
    |> invalid_unless(:session_view_id, valid_key?(id))
    |> invalid_unless(:session_view_state_builder, exports?(builder, :session_state_for, 2))
  end

  defp validate_session_view(errors, _), do: [:session_view | errors]

  defp validate_renderer(errors, %{source: source, export: export, full_bleed: full_bleed}) do
    errors
    |> invalid_unless(:renderer_import, valid_renderer_source?(source))
    |> invalid_unless(
      :renderer_export,
      is_binary(export) and Regex.match?(~r/^[A-Z][A-Za-z0-9_]*$/, export)
    )
    |> invalid_unless(:renderer_full_bleed, is_boolean(full_bleed))
  end

  defp validate_renderer(errors, _), do: [:renderer | errors]

  defp valid_renderer_source?(source) do
    is_binary(source) and String.starts_with?(source, "assets/src/") and
      not String.contains?(source, "..") and Path.extname(source) in [".ts", ".tsx"]
  end

  # Optional `:unfurl` field — absent ⇒ legal (缺省合法). When present it must be
  # a NON-EMPTY list whose every entry passes `valid_unfurl_renderer?/1`; an empty
  # list or a non-list is rejected (照 `valid_actions?` 风格 — a page that declares
  # unfurl must declare at least one valid renderer).
  defp validate_unfurl(errors, nil), do: errors

  defp validate_unfurl(errors, list) when is_list(list) and list != [] do
    if Enum.all?(list, &valid_unfurl_renderer?/1), do: errors, else: [:unfurl | errors]
  end

  defp validate_unfurl(errors, _), do: [:unfurl | errors]
end
