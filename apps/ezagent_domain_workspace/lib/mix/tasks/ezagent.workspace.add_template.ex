defmodule Mix.Tasks.Ezagent.Workspace.AddTemplate do
  @shortdoc "Add a session template to a workspace — same path as the operator UI"
  @moduledoc """
  Add a session template to a workspace via
  `Ezagent.Workspace.add_template/3` — the SAME function the operator UI calls.
  CLI and UI share one code path per Allen 2026-05-25 (`CLI/UI 同源派生`).

  ## Usage

      mix ezagent.workspace.add_template <workspace_name> <template_name> --json '<template_json>'
      mix ezagent.workspace.add_template <workspace_name> <template_name> --file <path_to_template.json>

  The template body is a map; pass it as JSON via `--json` or `--file`. The UI
  form composes the same map from its picker widgets before calling
  `add_template/3` — the underlying contract is one function with a map
  argument.

  ## Example

      mix ezagent.workspace.add_template system orchestrator \\
        --file priv/templates/orchestrator.json

  Exits non-zero on error.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} =
      OptionParser.parse(args, strict: [json: :string, file: :string])

    case positional do
      [workspace_name, tmpl_name | _]
      when is_binary(workspace_name) and workspace_name != "" and
             is_binary(tmpl_name) and tmpl_name != "" ->
        tmpl =
          case load_template(opts) do
            {:ok, t} -> t
            {:error, reason} -> Mix.raise("template load failed: #{inspect(reason)}")
          end

        case Ezagent.Workspace.add_template(workspace_name, tmpl_name, tmpl) do
          :ok ->
            Mix.shell().info(
              "✓ added template #{inspect(tmpl_name)} to workspace #{workspace_name}"
            )

          {:error, reason} ->
            Mix.raise("add_template failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("""
        Missing arguments.

        Usage:
          mix ezagent.workspace.add_template <workspace_name> <template_name> --json '<json>'
          mix ezagent.workspace.add_template <workspace_name> <template_name> --file <path>
        """)
    end
  end

  defp load_template(opts) do
    cond do
      json = opts[:json] -> decode_json(json)
      file = opts[:file] -> file |> File.read!() |> decode_json()
      true -> {:error, "must pass --json or --file"}
    end
  end

  defp decode_json(s) do
    case Jason.decode(s) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "template JSON must decode to an object/map"}
      {:error, e} -> {:error, Jason.DecodeError.message(e)}
    end
  end
end
