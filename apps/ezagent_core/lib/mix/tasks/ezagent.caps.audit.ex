defmodule Mix.Tasks.Ezagent.Caps.Audit do
  @shortdoc "Audit which Behaviors implement data_owner/1 (caps-data-ownership-v2)"
  @moduledoc """
  Reports each loaded `Ezagent.*.Behavior.*` module's `data_owner/1`
  status — exists or not.

  Part of caps-data-ownership-v2 PR-OWN-1
  (`docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` §7
  PR-OWN-1). Baseline at PR-OWN-1 merge: 0 production Behaviors
  declare `data_owner/1`. PR-OWN-2..6 sweeps them.

  PR-OWN-FINAL adds `--strict` mode which exits non-zero when any
  Behavior with `cap_subjects/0 != []` lacks `data_owner/1` — that's
  the invariant test the closeout PR ships.

  ## Usage

      mix ezagent.caps.audit            # report (always exits 0)
      mix ezagent.caps.audit --strict   # PR-OWN-FINAL gate: exit
                                        # non-zero on any miss
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    strict? = Enum.member?(args, "--strict")

    rows = collect()

    print_table(rows)

    miss_count = Enum.count(rows, &(&1.cap_subjects? and not &1.data_owner?))

    Mix.shell().info("")

    Mix.shell().info(
      "Summary: #{length(rows)} Behavior modules, #{miss_count} missing data_owner/1."
    )

    if strict? and miss_count > 0 do
      Mix.raise("--strict mode: #{miss_count} Behavior(s) missing data_owner/1")
    end

    :ok
  end

  # Collect every loaded module matching `Ezagent.*.Behavior.*` pattern,
  # plus the bare `Ezagent.Behavior.*` namespace.
  defp collect do
    :code.all_loaded()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&behavior_module?/1)
    |> Enum.map(&audit_row/1)
    |> Enum.sort_by(& &1.module)
  end

  defp behavior_module?(module) when is_atom(module) do
    s = Atom.to_string(module)

    String.starts_with?(s, "Elixir.Ezagent.Behavior.") or
      String.contains?(s, ".Behavior.")
  end

  defp behavior_module?(_), do: false

  defp audit_row(module) do
    %{
      module: module,
      cap_subjects?: cap_subjects?(module),
      data_owner?: function_exported?(module, :data_owner, 1)
    }
  end

  defp cap_subjects?(module) do
    if function_exported?(module, :cap_subjects, 0) do
      try do
        case module.cap_subjects() do
          [] -> false
          [_ | _] -> true
          _ -> false
        end
      rescue
        _ -> false
      end
    else
      false
    end
  end

  defp print_table(rows) do
    Mix.shell().info(String.duplicate("=", 90))

    Mix.shell().info(
      :io_lib.format("~-60s ~-10s ~-15s", ["Behavior module", "caps?", "data_owner?"])
    )

    Mix.shell().info(String.duplicate("-", 90))

    Enum.each(rows, fn row ->
      Mix.shell().info(
        :io_lib.format(
          "~-60s ~-10s ~-15s",
          [
            inspect(row.module),
            bool_str(row.cap_subjects?),
            bool_str(row.data_owner?)
          ]
        )
      )
    end)

    Mix.shell().info(String.duplicate("=", 90))
  end

  defp bool_str(true), do: "yes"
  defp bool_str(false), do: "no"
end
