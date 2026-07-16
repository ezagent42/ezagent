defmodule Mix.Tasks.Ezagent.Skills.RegenSeed do
  @shortdoc "Regenerate the release-bundled skills_seed from recipe declarations"
  @moduledoc """
  Regenerates `apps/ezagent_web/priv/skills_seed` from the runtime skill refs
  derived from every loaded plugin `roles/0` recipe and shipped socialware
  `recipes.yaml` data recipe.

      mix ezagent.skills.regen_seed

  The task copies each derived ref's dev-harness closure from
  `.claude/skills/<ref>/` into the release-bundled seed origin and prints the
  resulting content hash. It never edits `.claude/`.

  `@requirements ["compile"]` pins the derivation to FRESH beams: without it a
  regen after pulling recipe changes silently derives from stale `_build`
  output and drops newly-declared refs from the bundle (the 2026-07-09 #1266
  incident shape).
  """

  use Mix.Task

  @requirements ["compile"]

  @impl Mix.Task
  def run(_argv) do
    load_umbrella_apps!()

    root = umbrella_root!()
    source_root = Path.join([root, ".claude", "skills"])
    dest_root = Path.join([root, "apps", "ezagent_web", "priv", "skills_seed"])

    _plugin_modules = plugin_modules_from_umbrella!(root)
    refs = Ezagent.SkillRegistry.derived_recipe_skill_refs()

    File.rm_rf!(dest_root)
    File.mkdir_p!(dest_root)

    Enum.each(refs, fn ref ->
      source = Path.join(source_root, ref)
      dest = Path.join(dest_root, ref)

      unless File.regular?(Path.join(source, "SKILL.md")) do
        Mix.raise("derived skill #{inspect(ref)} has no source at #{source}")
      end

      File.cp_r!(source, dest)
      hash = Ezagent.SkillRegistry.dir_hash(dest)
      Mix.shell().info("#{ref} #{hash}")
    end)

    Mix.shell().info("Regenerated #{length(refs)} skill seed(s) in #{dest_root}")
  end

  defp umbrella_root! do
    File.cwd!()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.find(fn dir ->
      File.dir?(Path.join(dir, "apps")) and File.dir?(Path.join(dir, ".claude"))
    end) ||
      Mix.raise("could not locate umbrella root from #{File.cwd!()}")
  end

  defp load_umbrella_apps! do
    umbrella_root!()
    |> umbrella_app_names()
    |> Enum.each(fn app ->
      case Application.load(app) do
        :ok -> :ok
        {:error, {:already_loaded, ^app}} -> :ok
        {:error, reason} -> Mix.raise("failed to load #{inspect(app)}: #{inspect(reason)}")
      end
    end)
  end

  defp plugin_modules_from_umbrella!(root) do
    root
    |> umbrella_app_paths()
    |> Enum.filter(fn {app, _path} ->
      app |> Atom.to_string() |> String.starts_with?("ezagent_plugin_")
    end)
    |> Enum.map(fn {app, _path} ->
      load_app!(app)

      app
      |> plugin_module_from_app!()
      |> tap(fn plugin_module ->
        unless Code.ensure_loaded?(plugin_module) and
                 function_exported?(plugin_module, :roles, 0) do
          Mix.raise("#{inspect(plugin_module)} from #{app} is not a loaded plugin module")
        end
      end)
    end)
  end

  defp load_app!(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      {:error, reason} -> Mix.raise("failed to load #{inspect(app)}: #{inspect(reason)}")
    end
  end

  defp plugin_module_from_app!(app) do
    case Application.spec(app, :mod) do
      {module, _args} when is_atom(module) ->
        module

      other ->
        Mix.raise("#{inspect(app)} does not declare an OTP application module: #{inspect(other)}")
    end
  end

  defp umbrella_app_names(root) do
    root
    |> umbrella_app_paths()
    |> Enum.map(fn {app, _path} -> app end)
  end

  defp umbrella_app_paths(root) do
    root
    |> Path.join("apps/*/mix.exs")
    |> Path.wildcard()
    |> Enum.map(fn mix_exs ->
      app_path = Path.dirname(mix_exs)
      app = app_path |> Path.basename() |> String.to_atom()
      {app, app_path}
    end)
  end
end
