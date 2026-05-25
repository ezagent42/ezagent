defmodule Mix.Tasks.Ezagent.ExternalMirror.ListAdapters do
  @shortdoc "List all registered ExternalMirror adapters (SPEC §9 PR-EM-5)"
  @moduledoc """
  List every adapter registered with
  `Ezagent.ExternalMirror.AdapterRegistry` (the operator-facing
  metadata view per SPEC §4.4). No caps check — `list_adapters/0` is
  unauthed metadata per SPEC §9 PR-EM-1.

  ## Usage

      mix ezagent.external_mirror.list_adapters

  ## Output

      id              display_name                  description
      ----------------------------------------------------------------------------------
      feishu          Feishu (Lark)                 Mirror session messages to a Lark chat.

  ## Exit codes

  - `0` on success (always — empty list is not an error)

  ## See also

  - `mix ezagent.external_mirror.bind` / `unbind` / `list_bindings`
  - `Ezagent.ExternalMirror.list_adapters/0` (the facade)
  """

  use Mix.Task

  alias Mix.Tasks.Ezagent.ExternalMirror.CLI

  @impl Mix.Task
  def run(argv) do
    {_positional, %{help?: help?}} = CLI.parse_argv(argv)

    if help? do
      Mix.shell().info(@moduledoc)
    else
      CLI.ensure_app_started!()
      adapters = Ezagent.ExternalMirror.list_adapters()
      Mix.shell().info(CLI.format_adapters(adapters))
    end
  end
end
