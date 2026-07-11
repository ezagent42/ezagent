defmodule EzagentCore.Invariants.PluginWorkspaceLocalityContractTest do
  @moduledoc """
  Static plugin contract gate for workspace locality.

  Plugin code must not make workspace-bound local runtime decisions by
  consulting the local Kind registry or locally spawning actors directly. Those
  paths must enter core through owner-gated APIs so a future distributed
  runtime has one place to enforce workspace ownership.
  """

  use ExUnit.Case, async: true

  @forbidden_patterns [
    kind_registry_lookup:
      {~r/(?<![\.\w])(?:Ezagent\.)?KindRegistry\.lookup\s*\(/,
       "Use owner-gated core APIs instead of direct KindRegistry lookup."},
    registry_lookup:
      {~r/(?<![\.\w])Registry\.lookup\s*\(\s*Ezagent\.KindRegistry\s*,/,
       "Use owner-gated core APIs instead of direct Registry lookup."},
    spawn_registry:
      {~r/(?<![\.\w])(?:Ezagent\.)?SpawnRegistry\.spawn(?:_detailed)?\s*\(/,
       "Use an owner-gated core wrapper instead of direct SpawnRegistry calls."},
    genserver_to_pid:
      {~r/(?<![\.\w])GenServer\.(?:call|cast)\s*\(\s*pid\b/,
       "Do not call/cast workspace-bound Kind pids directly from plugins."}
  ]

  @allowlist [
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex",
      line: 169,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(uri) do",
      reason:
        "read-only seed_status probe needs the registered pid to read the template slice; " <>
          "LocalRuntime has no owner-gated read-with-pid API yet (ensure_started would spawn, " <>
          "kind_alive? drops the pid). Same class as world workspace_plugin_data status reads."
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      line: 367,
      key: :genserver_to_pid,
      line_substring:
        "GenServer.call(pid, {:run_tool, tool, arguments, ctx.bridge_token}, :infinity)",
      reason: "existing SessionManager direct executor call; pending owner-gated executor facade"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/sdk_sidecar.ex",
      line: 86,
      key: :genserver_to_pid,
      line_substring: "GenServer.call(pid, :recent_output, 1_000)",
      reason: "existing sidecar status call; sidecar has no workspace owner facade yet"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/sdk_sidecar.ex",
      line: 100,
      key: :genserver_to_pid,
      line_substring: "GenServer.call(pid, {:query, text, session_id}, timeout)",
      reason: "existing sidecar query call; sidecar has no workspace owner facade yet"
    },
    %{
      path: "apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/bridge_sidecar.ex",
      line: 56,
      key: :genserver_to_pid,
      line_substring: "GenServer.call(pid, :recent_output, 1_000)",
      reason: "existing codex sidecar status call; sidecar has no workspace owner facade yet"
    },
    %{
      path: "apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/app_server.ex",
      line: 61,
      key: :genserver_to_pid,
      line_substring: "GenServer.call(pid, :recent_output, 1_000)",
      reason:
        "existing codex app-server sidecar status call (per-agent AppServer GenServer, " <>
          "same class as bridge_sidecar); sidecar has no workspace owner facade yet"
    }
  ]

  test "plugin apps do not bypass workspace owner gate through local runtime APIs" do
    root = repo_root()

    violations =
      root
      |> production_plugin_files()
      |> Enum.flat_map(&violations_in_file(root, &1))

    assert violations == [],
           """
           Plugin workspace locality contract violations:

           #{format_violations(violations)}

           Workspace-bound plugin side effects must enter owner-gated core APIs.
           Add a centralized allowlist entry only for system-global metadata or
           code that is already owner-gated before this local runtime access.
           """
  end

  test "allowlist entries remain exact and justified" do
    root = repo_root()

    for %{path: path, line: line, key: key, line_substring: snippet, reason: reason} <- @allowlist do
      full_path = Path.join(root, path)
      source_line = full_path |> File.read!() |> String.split("\n") |> Enum.at(line - 1, "")

      assert is_binary(reason) and String.trim(reason) != "",
             "allowlist entry #{path}:#{line} #{key} must have a reason"

      assert String.contains?(source_line, snippet),
             """
             stale workspace locality allowlist entry:
               #{path}:#{line} #{key}
             expected line to contain:
               #{snippet}
             actual:
               #{source_line}
             """
    end
  end

  test "allowlisted plugin locality debt is surfaced as warning text" do
    warning = workspace_locality_debt_warning(@allowlist)

    if @allowlist != [] do
      IO.warn(warning)
    end

    assert warning =~ "workspace locality debt"
    assert warning =~ "total=#{length(@allowlist)}"
    assert warning =~ "kind_registry_lookup="
    assert warning =~ "spawn_registry="
    assert warning =~ "genserver_to_pid="
    assert warning =~ "docs/superpowers/specs/2026-06-24-workspace-locality-plugin-contract.md"

    assert workspace_locality_debt_enforced?(%{"ENFORCE_WORKSPACE_LOCALITY_DEBT" => "1"})
    refute workspace_locality_debt_enforced?(%{"ENFORCE_WORKSPACE_LOCALITY_DEBT" => "0"})
    refute workspace_locality_debt_enforced?(%{})

    if @allowlist != [] and workspace_locality_debt_enforced?(System.get_env()) do
      flunk("""
      workspace locality debt enforcement is enabled, but allowlist entries remain.

      #{warning}
      """)
    end
  end

  defp production_plugin_files(root) do
    root
    |> Path.join("apps")
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "ezagent_plugin_"))
    |> Enum.flat_map(fn app ->
      lib_dir = Path.join([root, "apps", app, "lib"])
      if File.dir?(lib_dir), do: list_ex_files(lib_dir), else: []
    end)
    |> Enum.sort()
  end

  defp violations_in_file(root, full_path) do
    rel_path = Path.relative_to(full_path, root)

    full_path
    |> File.read!()
    |> String.split("\n")
    |> source_lines()
    |> Enum.flat_map(fn {line, line_no} ->
      if ignorable_line?(line) do
        []
      else
        Enum.flat_map(@forbidden_patterns, fn {key, {pattern, message}} ->
          if Regex.match?(pattern, line) and not allowlisted?(rel_path, line_no, key, line) do
            [{rel_path, line_no, key, message}]
          else
            []
          end
        end)
      end
    end)
  end

  defp source_lines(lines) do
    {tagged, _in_docstring} =
      lines
      |> Enum.with_index(1)
      |> Enum.map_reduce(false, fn {line, line_no}, in_docstring ->
        starts_docstring? = Regex.match?(~r/@(?:module)?doc\s+"""/, line)
        ends_docstring? = in_docstring and String.contains?(line, ~s("""))
        one_line_docstring? = starts_docstring? and triple_quote_count(line) >= 2

        ignored? = in_docstring or starts_docstring?

        next_in_docstring =
          cond do
            one_line_docstring? -> false
            starts_docstring? -> true
            ends_docstring? -> false
            true -> in_docstring
          end

        {{line, line_no, ignored?}, next_in_docstring}
      end)

    tagged
    |> Enum.reject(fn {_line, _line_no, ignored?} -> ignored? end)
    |> Enum.map(fn {line, line_no, _ignored?} -> {line, line_no} end)
  end

  defp allowlisted?(rel_path, line_no, key, source_line) do
    Enum.any?(@allowlist, fn entry ->
      entry.path == rel_path and entry.line == line_no and entry.key == key and
        String.contains?(source_line, entry.line_substring)
    end)
  end

  defp ignorable_line?(line) do
    String.trim_leading(line) |> String.starts_with?("#")
  end

  defp triple_quote_count(line) do
    Regex.scan(~r/"""/, line) |> length()
  end

  defp format_violations([]), do: "(none)"

  defp format_violations(violations) do
    violations
    |> Enum.map(fn {path, line, key, message} ->
      "  #{path}:#{line} #{key} - #{message}"
    end)
    |> Enum.join("\n")
  end

  defp workspace_locality_debt_warning(allowlist) do
    counts = Enum.frequencies_by(allowlist, & &1.key)

    pattern_summary =
      @forbidden_patterns
      |> Keyword.keys()
      |> Enum.map(fn key -> "#{key}=#{Map.get(counts, key, 0)}" end)
      |> Enum.join(", ")

    entries =
      allowlist
      |> Enum.map(fn entry ->
        "  #{entry.path}:#{entry.line} #{entry.key} - #{entry.reason}"
      end)
      |> Enum.join("\n")

    """
    workspace locality debt: total=#{length(allowlist)} existing plugin local runtime assumptions remain allowlisted.
    This is not a clean pass; it is a visible migration backlog.
    by_pattern: #{pattern_summary}
    contract: docs/superpowers/specs/2026-06-24-workspace-locality-plugin-contract.md
    registry: apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs @allowlist
    enforce: ENFORCE_WORKSPACE_LOCALITY_DEBT=1
    entries:
    #{entries}
    """
  end

  defp workspace_locality_debt_enforced?(env) do
    Map.get(env, "ENFORCE_WORKSPACE_LOCALITY_DEBT") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp list_ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      cond do
        File.dir?(full) -> list_ex_files(full)
        String.ends_with?(entry, ".ex") -> [full]
        true -> []
      end
    end)
  end

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
      {top, 0} ->
        String.trim(top)

      _ ->
        Path.expand("../../../..", __DIR__)
    end
  end
end
