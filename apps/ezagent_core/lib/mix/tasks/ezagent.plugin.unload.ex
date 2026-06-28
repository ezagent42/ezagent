defmodule Mix.Tasks.Ezagent.Plugin.Unload do
  @shortdoc "Unload a hot-loaded plugin package (stop app + unregister + retire seeds + purge)"

  @moduledoc """
  Reverse of `mix ezagent.plugin.install` for a plugin PACKAGE (Q1-C):
  stop the plugin's OTP app, unregister its Behaviors / template classes
  / routing tables / assets, retire its seeded ConfigStore definitions,
  and purge its modules from the BEAM. See `Ezagent.PluginPackage.unload/1`
  for the live-instance policy (deny new, drain existing, let-it-crash).

  ## Usage

      mix ezagent.plugin.unload <slug>
  """

  use Mix.Task

  @impl Mix.Task
  def run([slug | _]) do
    case Ezagent.PluginPackage.unload(slug) do
      :ok ->
        Mix.shell().info("✓ plugin package #{inspect(slug)} unloaded")

      {:error, reason} ->
        Mix.shell().error("plugin package unload failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  def run(_argv) do
    Mix.shell().error("usage: mix ezagent.plugin.unload <slug>")
    exit({:shutdown, 2})
  end
end
