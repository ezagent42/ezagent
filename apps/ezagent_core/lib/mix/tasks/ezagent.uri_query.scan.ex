defmodule Mix.Tasks.Ezagent.UriQuery.Scan do
  @shortdoc "Scan URI construction/query violations for unify-uri-query"

  @moduledoc """
  Hard-fail source scan for the unify-uri-query migration.

  PR-0 established the categories in warn-only mode. PR-F flips the whole
  scan to fail CI whenever any violation remains.

  ## Options

    * `--hard-fail` - explicit no-op; the scan now fails by default
    * `--fail-category CATEGORY` - raise if the named category has violations;
      may be passed more than once. PR-B uses
      `--fail-category flavor_prefix_dependency`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {hard_fail?, fail_categories} = parse_args!(args)
    violations = Ezagent.UriQuery.Scan.scan()
    counts = Ezagent.UriQuery.Scan.counts_by_category(violations)

    Mix.shell().info("ezagent.uri_query.scan — #{mode(hard_fail?, fail_categories)}")
    print_summary(violations)

    cond do
      violations == [] ->
        Mix.shell().info("  ✓ no URI-query scan violations")
        :ok

      hard_fail? ->
        Mix.raise("ezagent.uri_query.scan: #{length(violations)} violation(s) remain")

      category_failures?(counts, fail_categories) ->
        Mix.raise("ezagent.uri_query.scan: #{category_failure_message(counts, fail_categories)}")

      fail_categories != [] ->
        Mix.shell().info("  ✓ selected categories clear: #{format_categories(fail_categories)}")
        Mix.shell().info("  ⚠ warn-only: #{length(violations)} violation(s) remain")
        :ok

      true ->
        Mix.shell().info("  ⚠ warn-only: #{length(violations)} violation(s) remain")
        :ok
    end
  end

  defp parse_args!(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [hard_fail: :boolean, fail_category: :string]
      )

    if rest != [] or invalid != [] do
      Mix.raise("ezagent.uri_query.scan: invalid arguments #{inspect(rest ++ invalid)}")
    end

    {Keyword.get(opts, :hard_fail, true), parse_fail_categories!(opts)}
  end

  defp parse_fail_categories!(opts) do
    categories_by_name =
      Ezagent.UriQuery.Scan.known_categories()
      |> Map.new(&{Atom.to_string(&1), &1})

    opts
    |> Keyword.get_values(:fail_category)
    |> Enum.map(fn name ->
      Map.get(categories_by_name, name) ||
        Mix.raise(
          "ezagent.uri_query.scan: unknown category #{inspect(name)}; known categories: " <>
            (categories_by_name |> Map.keys() |> Enum.sort() |> Enum.join(", "))
        )
    end)
    |> Enum.uniq()
  end

  defp mode(true, _fail_categories), do: "hard-fail"

  defp mode(false, []), do: "warn-only"

  defp mode(false, fail_categories),
    do: "category hard-fail (#{format_categories(fail_categories)})"

  defp category_failures?(counts, fail_categories) do
    Enum.any?(fail_categories, &(Map.get(counts, &1, 0) > 0))
  end

  defp category_failure_message(counts, fail_categories) do
    fail_categories
    |> Enum.flat_map(fn category ->
      case Map.get(counts, category, 0) do
        0 -> []
        count -> ["#{category}=#{count}"]
      end
    end)
    |> Enum.join(", ")
    |> then(&"category violation(s) remain: #{&1}")
  end

  defp format_categories(categories) do
    categories
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join(", ")
  end

  defp print_summary([]), do: :ok

  defp print_summary(violations) do
    Mix.shell().info("  violation summary:")

    violations
    |> Ezagent.UriQuery.Scan.counts_by_category()
    |> Enum.sort_by(fn {category, _count} -> to_string(category) end)
    |> Enum.each(fn {category, count} ->
      Mix.shell().info("    #{category}: #{count}")
    end)

    Mix.shell().info("  first violations:")

    violations
    |> Enum.take(20)
    |> Enum.each(fn violation ->
      Mix.shell().info(
        "    #{violation.path}:#{violation.line}:#{violation.category}: #{violation.snippet}"
      )
    end)
  end
end
