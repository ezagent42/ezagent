defmodule Mix.Tasks.RegSeed do
  @shortdoc "Build-time fixture task — seeds a registry (exempt from check 7)"
  @moduledoc """
  A BUILD-TIME Mix task (lives at `lib/mix/tasks/`) that calls a
  `*Registry.register` API directly to seed the registry before a
  build-time projection — exactly the sanctioned pattern of
  `mix world.e2e.fixtures` (#1476). check 7 EXEMPTS `lib/mix/tasks/**`,
  so this file must NOT trip the "declare, don't call" grep. The gate
  only greps source text (it never runs this task).
  """
  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Ezagent.PluginRegistry.register(SomePlugin)
  end
end
