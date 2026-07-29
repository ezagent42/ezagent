defmodule Mix.Tasks.Ezagent.Socialware.Check do
  @shortdoc "Conformance-check socialware Definitions (all declared refs resolve)"
  @moduledoc """
  T2-3 — the socialware Definition conformance gate. Runs the SPEC §4 assertions
  (`Ezagent.Socialware.Conformance`) against one or all installed socialware
  Definitions and fails LOUD (non-zero exit) on any unresolved reference.

  ## Usage

      # check every builtin definition seeded in the system workspace
      mix ezagent.socialware.check

      # check one definition by name in a workspace
      mix ezagent.socialware.check <name> [--workspace workspace://<ws>]

  Wired into CI (`ci.local` / the precommit gate) so a definition that names a
  nonexistent recipe / view / adapter / prompt_template_ref goes RED.
  """
  use Mix.Task

  alias Mix.Tasks.Ezagent.Socialware.ManifestArgs
  alias Ezagent.Socialware.{Conformance, Definition, DefinitionRegistry}

  @requirements ["app.start"]

  # Apps that register the adapters / recipes / view render-caps a definition
  # references but that are NOT compile-deps of this task's app (the dep graph
  # runs the other way). Started best-effort (atom-only — a no-op if absent from
  # this build), mirroring `Mix.Tasks.Ezagent.Agent.GrantRecipeCaps`. The list is
  # deployment config (`config :ezagent_domain_session,
  # :socialware_check_reference_apps`), NOT a hardcoded attribute, so a build can
  # add reference plugins without editing this generic task.
  @default_reference_apps [
    :ezagent_domain_socialware,
    :ezagent_plugin_hello,
    :ezagent_plugin_kanban
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [workspace: :string])

    # No silent default-workspace STRING fallback (#324): build the admin/system
    # workspace STRUCTURALLY when `--workspace` is omitted.
    workspace_uri = ManifestArgs.workspace_uri(opts)

    for app <- reference_apps(), do: _ = Application.ensure_all_started(app)
    _ = seed_builtins()

    definitions = resolve_definitions(positional, workspace_uri)

    if definitions == [] do
      Mix.raise("no socialware definitions to check (workspace=#{URI.to_string(workspace_uri)})")
    end

    results =
      Enum.map(definitions, fn {name, definition} ->
        {name, Conformance.check(definition, workspace_uri)}
      end)

    Enum.each(results, &report/1)

    if Enum.any?(results, fn {_name, r} -> match?({:error, _}, r) end) do
      Mix.raise("socialware conformance FAILED — see failures above")
    else
      Mix.shell().info("✓ socialware conformance: #{length(results)} definition(s) OK")
    end
  end

  defp reference_apps,
    do:
      Application.get_env(
        :ezagent_domain_session,
        :socialware_check_reference_apps,
        @default_reference_apps
      )

  defp resolve_definitions([name | _], workspace_uri) do
    case DefinitionRegistry.lookup(workspace_uri, name) do
      {:ok, %Definition{} = definition, _obj} ->
        [{name, definition}]

      :error ->
        Mix.raise("no socialware definition #{inspect(name)} in #{URI.to_string(workspace_uri)}")
    end
  end

  defp resolve_definitions([], workspace_uri) do
    workspace_uri
    |> all_definition_names()
    |> Enum.map(fn name ->
      case DefinitionRegistry.lookup(workspace_uri, name) do
        {:ok, %Definition{} = definition, _obj} ->
          {name, definition}

        :error ->
          Mix.raise(
            "listed socialware definition #{inspect(name)} did not resolve in #{URI.to_string(workspace_uri)}"
          )
      end
    end)
  end

  defp all_definition_names(workspace_uri) do
    workspace_uri
    |> DefinitionRegistry.list()
    |> Enum.map(& &1.name)
  end

  defp seed_builtins do
    if function_exported?(DefinitionRegistry, :seed_builtin_definitions, 0) do
      DefinitionRegistry.seed_builtin_definitions()
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp report({name, :ok}) do
    Mix.shell().info("  ✓ #{name}: all #{length(Conformance.assertions())} assertions pass")
  end

  defp report({name, {:error, failures}}) do
    Mix.shell().error("  ✗ #{name}:")

    Enum.each(failures, fn {assertion, detail} ->
      Mix.shell().error("      - #{assertion}: #{inspect(detail)}")
    end)
  end
end
