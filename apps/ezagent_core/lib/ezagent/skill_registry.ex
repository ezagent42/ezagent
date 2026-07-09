defmodule Ezagent.SkillRegistry do
  @moduledoc """
  Read-through index for deployed agent skills.

  Skills referenced by `Ezagent.Agent.Recipe` declarations are content, not
  declaration authority. Recipes keep declaring refs in `skills`; this registry
  resolves those refs to runtime skill source directories and their directory-
  closure hashes.

  `priv/skills_seed/<ref>/` remains the shipped seed source. The registry itself
  reads only the single runtime origin at `$EZAGENT_HOME/<profile>/skills/` after
  `Ezagent.Home.SkillSeed` has populated it and `refresh!/1` has marked the
  index ready.
  """

  import Bitwise

  alias Ezagent.Agent.Recipe

  @source_rel "skills_seed"
  @marker "SKILL.md"
  @entries_key {__MODULE__, :entries}
  @ready_key {__MODULE__, :ready?}

  @doc """
  Resolves `ref` to a runtime skill source directory and content hash.

  `refresh!/1` must run before the first call. A pre-ready call raises because
  it indicates a boot-order bug; after ready, unknown refs fail loudly as
  `{:error, {:skill_source_not_found, ref}}`.
  """
  @spec resolve(String.t()) ::
          {:ok, {Path.t(), String.t()}} | {:error, {:skill_source_not_found, String.t()}}
  def resolve(ref) when is_binary(ref) do
    unless ready?() do
      raise RuntimeError,
            "SkillRegistry is not ready; Ezagent.Home.SkillSeed.boot!/1 must run " <>
              "before the first skill resolve"
    end

    case Map.fetch(entries(), ref) do
      {:ok, {_dir, _hash} = entry} -> {:ok, entry}
      :error -> {:error, {:skill_source_not_found, ref}}
    end
  end

  @doc """
  Scan the single runtime origin into the read-through index and mark it ready.

  Options:

    * `:runtime_dir` — test seam for the deployment skills dir. Production code
      leaves it unset, resolving `system://skills` through `Ezagent.System.FsResolver`.
  """
  @spec refresh!(keyword()) :: :ok
  def refresh!(opts \\ []) do
    runtime_dir = runtime_dir(opts)

    entries =
      runtime_dir
      |> child_skill_refs()
      |> Map.new(fn ref ->
        dir = Path.expand(Path.join(runtime_dir, ref))
        {ref, {dir, dir_hash(dir)}}
      end)

    :persistent_term.put(@entries_key, entries)
    :persistent_term.put(@ready_key, true)
    :ok
  end

  @doc "Whether the runtime skill index has completed its boot scan."
  @spec ready?() :: boolean()
  def ready?, do: :persistent_term.get(@ready_key, false)

  @doc "Reset the runtime index. Intended for tests and boot reinitialization."
  @spec reset!() :: :ok
  def reset! do
    :persistent_term.erase(@entries_key)
    :persistent_term.put(@ready_key, false)
    :ok
  end

  @doc """
  Lists all shipped skill refs present under loaded apps' `priv/skills_seed`.

  Intermediate materialization names are ignored defensively so a future runtime
  scan cannot accidentally index crash residue.
  """
  @spec seed_bundle_refs() :: [String.t()]
  def seed_bundle_refs do
    seed_source_dirs()
    |> Enum.flat_map(&child_skill_refs/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Computes the runtime skill set from every loaded plugin module's `roles/0`.

  This mirrors `Ezagent.Plugin.boot/1`'s role seed surface: each loaded
  `ezagent_plugin_*` app contributes its plugin contract module, and each role
  recipe is validated through `Ezagent.Agent.Recipe.new/1` before its `skills`
  refs are collected.
  """
  @spec derived_recipe_skill_refs() :: [String.t()]
  def derived_recipe_skill_refs do
    loaded_plugin_modules()
    |> derived_recipe_skill_refs()
  end

  @doc """
  Computes the runtime skill set from an explicit list of plugin modules.

  This is the same derivation as `derived_recipe_skill_refs/0`, exposed for the
  seed-regeneration Mix task so it can use umbrella project metadata without
  starting plugin applications.
  """
  @spec derived_recipe_skill_refs([module()]) :: [String.t()]
  def derived_recipe_skill_refs(plugin_modules) when is_list(plugin_modules) do
    plugin_modules
    |> Enum.flat_map(&role_skills!/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  All skill-seed source dirs: every loaded OTP app's `priv/skills_seed` that
  exists on disk.

  The `:ezagent_core, :skill_registry_source_dirs` app env is a test seam for
  prod-shape resolver tests; production code should leave it unset.
  """
  @spec seed_source_dirs() :: [Path.t()]
  def seed_source_dirs do
    case Application.get_env(:ezagent_core, :skill_registry_source_dirs) do
      dirs when is_list(dirs) ->
        dirs

      nil ->
        for {app, _desc, _vsn} <- Application.loaded_applications(),
            priv = safe_priv_dir(app),
            priv != nil,
            dir = Path.join(priv, @source_rel),
            File.dir?(dir) do
          dir
        end
    end
  end

  @doc "Backward-compatible name for the shipped `priv/skills_seed` source dirs."
  @spec source_dirs() :: [Path.t()]
  def source_dirs, do: seed_source_dirs()

  @doc """
  Computes a deterministic hash over a skill directory closure.

  Each file contributes `{relative_path, owner_exec_bit, content_digest}`. Regular
  files hash their bytes; symlinks hash the link target path and are not followed.
  Empty directories do not contribute entries.
  """
  @spec dir_hash(Path.t()) :: String.t()
  def dir_hash(dir) when is_binary(dir) do
    dir = Path.expand(dir)

    dir
    |> closure_entries(dir)
    |> Enum.sort()
    |> Enum.map(fn {relpath, exec?, digest} ->
      [relpath, 0, if(exec?, do: "1", else: "0"), 0, digest, ?\n]
    end)
    |> IO.iodata_to_binary()
    |> sha256()
  end

  defp entries, do: :persistent_term.get(@entries_key, %{})

  defp runtime_dir(opts) do
    Keyword.get_lazy(opts, :runtime_dir, fn ->
      Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("skills"))
    end)
  end

  defp child_skill_refs(source_dir) do
    if File.dir?(source_dir) do
      source_dir
      |> File.ls!()
      |> Enum.filter(fn child ->
        path = Path.join(source_dir, child)

        File.dir?(path) and not intermediate_name?(child) and
          File.regular?(Path.join(path, @marker))
      end)
    else
      []
    end
  end

  defp intermediate_name?(name),
    do: String.contains?(name, ".staging-") or String.contains?(name, ".old-")

  defp loaded_plugin_modules do
    for {app, _desc, _vsn} <- Application.loaded_applications(),
        app |> Atom.to_string() |> String.starts_with?("ezagent_plugin_"),
        mod = plugin_module_for(app),
        not is_nil(mod),
        function_exported?(mod, :roles, 0) do
      mod
    end
  end

  defp plugin_module_for(app) do
    Application.get_env(app, :ezagent_plugin) || camelized_plugin_module(app)
  end

  defp camelized_plugin_module(app) do
    mod = app |> Atom.to_string() |> Macro.camelize() |> Module.concat()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :plugin_info, 0) do
      mod
    end
  rescue
    _ -> nil
  end

  defp role_skills!(plugin_module) do
    plugin_module.roles()
    |> Enum.flat_map(fn recipe ->
      case Recipe.new(recipe) do
        {:ok, %Recipe{skills: skills}} ->
          skills

        {:error, reason} ->
          raise ArgumentError,
                "#{inspect(plugin_module)} roles/0 emitted invalid recipe for skill derivation: " <>
                  inspect(reason)
      end
    end)
  end

  defp safe_priv_dir(app) do
    case :code.priv_dir(app) do
      {:error, :bad_name} -> nil
      priv -> List.to_string(priv)
    end
  end

  defp closure_entries(path, root) do
    stat = File.lstat!(path)

    cond do
      stat.type == :directory ->
        path
        |> File.ls!()
        |> Enum.flat_map(fn child -> closure_entries(Path.join(path, child), root) end)

      stat.type == :regular ->
        relpath = relative_posix_path(path, root)
        exec? = (stat.mode &&& 0o100) != 0
        digest = path |> File.read!() |> sha256()
        [{relpath, exec?, digest}]

      stat.type == :symlink ->
        relpath = relative_posix_path(path, root)
        exec? = (stat.mode &&& 0o100) != 0
        digest = path |> File.read_link!() |> sha256()
        [{relpath, exec?, digest}]

      true ->
        []
    end
  end

  defp relative_posix_path(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.join("/")
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
