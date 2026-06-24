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
      path: "apps/ezagent_plugin_advisor/lib/ezagent_plugin_advisor/template/advisor_session.ex",
      line: 132,
      key: :kind_registry_lookup,
      line_substring: "case KindRegistry.lookup(operator_uri) do",
      reason: "existing advisor template operator ensure; pending owner-gated wrapper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex",
      line: 155,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(uri) do",
      reason: "existing orchestrator seed status probe; pending owner-gated read wrapper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex",
      line: 202,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(uri) do",
      reason: "existing orchestrator seed ensure; pending owner-gated ensure wrapper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex",
      line: 207,
      key: :spawn_registry,
      line_substring: "case Ezagent.SpawnRegistry.spawn(uri) do",
      reason: "existing orchestrator seed materialization; pending owner-gated ensure wrapper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      line: 190,
      key: :spawn_registry,
      line_substring: "_ = Ezagent.SpawnRegistry.spawn(session_uri)",
      reason: "existing orchestrator MCP recovery ensure; pending owner-gated wrapper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      line: 191,
      key: :spawn_registry,
      line_substring: "_ = Ezagent.SpawnRegistry.spawn(orchestrator_uri)",
      reason: "existing orchestrator MCP recovery ensure; pending owner-gated wrapper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      line: 357,
      key: :genserver_to_pid,
      line_substring:
        "GenServer.call(pid, {:run_tool, tool, arguments, ctx.bridge_token}, :infinity)",
      reason: "existing SessionManager direct executor call; pending owner-gated executor facade"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/sdk_sidecar.ex",
      line: 72,
      key: :genserver_to_pid,
      line_substring: "GenServer.call(pid, :recent_output, 1_000)",
      reason: "existing sidecar status call; sidecar has no workspace owner facade yet"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/sdk_sidecar.ex",
      line: 86,
      key: :genserver_to_pid,
      line_substring: "GenServer.call(pid, {:query, text, session_id}, timeout)",
      reason: "existing sidecar query call; sidecar has no workspace owner facade yet"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex",
      line: 605,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(agent_uri) do",
      reason: "existing agent liveness probe; pending owner-gated liveness wrapper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/spawn.ex",
      line: 210,
      key: :spawn_registry,
      line_substring: "case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do",
      reason: "existing agent instantiate ensure; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex",
      line: 182,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(agent_uri) do",
      reason: "existing headless agent liveness probe; pending owner-gated liveness wrapper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex",
      line: 91,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(agent_uri) do",
      reason: "existing demo seed local probe; pending owner-gated demo helper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex",
      line: 97,
      key: :spawn_registry,
      line_substring: "case Ezagent.SpawnRegistry.spawn(agent_uri) do",
      reason: "existing demo seed local spawn; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex",
      line: 112,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(session_uri) do",
      reason: "existing demo seed session probe; pending owner-gated demo helper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex",
      line: 120,
      key: :spawn_registry,
      line_substring: "case Ezagent.SpawnRegistry.spawn(session_uri) do",
      reason: "existing demo seed session spawn; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_sandbox.ex",
      line: 218,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(uri) do",
      reason: "existing sandbox seed template probe; pending owner-gated demo helper"
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_sandbox.ex",
      line: 223,
      key: :spawn_registry,
      line_substring: "case Ezagent.SpawnRegistry.spawn(uri) do",
      reason: "existing sandbox seed template spawn; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/bridge_sidecar.ex",
      line: 45,
      key: :genserver_to_pid,
      line_substring: "GenServer.call(pid, :recent_output, 1_000)",
      reason: "existing codex sidecar status call; sidecar has no workspace owner facade yet"
    },
    %{
      path: "apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex",
      line: 555,
      key: :spawn_registry,
      line_substring: "case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do",
      reason: "existing codex instantiate ensure; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex",
      line: 620,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(agent_uri) do",
      reason: "existing codex liveness probe; pending owner-gated liveness wrapper"
    },
    %{
      path: "apps/ezagent_plugin_codex/lib/ezagent/template/codex_remote_agent.ex",
      line: 314,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(agent_uri) do",
      reason: "existing codex remote liveness probe; pending owner-gated liveness wrapper"
    },
    %{
      path: "apps/ezagent_plugin_codex/lib/ezagent/template/codex_remote_agent.ex",
      line: 335,
      key: :spawn_registry,
      line_substring: "case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do",
      reason: "existing codex remote instantiate ensure; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_echo/lib/ezagent/template/echo_agent.ex",
      line: 194,
      key: :spawn_registry,
      line_substring: "case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do",
      reason: "existing echo instantiate ensure; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_echo/lib/ezagent/template/echo_agent.ex",
      line: 248,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(agent_uri) do",
      reason: "existing echo liveness probe; pending owner-gated liveness wrapper"
    },
    %{
      path: "apps/ezagent_plugin_echo/lib/ezagent_plugin_echo/application.ex",
      line: 145,
      key: :spawn_registry,
      line_substring: "with {:ok, _pid} <- Ezagent.SpawnRegistry.spawn(default_uri) do",
      reason: "existing default echo boot spawn; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/binding_policy.ex",
      line: 72,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(uri) do",
      reason: "existing inbound sender ensure; pending owner-gated user ensure wrapper"
    },
    %{
      path: "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/binding_policy.ex",
      line: 77,
      key: :spawn_registry,
      line_substring: "case Ezagent.SpawnRegistry.spawn(uri) do",
      reason: "existing inbound sender spawn; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/sender_resolver.ex",
      line: 65,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(bound_uri) do",
      reason: "existing inbound bound-user probe; pending owner-gated user ensure wrapper"
    },
    %{
      path: "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/sender_resolver.ex",
      line: 70,
      key: :spawn_registry,
      line_substring: "_ = Ezagent.SpawnRegistry.spawn(bound_uri)",
      reason: "existing inbound bound-user spawn; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/template/hello_session.ex",
      line: 41,
      key: :kind_registry_lookup,
      line_substring: "fresh? = KindRegistry.lookup(session_uri) == :error",
      reason: "existing hello template freshness probe; pending owner-gated freshness wrapper"
    },
    %{
      path: "apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex",
      line: 53,
      key: :spawn_registry,
      line_substring: "with {:ok, _pid} <- SpawnRegistry.spawn(session_uri),",
      reason: "existing stateless protocol session spawn; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex",
      line: 90,
      key: :spawn_registry,
      line_substring: "with {:ok, _pid} <- SpawnRegistry.spawn(session_uri),",
      reason: "existing bound protocol session spawn; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path:
        "apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/openai_chat_plug.ex",
      line: 109,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(agent_uri) do",
      reason: "existing protocol API readiness probe; pending owner-gated readiness wrapper"
    },
    %{
      path:
        "apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/openai_chat_plug.ex",
      line: 195,
      key: :spawn_registry,
      line_substring: "case SpawnRegistry.spawn(agent) do",
      reason: "existing protocol API agent spawn; SpawnRegistry is owner-gated in PR1"
    },
    %{
      path: "apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_data.ex",
      line: 122,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(ws.uri) do",
      reason: "existing world read-only liveness display; pending owner-aware status API"
    },
    %{
      path: "apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_data.ex",
      line: 164,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(uri) do",
      reason: "existing world read-only liveness display; pending owner-aware status API"
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
