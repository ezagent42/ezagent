defmodule Ezagent.PluginAssetRegistry do
  @moduledoc """
  Runtime registry of hot-loaded plugins' frontend asset entry points
  (plugin-package handoff piece 3 — assets hot-load).

  The web tier serves a hot-loaded plugin's island bundle WITHOUT a
  rebuild by consulting THIS registry, which is AUGMENTED at hot-load
  (install) and reduced at unload. It replaces the compile-time-only
  `assets.deploy` copy-into-`ezagent_web/priv/static` path for plugins
  that ship after the host has started.

  ## ETS layout

  `:ezagent_plugin_asset_registry` `:set` table owned by
  `EzagentCore.EtsOwner`. Key = `{slug, route}` (the slug from the
  package manifest + the entry's route segment); value =
  `%{slug, route, file, abs_path, content_type}` where `abs_path` is
  the resolved absolute path inside the unpacked package's `priv/`.
  The `(slug, route)` composite key means a single plugin can expose
  several entry points (JS + CSS), and an unload by slug removes only
  that plugin's rows.

  ## Serving

  `EzagentWeb.PluginAssetController` (`/plugin-assets/:slug/*path`)
  looks up an entry by `(slug, route)` and streams `abs_path`. A
  hot-loaded plugin's island is therefore reachable at
  `/plugin-assets/<slug>/<route>` immediately after install — no
  `mix assets.deploy`, no web rebuild.
  """

  alias Ezagent.PluginPackage.Manifest

  @table :ezagent_plugin_asset_registry

  @type entry :: %{
          slug: String.t(),
          route: String.t(),
          file: String.t(),
          abs_path: String.t(),
          content_type: String.t()
        }

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Register every asset entry from `manifest` against the unpacked
  package directory `priv_dir`. Idempotent for the same `(slug, route)`
  — re-registering the same entry is a no-op (a swap reuses the slug,
  so the caller unloads v1 first).

  Raises `ArgumentError` if a `(slug, route)` is already registered
  with a DIFFERENT `abs_path` (two packages fighting over the same
  route — caller bug, surfaced loudly), OR if an asset `file` resolves
  OUTSIDE `priv_dir` (path-traversal defense-in-depth, H-1).
  """
  @spec register(Manifest.t(), Path.t()) :: :ok
  def register(%Manifest{} = manifest, priv_dir) do
    # Defense-in-depth (H-1): the manifest's `file` is validated against
    # `..`/absolute at parse time, but re-assert here that the EXPANDED
    # abs_path stays within the expanded priv_dir — so even a path that
    # slipped past validation (or a future caller that bypasses the
    # manifest) cannot serve a file outside the plugin's priv dir via the
    # public `/plugin-assets/...` route.
    priv_prefix = Path.expand(priv_dir) <> "/"

    Enum.each(manifest.asset_entries, fn %{route: route, file: file, content_type: ct} ->
      abs_path = Path.expand(Path.join(priv_dir, file))

      unless String.starts_with?(abs_path, priv_prefix) do
        raise ArgumentError,
              "PluginAssetRegistry: asset entry #{inspect(file)} for slug " <>
                "#{inspect(manifest.slug)} resolves OUTSIDE priv_dir " <>
                "(#{inspect(abs_path)} not under #{inspect(priv_prefix)}); " <>
                "rejecting path-traversal attempt."
      end

      key = {manifest.slug, route}

      case :ets.lookup(@table, key) do
        [{^key, %{abs_path: ^abs_path}}] ->
          :ok

        [{^key, %{abs_path: existing}}] ->
          raise ArgumentError,
                "PluginAssetRegistry: route #{inspect(route)} for slug " <>
                  "#{inspect(manifest.slug)} is already registered at " <>
                  "#{inspect(existing)}; cannot re-register at #{inspect(abs_path)}. " <>
                  "Unload the existing package before installing a new one."

        [] ->
          :ets.insert(@table, {
            key,
            %{slug: manifest.slug, route: route, file: file, abs_path: abs_path, content_type: ct}
          })

          :ok
      end
    end)
  end

  @doc """
  Look up an asset entry by `(slug, route)`. Returns `{:ok, entry}` or
  `:error` (404).
  """
  @spec lookup(String.t(), String.t()) :: {:ok, entry()} | :error
  def lookup(slug, route) when is_binary(slug) and is_binary(route) do
    case :ets.lookup(@table, {slug, route}) do
      [{_key, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  @doc "List every registered asset entry (observability)."
  @spec list_all() :: [entry()]
  @spec list_all(String.t()) :: [entry()]
  def list_all(slug \\ nil)

  def list_all(nil) do
    @table |> :ets.tab2list() |> Enum.map(fn {_k, v} -> v end)
  end

  def list_all(slug) when is_binary(slug) do
    :ets.match_object(@table, {{slug, :_}, :_})
    |> Enum.map(fn {_k, v} -> v end)
  end

  @doc """
  Unregister every asset entry for `slug` (unload / swap-v1). Idempotent.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(slug) when is_binary(slug) do
    :ets.match_delete(@table, {{slug, :_}, :_})
    :ok
  end
end
