defmodule Mix.Tasks.Ci.Shard.Verify do
  use Mix.Task

  @shortdoc "Prove the CI full-suite shard split is a lossless partition of `mix ci.local`"

  @moduledoc """
  Parity gate for the CI full-suite shard split. Fails (non-zero) unless the union
  of the shards reproduces the monolith `mix ci.local` EXACTLY. Three proofs:

    1. FILE parity — every `apps/*/test/**/*_test.exs` the monolith runs is
       assigned to exactly one shard (empty-allowlist: 0 unassigned, no empty
       shard). This is the guarantee that no test is silently dropped.

    2. STEP parity — the set of NON-test steps across all `ci.shard.*` aliases
       equals the set of NON-test steps of `ci.local` (with nested aliases like
       `precommit` fully expanded, and the split `test` step excluded on both
       sides). Drift-proof: drop `world.e2e.fixtures` from `ci.shard.static` and
       this fails; add a new gate to `ci.local` without assigning it to a shard
       and this fails.

    3. NAME parity — the `ci.shard.*` alias keys equal the manifest shard names
       plus `static`.

  Run at the umbrella root (`Mix.Project.config()` must be the umbrella so the
  aliases are visible):

      mix ci.shard.verify

  The `ci_shard_parity_test.exs` arch test enforces proof #1 on every PR (via the
  `gate.arch` subset); this task additionally enforces #2 and #3 and is the
  coordinator's manual tool + a `ci.shard.static` step.
  """

  @impl Mix.Task
  def run(_args) do
    file_report = EzagentCore.CiShards.verify()
    print_file_report(file_report)

    aliases = Mix.Project.config()[:aliases] || []
    {step_errors, cilocal_set, shard_set} = check_step_parity(aliases)
    name_errors = check_name_parity(aliases)

    errors =
      file_errors(file_report) ++ step_errors ++ name_errors

    if errors == [] do
      Mix.shell().info([
        :green,
        "\n✓ ci.shard parity OK — #{file_report.total} test files partitioned across " <>
          "#{map_size(file_report.counts)} shards; step-set (#{MapSet.size(shard_set)}) == " <>
          "ci.local non-test step-set (#{MapSet.size(cilocal_set)}).",
        :reset
      ])
    else
      Mix.shell().error("\n✗ ci.shard parity BROKEN:")
      Enum.each(errors, &Mix.shell().error("    - #{&1}"))
      Mix.raise("ci.shard parity failure (#{length(errors)} issue(s)) — see above.")
    end
  end

  # ---- FILE parity ---------------------------------------------------------

  defp print_file_report(r) do
    Mix.shell().info("ci.shard file parity — #{r.total} umbrella test files:")

    Enum.each(Enum.sort(r.counts), fn {name, count} ->
      Mix.shell().info("  #{String.pad_trailing(name, 10)} #{count}")
    end)

    Mix.shell().info("  #{String.pad_trailing("static", 10)} 0 (deterministic gates only)")
    Mix.shell().info("  sum assigned = #{r.counts |> Map.values() |> Enum.sum()} / #{r.total}")
  end

  defp file_errors(%{ok?: true}), do: []

  defp file_errors(r) do
    unassigned = for f <- r.unassigned, do: "unassigned test file (matches no shard): #{f}"
    empty = for n <- r.empty, do: "shard #{inspect(n)} matched 0 test files (stale rule?)"
    unassigned ++ empty
  end

  # ---- STEP parity ---------------------------------------------------------

  defp check_step_parity(aliases) do
    cilocal_set = alias_step_set(:"ci.local", aliases)

    shard_set =
      aliases
      |> shard_alias_keys()
      |> Enum.map(&alias_step_set(&1, aliases))
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    errors =
      cond do
        MapSet.equal?(cilocal_set, shard_set) ->
          []

        true ->
          missing = MapSet.difference(cilocal_set, shard_set)
          extra = MapSet.difference(shard_set, cilocal_set)

          for(s <- missing, do: "ci.local step NOT covered by any shard: #{describe(s)}") ++
            for(s <- extra, do: "shard step NOT in ci.local (drift): #{describe(s)}")
      end

    {errors, cilocal_set, shard_set}
  end

  # Flattened SET of a `ci.local`/`ci.shard.*` alias's steps, with nested aliases
  # (e.g. `precommit`) expanded and the split `test` step dropped on both sides.
  defp alias_step_set(key, aliases) do
    aliases
    |> Keyword.get(key, [])
    |> Enum.flat_map(&flatten_step(&1, aliases))
    |> Enum.reject(&(&1 == :__test__))
    |> MapSet.new()
  end

  defp flatten_step(step, aliases) when is_binary(step) do
    task = step |> String.split(" ", parts: 2) |> hd()
    key = String.to_atom(task)

    cond do
      Keyword.has_key?(aliases, key) -> Enum.flat_map(aliases[key], &flatten_step(&1, aliases))
      task == "test" -> [:__test__]
      # The parity self-check is a meta-gate the static shard runs; it is not a
      # coverage step and has no counterpart in ci.local, so it is excluded from
      # both sides of the step-set comparison.
      task == "ci.shard.verify" -> []
      true -> [{:task, step}]
    end
  end

  defp flatten_step(fun, _aliases) when is_function(fun) do
    info = Function.info(fun)
    name = to_string(info[:name])

    # The only anonymous funs in these aliases are the per-shard test closures
    # (`shard_test_step/1`); collapse them to the split-out test step and drop.
    if String.contains?(name, "-fun-") or String.contains?(name, "shard_test_step") do
      [:__test__]
    else
      [{:fun, info[:module], info[:name], info[:arity]}]
    end
  end

  defp describe({:task, s}), do: "task #{inspect(s)}"
  defp describe({:fun, m, f, a}), do: "function #{inspect(m)}.#{f}/#{a}"

  # ---- NAME parity ---------------------------------------------------------

  defp check_name_parity(aliases) do
    have =
      aliases
      |> Keyword.keys()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.filter(&String.starts_with?(&1, "ci.shard."))
      |> Enum.map(&String.replace_prefix(&1, "ci.shard.", ""))
      |> MapSet.new()

    want = MapSet.new(["static" | EzagentCore.CiShards.shard_names()])

    cond do
      MapSet.equal?(have, want) ->
        []

      true ->
        missing = MapSet.difference(want, have)
        extra = MapSet.difference(have, want)

        for(n <- missing, do: "missing alias ci.shard.#{n} (manifest has the shard)") ++
          for(n <- extra, do: "alias ci.shard.#{n} has no matching manifest shard")
    end
  end

  defp shard_alias_keys(aliases) do
    aliases
    |> Keyword.keys()
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "ci.shard."))
  end
end
