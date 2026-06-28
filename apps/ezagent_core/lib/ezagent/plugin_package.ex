defmodule Ezagent.PluginPackage do
  @moduledoc """
  Plugin-package hot-load / unload / swap orchestrator (handoff
  `docs/together/2026-06-28/handoffs/plugin-package-c-codex-handoff.md`).

  A plugin package is a versioned distributable bundle:
  `manifest.json` + `ebin/` (compiled OTP app) + `priv/` (assets bundle
  + seed definitions). This module is the GENERIC layer-1 mechanism that
  accepts such a bundle, hot-loads it WITHOUT a host restart, and
  reverses the load on unload — no business words, no awareness of what
  a given plugin's Behaviors actually do.

  ## install/1 (handoff piece 2)

  1. Unpack the package to `EZAGENT_HOME/plugins/<slug>-<version>/`
     (no-op if already a directory).
  2. Read + validate `manifest.json`.
  3. `:code.add_path(ebin)` — make the plugin's modules loadable.
  4. `:application.load` + `:application.ensure_all_started` — boot the
     plugin's OTP app; its `Application.start/2` delegates to
     `Ezagent.Plugin.boot/1`, which registers Behaviors / template
     classes / routing tables / etc. (the EXISTING path — unchanged).
  5. Seed the package's `seed_refs` into ConfigStore via
     `Ezagent.Plugin.SeedHook`.
  6. Register the package's asset entries via
     `Ezagent.PluginAssetRegistry` (handoff piece 3 — assets hot-load).
  7. Record the install in `Ezagent.PluginPackage.InstalledRegistry`
     (unload bookkeeping).

  ## unload/1 (handoff piece 4)

  1. `:application.stop` + `:application.unload` — tear down the OTP app.
  2. Unregister the manifest's Behaviors (`CapabilityRegistry.unregister/3`),
     template classes (`TemplateRegistry.unregister/1`), routing tables
     (`RoutingRegistry.undeclare_table/1`), plugin self-reg
     (`PluginRegistry.unregister/1`), and assets
     (`PluginAssetRegistry.unregister/1`).
  3. Retire the seeded definitions (`Ezagent.Plugin.SeedHook.retire/2`).
  4. `:code.del_paths` + `:code.purge` the plugin's modules.

  ### Live-instance policy (the unload-vs-live-instance OQ)

  A live session/agent whose BehaviorSet mounts an UNLOADED plugin's
  behavior is NOT forcibly torn down. New dispatch to the unloaded
  behavior fails cleanly: `BehaviorRegistry.lookup/2` returns `:error` →
  `BehaviorSet.resolve_action/3` returns `{:error, {:unknown_action, _}}`
  → the caller sees `{:error, {:unknown_action, action}}`. An in-flight
  dispatch that already entered the behavior's `handle_<action>/2` when
  the module is purged will crash (let-it-crash); the Kind's supervisor
  restarts it, and the restarted process finds the behavior gone → next
  dispatch returns `:unknown_action`. No registry state is corrupted
  (each unload is per-plugin-scoped; siblings are untouched). This is
  the deny-new / drain-existing / let-it-crash-if-live-loses-its-behavior
  policy the handoff specified — the structural answer to the
  unload-vs-live-instance open question.

  ## swap/2 (handoff piece 4)

  `unload(v1_slug) + install(v2_package)`. BEAM hot-code-reload
  semantics for the modules (v2's beams replace v1's on the code path).
  """

  alias Ezagent.{
    CapabilityRegistry,
    Home,
    PluginAssetRegistry,
    PluginRegistry,
    PluginPackage.InstalledRegistry,
    PluginPackage.Manifest,
    Plugin.SeedHook,
    RoutingRegistry,
    TemplateRegistry
  }

  @doc "Install a plugin package (archive path OR unpacked directory)."
  @spec install(Path.t()) :: {:ok, map()} | {:error, term()}
  def install(package_path) do
    dir = unpack!(package_path)
    manifest = Manifest.read!(dir)
    ebin = Path.join(dir, "ebin")
    priv_dir = Path.join(dir, "priv")

    with :ok <- add_code_path(ebin),
         :ok <- load_application(manifest.app),
         {:ok, _started} <- ensure_all_started(manifest.app),
         :ok <- seed_definitions(manifest, priv_dir),
         :ok <- PluginAssetRegistry.register(manifest, priv_dir) do
      rec = %{
        manifest: manifest,
        app: manifest.app,
        ebin: ebin,
        priv_dir: priv_dir,
        modules: enumerate_modules(ebin),
        seeded: manifest.seed_refs
      }

      :ok = InstalledRegistry.put(rec)
      {:ok, %{slug: manifest.slug, app: manifest.app, manifest: manifest}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Unload a hot-loaded plugin package by slug."
  @spec unload(String.t()) :: :ok | {:error, term()}
  def unload(slug) when is_binary(slug) do
    case InstalledRegistry.lookup(slug) do
      :error ->
        {:error, {:not_installed, slug}}

      {:ok, rec} ->
        :ok = stop_application(rec.app)
        :ok = unregister_declarations(rec.manifest)
        :ok = retire_seeds(rec.manifest)
        :ok = PluginAssetRegistry.unregister(slug)
        :ok = purge_modules(rec.modules, rec.ebin)
        :ok = InstalledRegistry.delete(slug)
        :ok
    end
  end

  @doc "Swap: unload v1 (by slug) + install v2 (package path)."
  @spec swap(String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def swap(v1_slug, v2_package) when is_binary(v1_slug) do
    with :ok <- unload(v1_slug),
         {:ok, result} <- install(v2_package) do
      {:ok, result}
    end
  end

  @doc "Look up an installed package record by slug."
  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(slug), do: InstalledRegistry.lookup(slug)

  @doc "List every installed package record."
  @spec list_all() :: [map()]
  def list_all, do: InstalledRegistry.list_all()

  # --- install steps --------------------------------------------------------

  defp unpack!(path) do
    abs = Path.expand(path)

    cond do
      File.dir?(abs) and File.exists?(Path.join(abs, "manifest.json")) ->
        abs

      String.ends_with?(abs, ".zip") ->
        dest = unpack_dir(abs)
        File.rm_rf!(dest)
        File.mkdir_p!(dest)
        {:ok, _entries} = :zip.unzip(to_charlist(abs), [{:cwd, to_charlist(dest)}])
        dest

      true ->
        raise ArgumentError,
              "plugin package must be a directory containing manifest.json " <>
                "or a .zip archive; got: #{inspect(abs)}"
    end
  end

  defp unpack_dir(archive_path) do
    base = Path.basename(archive_path, ".zip")
    Path.join(Home.path(:plugins), "#{base}-#{:erlang.phash2(archive_path)}")
  end

  defp add_code_path(ebin) do
    if File.dir?(ebin) do
      case :code.add_path(String.to_charlist(ebin)) do
        true -> :ok
        {:error, reason} -> {:error, {:add_path_failed, reason}}
      end
    else
      {:error, {:no_ebin, ebin}}
    end
  end

  defp load_application(app) do
    case :application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      {:error, reason} -> {:error, {:load_failed, reason}}
    end
  end

  defp ensure_all_started(app) do
    case :application.ensure_all_started(app) do
      {:ok, started} -> {:ok, started}
      {:error, {:already_started, ^app}} -> {:ok, []}
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp seed_definitions(%Manifest{seed_refs: refs}, priv_dir) do
    Enum.reduce_while(refs, :ok, fn %{kind: kind, name: name, file: file}, :ok ->
      path = Path.join(priv_dir, file)

      case File.read(path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, body} ->
              case SeedHook.seed(kind, name, body) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, {:seed_failed, kind, name, reason}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:seed_file_invalid_json, file, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:seed_file_missing, file, reason}}}
      end
    end)
  end

  defp enumerate_modules(ebin) do
    case File.dir?(ebin) do
      true ->
        Path.wildcard(Path.join(ebin, "*.beam"))
        |> Enum.map(fn beam ->
          beam |> Path.basename(".beam") |> String.to_atom()
        end)

      false ->
        []
    end
  end

  # --- unload steps ---------------------------------------------------------

  defp stop_application(app) do
    _ = :application.stop(app)
    _ = :application.unload(app)
    :ok
  end

  defp unregister_declarations(%Manifest{} = manifest) do
    Enum.each(manifest.behaviors, fn {kind, action, behavior} ->
      :ok = CapabilityRegistry.unregister(kind, action, behavior)
    end)

    Enum.each(manifest.template_classes, fn class_module ->
      try do
        name = class_module.template_name()
        :ok = TemplateRegistry.unregister(name)
      rescue
        _ -> :ok
      end
    end)

    Enum.each(manifest.routing_tables, fn {table_name, _opts} ->
      :ok = RoutingRegistry.undeclare_table(table_name)
    end)

    :ok = PluginRegistry.unregister(manifest.slug)
    :ok
  end

  defp retire_seeds(%Manifest{seed_refs: refs}) do
    Enum.each(refs, fn %{kind: kind, name: name} ->
      :ok = SeedHook.retire(kind, name)
    end)

    :ok
  end

  defp purge_modules(modules, ebin) do
    # Remove the plugin's ebin from the code path first, then purge each
    # module so the BEAM frees the old code version. `:code.purge/1` is
    # safe (no-op if the module isn't loaded); `:code.delete/1` removes
    # the old version after purge.
    _ = :code.del_paths([String.to_charlist(ebin)])

    Enum.each(modules, fn mod ->
      _ = :code.purge(mod)
      _ = :code.delete(mod)
    end)

    :ok
  end
end
