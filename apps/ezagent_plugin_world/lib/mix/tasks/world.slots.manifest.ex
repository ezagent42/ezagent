defmodule Mix.Tasks.World.Slots.Manifest do
  @moduledoc """
  Regenerate the checked-in world slot manifest from the SoT registry.

      mix world.slots.manifest          # write assets/src/slots.manifest.json
      mix world.slots.manifest --check  # verify it is in sync (CI / drift gate)

  `Ezagent.World.SlotRegistry` is the source of truth; the JSON manifest is a
  generated projection consumed by the React renderer (`main.tsx`) and the JS
  mount gate. `slot_manifest_test.exs` runs `--check` semantics so drift fails
  the suite.
  """
  use Mix.Task

  @requirements ["compile"]
  @shortdoc "Regenerate (or --check) the world typed-slot manifest"

  @impl Mix.Task
  def run(args) do
    start_plugin_apps!()
    {opts, _, _} = OptionParser.parse(args, switches: [check: :boolean])

    path = manifest_path()
    generated = Ezagent.World.SlotRegistry.manifest_json()

    if opts[:check] do
      on_disk = if File.exists?(path), do: File.read!(path), else: ""

      if on_disk == generated do
        Mix.shell().info("world slot manifest in sync (#{relative(path)})")
      else
        Mix.raise(
          "world slot manifest is stale — run `mix world.slots.manifest` and commit #{relative(path)}"
        )
      end
    else
      File.write!(path, generated)
      Mix.shell().info("wrote #{relative(path)}")
    end
  end

  defp start_plugin_apps! do
    apps = Map.keys(Mix.Project.apps_paths())

    Enum.each(apps, fn app ->
      case Application.load(app) do
        :ok -> :ok
        {:error, {:already_loaded, ^app}} -> :ok
      end
    end)

    apps
    |> Enum.filter(fn app ->
      case Application.get_env(app, :ezagent_plugin) do
        provider when is_atom(provider) ->
          Code.ensure_loaded?(provider) and function_exported?(provider, :pages, 0)

        _ ->
          false
      end
    end)
    |> Enum.each(fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          Mix.raise("could not start plugin application #{inspect(app)}: #{inspect(reason)}")
      end
    end)
  end

  defp manifest_path do
    cond do
      File.dir?("apps/ezagent_plugin_world/assets/src") ->
        "apps/ezagent_plugin_world/assets/src/slots.manifest.json"

      File.dir?("assets/src") ->
        "assets/src/slots.manifest.json"

      true ->
        Mix.raise("cannot locate world assets/src — run from the umbrella root or the plugin app")
    end
  end

  defp relative(path), do: Path.relative_to_cwd(path)
end
