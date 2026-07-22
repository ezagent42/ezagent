defmodule EzagentCore.Invariants.DatabaseAgnosticGuardTest do
  @moduledoc """
  Static guard for database portability.

  This test intentionally does NOT flag the current Ecto adapter choice
  (`Ecto.Adapters.SQLite3`, `ecto_sqlite3`, config, or lockfile entries).
  Those are deployment/configuration facts, not proof that product runtime
  logic is strongly coupled to SQLite.

  The guard only tracks side paths that bypass Ecto's portability layer:

    * direct `Exqlite` references in runtime code
    * SQLite-only SQL/catalog commands such as `PRAGMA` and `sqlite_master`
    * raw SQL parameter placeholders such as `?1` / interpolated `?\#{n}`

  Backup/restore code, historical migrations, and tests are outside this
  audit scope.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  @known_reviewed_dependencies [
    # False positive — `?#{query}` is a URL query-string delimiter with Elixir
    # interpolation, not a SQLite `?1` numbered placeholder.
    {:sqlite_numbered_placeholder,
     "apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_oauth.ex:50"}
  ]

  @excluded_path_parts [
    "/test/",
    "/priv/repo/migrations/",
    "/lib/ezagent/home/migration.ex",
    "/lib/ezagent/persistence/database_diagnostics.ex",
    "/lib/ezagent/persistence/transient_retry.ex",
    "/lib/mix/tasks/ezagent.home.backup.ex",
    "/lib/mix/tasks/ezagent.home.restore.ex",
    # KB retrieval capability (SPEC kb-retrieval-capability §3.6, §4) — the
    # `kb` plugin intentionally uses `Exqlite` DIRECTLY (NOT via Ecto) for the
    # SEPARATE, PORTABLE per-KB sqlite stores. This is the OPPOSITE of an
    # adapter-portability leak: ezagent's OWN DB stays Postgres, and the KB
    # corpus is deliberately ISOLATED into standalone sqlite files that exqlite
    # opens per-file (one sqlite DB per kb-agent does not fit a single bound
    # Ecto.Repo). The direct-Exqlite + FTS5 PRAGMA usage is the sanctioned,
    # reviewed boundary — scoped to this plugin's lib only.
    "/apps/ezagent_plugin_kb/lib/"
  ]

  @sqlite_string_patterns [
    sqlite_catalog: ~r/\bsqlite_master\b/,
    sqlite_pragma: ~r/\bPRAGMA\b/,
    sqlite_maintenance: ~r/\bVACUUM\b|\bwal_checkpoint\b/,
    sqlite_lock_message: ~r/Database busy|database is locked/i,
    sqlite_numbered_placeholder: ~r/\?(?:\d|#\{)/
  ]

  test "runtime database-specific side paths stay reviewed and do not expand" do
    findings = runtime_database_specific_findings()

    known = MapSet.new(@known_reviewed_dependencies)

    assert MapSet.new(findings) == known,
           """
           Runtime database-specific side paths changed.

           This guard tracks code that bypasses Ecto's adapter portability
           layer. Do not add database-specific calls or raw SQL dialect
           syntax in feature code. Prefer Ecto queries/schemas, or isolate
           adapter-specific behavior behind a reviewed boundary.

           If a known dependency was removed, update this baseline and the
           database-agnostic audit document. If a new dependency was added,
           either rewrite it to be database-agnostic or document why the
           adapter boundary is intentional.

           Current findings:
           #{format_findings(findings)}
           """
  end

  defp runtime_database_specific_findings do
    app_source_files()
    |> Enum.flat_map(fn path ->
      relative = Path.relative_to(path, @repo_root)
      source = File.read!(path)

      ast_findings(relative, source) ++ source_line_findings(relative, source)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp app_source_files do
    Path.join([@repo_root, "apps", "**", "*"])
    |> Path.wildcard()
    |> Enum.filter(&String.ends_with?(&1, [".ex", ".exs"]))
    |> Enum.reject(fn path ->
      relative = "/" <> Path.relative_to(path, @repo_root)
      Enum.any?(@excluded_path_parts, &String.contains?(relative, &1))
    end)
  end

  defp ast_findings(relative, source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        {_ast, findings} =
          Macro.prewalk(ast, [], fn
            {:@, meta, [{name, attr_meta, [_doc]}]}, acc when name in [:moduledoc, :doc] ->
              {{:@, meta, [{name, attr_meta, [:__database_guard_doc_skipped__]}]}, acc}

            {:__aliases__, meta, [:Exqlite | _rest]} = node, acc ->
              {node, [finding(:exqlite_driver, relative, meta[:line]) | acc]}

            node, acc ->
              {node, acc}
          end)

        findings

      {:error, _} ->
        []
    end
  end

  defp source_line_findings(relative, source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      trimmed = String.trim_leading(line)

      if String.starts_with?(trimmed, "#") do
        []
      else
        string_pattern_findings(relative, line_no, line)
      end
    end)
  end

  defp string_pattern_findings(relative, line_no, text) do
    @sqlite_string_patterns
    |> Enum.filter(fn {_kind, pattern} -> Regex.match?(pattern, text) end)
    |> Enum.map(fn {kind, _pattern} -> finding(kind, relative, line_no) end)
  end

  defp finding(kind, relative, line_no), do: {kind, "#{relative}:#{line_no}"}

  defp format_findings([]), do: "  none"

  defp format_findings(findings) do
    findings
    |> Enum.map(fn {kind, location} -> "  - #{kind} #{location}" end)
    |> Enum.join("\n")
  end
end
