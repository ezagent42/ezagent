defmodule Mix.Tasks.Ezagent.Socialware.ReseedBuiltins do
  @shortdoc "Report / force-apply built-in socialware definitions (default no-clobber)"
  @moduledoc """
  Operator entry point for the built-in socialware definition seed
  (`Ezagent.Socialware.DefinitionRegistry.builtin_definitions/0`), honoring the
  DEFAULT NO-CLOBBER policy (Allen 2026-07-10).

  ## Default (no `--force`) — seed-absent + report divergences

      mix ezagent.socialware.reseed_builtins
      mix ezagent.socialware.reseed_builtins <name>

  Seeds any ABSENT built-in, leaves current ones untouched, and REPORTS every
  stored definition that DIVERGES from the code definition WITHOUT overwriting it
  (a diverged stored definition may carry an intentional runtime change). This is
  the same reconciliation the boot seed performs — safe to run any time.

  ## `--force` — apply the code version (content-safe)

      mix ezagent.socialware.reseed_builtins --force
      mix ezagent.socialware.reseed_builtins <name> --force

  Applies the CODE definition to the stored one, overriding a divergence. This is
  the explicit "change the data, not the code" action. It is content-safe:
  `ConfigStore.seed_object_upsert/1` APPENDS a new immutable object and REPOINTS
  the pointer — never a raw in-place UPDATE. Only the SYSTEM-workspace built-in
  pointer is touched, so tenant-workspace overrides are never affected.

  Exits non-zero (LOUD) on an unknown definition name or a write failure.
  """

  use Mix.Task

  alias Ezagent.Socialware.DefinitionRegistry

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [force: :boolean])
    force? = Keyword.get(opts, :force, false)
    name = List.first(positional)

    cond do
      force? and is_binary(name) -> force_one(name)
      force? -> force_all()
      is_binary(name) -> report(name)
      true -> report(nil)
    end
  end

  # ---- default (no-clobber) --------------------------------------------------

  defp report(name) do
    if is_binary(name), do: assert_known!(name)

    case DefinitionRegistry.seed_builtin_definitions() do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("built-in socialware definition seed FAILED: #{inspect(reason)}")
    end

    divergences =
      DefinitionRegistry.builtin_definition_divergences()
      |> filter_by_name(name)

    if divergences == [] do
      Mix.shell().info(
        "✓ built-in socialware definitions reconciled — absent seeded, current unchanged, " <>
          "no divergences#{for_name(name)}"
      )
    else
      Mix.shell().info(
        "⚠ #{length(divergences)} built-in definition(s) DIVERGE from code — NOT overwritten " <>
          "(default no-clobber policy):"
      )

      Enum.each(divergences, fn d ->
        Mix.shell().info(
          "    - #{d.name} in #{d.workspace_uri}: stored #{d.stored_hash} vs code #{d.code_hash}"
        )
      end)

      Mix.shell().info(
        "  To apply the code version, re-run with --force: " <>
          "mix ezagent.socialware.reseed_builtins #{name || "<name>"} --force"
      )
    end
  end

  # ---- --force (apply code) --------------------------------------------------

  defp force_all do
    DefinitionRegistry.builtin_definitions()
    |> Enum.each(&force_one(&1.name))
  end

  defp force_one(name) do
    case DefinitionRegistry.reseed_builtin_definition(name) do
      {:ok, result} ->
        Mix.shell().info(
          "✓ force-applied built-in socialware definition #{inspect(name)}: #{result}"
        )

      {:error, {:unknown_builtin_definition, ^name}} ->
        Mix.raise(
          "no built-in socialware definition named #{inspect(name)} — known: #{known_builtins()}"
        )

      {:error, reason} ->
        Mix.raise("force-apply of #{inspect(name)} FAILED: #{inspect(reason)}")
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp assert_known!(name) do
    unless Enum.any?(DefinitionRegistry.builtin_definitions(), &(&1.name == name)) do
      Mix.raise(
        "no built-in socialware definition named #{inspect(name)} — known: #{known_builtins()}"
      )
    end
  end

  defp filter_by_name(divergences, nil), do: divergences
  defp filter_by_name(divergences, name), do: Enum.filter(divergences, &(&1.name == name))

  defp for_name(nil), do: ""
  defp for_name(name), do: " for #{inspect(name)}"

  defp known_builtins do
    DefinitionRegistry.builtin_definitions()
    |> Enum.map(& &1.name)
    |> Enum.sort()
    |> Enum.join(", ")
  end
end
