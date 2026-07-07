defmodule Mix.Tasks.Ezagent.Socialware.Export do
  @shortdoc "Export a socialware Definition as manifest YAML"
  @moduledoc """
  Exports a published socialware Definition as canonical manifest YAML.

      mix ezagent.socialware.export autoservice-tier1
      mix ezagent.socialware.export autoservice-tier1 --workspace workspace://acme
  """
  use Mix.Task

  alias Mix.Tasks.Ezagent.Socialware.ManifestArgs
  alias Ezagent.Socialware.ManifestYaml

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [workspace: :string])
    name = one_name!(positional)

    case ManifestYaml.export(name, ManifestArgs.workspace_uri(opts)) do
      {:ok, yaml} -> Mix.shell().info(yaml)
      {:error, reason} -> Mix.raise("socialware manifest export failed: #{inspect(reason)}")
    end
  end

  defp one_name!([name]), do: name
  defp one_name!([]), do: Mix.raise("expected socialware definition name")
  defp one_name!(_), do: Mix.raise("expected exactly one socialware definition name")
end
