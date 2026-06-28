defmodule Ezagent.PluginPackage.Manifest do
  @moduledoc """
  Declarative manifest for a plugin PACKAGE — the distributable form
  (`docs/together/2026-06-28/handoffs/plugin-package-c-codex-handoff.md` piece 1).

  A plugin package = `manifest.json` + `ebin/` (compiled OTP app) +
  `priv/` (assets bundle + seed definitions). The manifest is the
  DECLARATIVE EXTENSION of the existing `Ezagent.Plugin` contract: the
  plugin module inside the package still `use Ezagent.Plugin` and
  declares Kinds/Behaviors/template-classes via callbacks at boot; the
  manifest adds the packaging metadata the host needs to hot-load,
  serve assets, seed definitions, and (eventually) unload — WITHOUT
  re-deriving it from the compiled module.

  ## Why a manifest alongside `plugin_info/0`

  `plugin_info/0` is the runtime identity (`slug`/`name`/`version`).
  The manifest carries what `plugin_info/0` deliberately does NOT:
  the package's `app` atom + `plugin_module` (so the host can
  `:application.load` + `Ezagent.Plugin.boot/1` without a build-time
  `mix.exs`), the asset entry points (so the web tier can serve the
  island bundle at hot-load), the seed-definition refs (so the host
  seeds layer-2 data), and the unload bookkeeping list (which
  `{kind, action, behavior}` triples + template classes + routing
  tables this plugin published — the data `Ezagent.Plugin.boot/1`
  registers, recorded here so `unload/1` can reverse it without
  re-running the plugin module).

  ## Layer discipline

  The manifest is layer-1 GENERIC mechanism. It carries NO business
  words — only structural packaging metadata. Business semantics live
  in the seed-definitions (layer-2 data) the manifest REFERENCES by
  file path, never inlined here.
  """

  alias Ezagent.PluginPackage.Manifest

  @typedoc """
  An asset entry point a plugin's island bundle exposes. `route` is the
  path segment under `/plugin-assets/<slug>/...`; `file` is the path
  within the package's `priv/` (e.g. `"static/assets/main.js"`); the
  bundle is served from the package's unpacked priv dir at hot-load.
  """
  @type asset_entry :: %{
          route: String.t(),
          file: String.t(),
          content_type: String.t()
        }

  @typedoc """
  A seed-definition ref: a file path within the package's `priv/`
  containing a layer-2 definition (recipe / socialware-definition) to
  seed into ConfigStore at install, keyed by `kind` (`:recipe` |
  `:socialware`) and a `name` for unload bookkeeping.
  """
  @type seed_ref :: %{
          kind: :recipe | :socialware,
          name: String.t(),
          file: String.t()
        }

  @type t :: %__MODULE__{
          slug: String.t(),
          version: String.t(),
          app: atom(),
          plugin_module: module(),
          behaviors: [{module(), atom(), module()}],
          template_classes: [module()],
          routing_tables: [{atom(), keyword()}],
          asset_entries: [asset_entry()],
          seed_refs: [seed_ref()],
          config_schema: term() | nil
        }

  defstruct [
    :slug,
    :version,
    :app,
    :plugin_module,
    :template_classes,
    :routing_tables,
    :asset_entries,
    :seed_refs,
    :config_schema,
    behaviors: []
  ]

  @doc """
  Parse + validate a manifest from a decoded JSON map (the contents of
  a package's `manifest.json`). Raises `ArgumentError` on a malformed
  manifest so a bad package fails loudly at install, before any code is
  loaded.
  """
  @spec parse!(map()) :: t()
  def parse!(data) when is_map(data) do
    %Manifest{
      slug: fetch!(data, "slug"),
      version: fetch!(data, "version"),
      app: data |> fetch!("app") |> to_atom!("app"),
      plugin_module: data |> fetch!("plugin_module") |> to_module!("plugin_module"),
      behaviors: parse_behaviors(Map.get(data, "behaviors", [])),
      template_classes: parse_modules(Map.get(data, "template_classes", [])),
      routing_tables: parse_routing_tables(Map.get(data, "routing_tables", [])),
      asset_entries: parse_asset_entries(Map.get(data, "asset_entries", [])),
      seed_refs: parse_seed_refs(Map.get(data, "seed_refs", [])),
      config_schema: Map.get(data, "config_schema")
    }
    |> validate!()
  end

  @doc """
  Read + parse a `manifest.json` from a package directory.
  """
  @spec read!(Path.t()) :: t()
  def read!(package_dir) do
    path = Path.join(package_dir, "manifest.json")

    unless File.exists?(path) do
      raise ArgumentError,
            "plugin package has no manifest.json at #{path} — " <>
              "a package must be a directory containing manifest.json + ebin/ + priv/"
    end

    path
    |> File.read!()
    |> Jason.decode!()
    |> parse!()
  end

  @doc """
  Validate a parsed manifest. Raises `ArgumentError` on any malformed
  field. Cross-module reachability is NOT checked here (the plugin's
  modules are loaded only at install); this validates the manifest's
  structural shape + that `plugin_module` is a real module atom.
  """
  @spec validate!(t()) :: t()
  def validate!(%Manifest{} = m) do
    unless is_binary(m.slug) and m.slug != "" do
      raise ArgumentError, "manifest field `slug` must be a non-empty string"
    end

    unless is_binary(m.version) and m.version != "" do
      raise ArgumentError, "manifest field `version` must be a non-empty string"
    end

    unless is_atom(m.app) do
      raise ArgumentError, "manifest field `app` must be a string (OTP app name)"
    end

    unless is_atom(m.plugin_module) do
      raise ArgumentError, "manifest field `plugin_module` must be a module atom string"
    end

    Enum.each(m.behaviors, fn {kind, action, behavior} = decl ->
      unless is_atom(kind) and is_atom(action) and is_atom(behavior) do
        raise ArgumentError,
              "manifest `behaviors` entry #{inspect(decl)} must be " <>
                "`{kind_module, action_atom, behavior_module}`"
      end
    end)

    Enum.each(m.asset_entries, fn %{route: route, file: file} ->
      unless is_binary(route) and route != "" and is_binary(file) and file != "" do
        raise ArgumentError,
              "manifest `asset_entries` must each carry non-empty `route` + `file`"
      end
    end)

    Enum.each(m.seed_refs, fn %{kind: kind, name: name, file: file} = ref ->
      unless kind in [:recipe, :socialware] do
        raise ArgumentError,
              "manifest `seed_refs` entry #{inspect(ref)} kind must be :recipe | :socialware"
      end

      unless is_binary(name) and name != "" and is_binary(file) and file != "" do
        raise ArgumentError,
              "manifest `seed_refs` entry #{inspect(ref)} must carry non-empty `name` + `file`"
      end
    end)

    m
  end

  @doc "Serialize a manifest to a JSON-encodable map (for `manifest.json`)."
  @spec to_json(t()) :: map()
  def to_json(%Manifest{} = m) do
    %{
      "slug" => m.slug,
      "version" => m.version,
      "app" => Atom.to_string(m.app),
      "plugin_module" => inspect(m.plugin_module),
      "behaviors" =>
        Enum.map(m.behaviors, fn {k, a, b} ->
          %{"kind" => inspect(k), "action" => Atom.to_string(a), "behavior" => inspect(b)}
        end),
      "template_classes" => Enum.map(m.template_classes, &inspect/1),
      "routing_tables" => Enum.map(m.routing_tables, fn {t, _} -> Atom.to_string(t) end),
      "asset_entries" => Enum.map(m.asset_entries, &Map.new(&1)),
      "seed_refs" => Enum.map(m.seed_refs, &Map.new(&1)),
      "config_schema" => m.config_schema
    }
  end

  @doc """
  Derive a manifest from a LOADED plugin module — the inverse of
  `parse!/1`. Used by `mix ezagent.plugin.package` (and tests) to emit a
  `manifest.json` from a built plugin app: it reads the plugin's
  `plugin_info/0` + declaration callbacks, then layers on the supplied
  packaging extras (asset entries + seed refs).
  """
  @spec from_plugin(module(), keyword()) :: t()
  def from_plugin(plugin_module, opts \\ []) when is_atom(plugin_module) do
    info = plugin_module.plugin_info()

    %Manifest{
      slug: info.slug,
      version: info.version,
      app: Keyword.get(opts, :app, app_from_module(plugin_module)),
      plugin_module: plugin_module,
      behaviors: plugin_module.behaviors(),
      template_classes: plugin_module.template_classes(),
      routing_tables: plugin_module.routing_tables(),
      asset_entries: Keyword.get(opts, :asset_entries, []),
      seed_refs: Keyword.get(opts, :seed_refs, []),
      config_schema: Keyword.get(opts, :config_schema)
    }
    |> validate!()
  end

  # --- private --------------------------------------------------------------

  defp fetch!(data, key) do
    case Map.fetch(data, key) do
      {:ok, val} ->
        val

      :error ->
        raise ArgumentError, "manifest is missing required field `#{key}`"
    end
  end

  defp to_atom!(value, field) when is_binary(value) do
    if String.match?(value, ~r/^[a-z][a-z0-9_]*$/) do
      String.to_atom(value)
    else
      raise ArgumentError,
            "manifest field `#{field}` must be a lowercase snake_case atom; got: #{inspect(value)}"
    end
  end

  defp to_module!(value, field) when is_binary(value) do
    value = String.trim_leading(value, "Elixir.")
    mod = Module.concat(["Elixir" | String.split(value, ".")])
    true = is_atom(mod)
    mod
  rescue
    _ ->
      raise ArgumentError, "manifest field `#{field}` is not a valid module atom: #{inspect(value)}"
  end

  defp parse_behaviors(list) when is_list(list) do
    Enum.map(list, fn
      %{"kind" => k, "action" => a, "behavior" => b} ->
        {to_module!(k, "behaviors.kind"), String.to_atom(a), to_module!(b, "behaviors.behavior")}

      other ->
        raise ArgumentError, "manifest `behaviors` entry #{inspect(other)} is malformed"
    end)
  end

  defp parse_modules(list) when is_list(list) do
    Enum.map(list, &to_module!(&1, "template_classes"))
  end

  defp parse_routing_tables(list) when is_list(list) do
    Enum.map(list, fn
      %{"table" => t, "opts" => opts} ->
        {String.to_atom(t), opts || []}

      name when is_binary(name) ->
        {String.to_atom(name), []}

      other ->
        raise ArgumentError, "manifest `routing_tables` entry #{inspect(other)} is malformed"
    end)
  end

  defp parse_asset_entries(list) when is_list(list) do
    Enum.map(list, fn
      %{"route" => route, "file" => file} = entry ->
        %{
          route: route,
          file: file,
          content_type: Map.get(entry, "content_type", content_type_for(file))
        }

      other ->
        raise ArgumentError, "manifest `asset_entries` entry #{inspect(other)} is malformed"
    end)
  end

  defp parse_seed_refs(list) when is_list(list) do
    Enum.map(list, fn
      %{"kind" => kind, "name" => name, "file" => file} ->
        %{
          kind: if(kind == "socialware", do: :socialware, else: :recipe),
          name: name,
          file: file
        }

      other ->
        raise ArgumentError, "manifest `seed_refs` entry #{inspect(other)} is malformed"
    end)
  end

  defp content_type_for(file) do
    cond do
      String.ends_with?(file, ".js") -> "text/javascript"
      String.ends_with?(file, ".css") -> "text/css"
      String.ends_with?(file, ".json") -> "application/json"
      true -> "application/octet-stream"
    end
  end

  defp app_from_module(plugin_module) do
    plugin_module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> Macro.underscore()
    |> String.to_atom()
  end
end
