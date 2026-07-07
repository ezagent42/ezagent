defmodule Mix.Tasks.Ezagent.Socialware.Import do
  @shortdoc "Import a socialware manifest YAML file"
  @moduledoc """
  Imports a socialware manifest YAML file through the governed publish path.

      mix ezagent.socialware.import priv/socialware/example/manifest.yaml
      mix ezagent.socialware.import manifest.yaml --workspace workspace://acme

  File IO is intentionally limited to this operator task. The library import API
  receives manifest bytes only.
  """
  use Mix.Task

  alias Mix.Tasks.Ezagent.Socialware.ManifestArgs
  alias Ezagent.Socialware.ManifestYaml

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [workspace: :string])
    path = one_path!(positional)
    yaml = File.read!(path)

    with {:ok, attrs} <- ManifestYaml.parse(yaml),
         name when is_binary(name) and name != "" <- Map.get(attrs, "name"),
         ctx <- ManifestYaml.operator_admin_ctx(name, ManifestArgs.workspace_uri(opts)),
         {:ok, result} <- ManifestYaml.import(yaml, ctx) do
      Mix.shell().info("socialware manifest #{name}: #{result}")
    else
      {:error, failures} when is_list(failures) ->
        Mix.shell().error("socialware manifest conformance failed:")

        Enum.each(failures, fn {assertion, detail} ->
          Mix.shell().error("  - #{assertion}: #{inspect(detail)}")
        end)

        Mix.raise("socialware manifest import failed")

      {:error, reason} ->
        Mix.raise("socialware manifest import failed: #{inspect(reason)}")

      other ->
        Mix.raise("socialware manifest import failed: #{inspect(other)}")
    end
  end

  defp one_path!([path]), do: path
  defp one_path!([]), do: Mix.raise("expected manifest path")
  defp one_path!(_), do: Mix.raise("expected exactly one manifest path")
end
