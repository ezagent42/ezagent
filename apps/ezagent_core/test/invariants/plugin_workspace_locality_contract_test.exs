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

  @ownership_allowlist [
    %{
      path: "apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex",
      function: {:ensure_session_alive, 1},
      module: Ezagent.WorkspaceRegistry,
      call: {:bind, 2},
      reason: "existing demo session rebind predates Plan C"
    },
    %{
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex",
      function: {:bind_workspace, 2},
      module: Ezagent.WorkspaceRegistry,
      call: {:bind, 2},
      reason: "existing hello session binding predates Plan C"
    },
    %{
      path: "apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex",
      function: {:create_stateless, 2},
      module: Ezagent.WorkspaceRegistry,
      call: {:bind, 2},
      reason: "existing protocol stateless session binding predates Plan C"
    },
    %{
      path: "apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex",
      function: {:create_and_bind, 3},
      module: Ezagent.WorkspaceRegistry,
      call: {:bind, 2},
      reason: "existing protocol conversation session binding predates Plan C"
    }
  ]

  @allowlist [
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex",
      line: 172,
      key: :kind_registry_lookup,
      line_substring: "case Ezagent.KindRegistry.lookup(uri) do",
      reason:
        "read-only seed_status probe needs the registered pid to read the template slice; " <>
          "LocalRuntime has no owner-gated read-with-pid API yet (ensure_started would spawn, " <>
          "kind_alive? drops the pid). Same class as world workspace_plugin_data status reads."
    },
    %{
      path: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      line: 428,
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
      |> Enum.flat_map(fn path ->
        violations_in_file(root, path) ++ ownership_violations_in_file(root, path)
      end)

    assert violations == [],
           """
           Plugin workspace locality contract violations:

           #{format_violations(violations)}

           Workspace-bound plugin side effects must enter owner-gated core APIs.
           Add a centralized allowlist entry only for system-global metadata or
           code that is already owner-gated before this local runtime access.
           """
  end

  test "ownership scanner rejects alias, multiline, import, and apply escapes" do
    mutants = [
      "alias Ezagent.Agent.CreationInventory, as: Inventory\nInventory.record_exact(repo, a, b, c, d)",
      "alias Ezagent.WorkspaceRegistry\nWorkspaceRegistry\n. bind(agent, workspace)",
      "alias Ezagent.{AgentLineage, WorkspaceRegistry}\nAgentLineage.record(agent, root)",
      "import Ezagent.AgentLineage, only: [record_exact: 3]\nrecord_exact(repo, agent, root)",
      "alias Ezagent.Agent.CreationInventory, as: Inventory\napply(Inventory, :record_exact, args)",
      "alias Ezagent.Agent.CreationInventory, as: Inventory\nKernel.apply(Inventory, dynamic_fun, args)",
      "owner = Ezagent.Agent.CreationInventory\napply(owner, :record_exact, args)",
      "registry = Ezagent.WorkspaceRegistry\nregistry.bind(agent, workspace)",
      "alias Ezagent.Agent.CreationInventory, as: Inventory\nowner = Inventory\nquote do: apply(unquote(owner), :record_exact, args)"
    ]

    for source <- mutants do
      assert ownership_calls(source) != [], source
    end

    assert ownership_calls("# Inventory.record_exact(x)\n\"WorkspaceRegistry.bind(x)\"") == []

    safe_rebind =
      "owner = Ezagent.Agent.CreationInventory\nowner = String\napply(owner, :upcase, [\"ok\"])"

    assert ownership_calls(safe_rebind) == []
  end

  test "ownership allowlist is exact by file, enclosing function, module, and call" do
    root = repo_root()

    for entry <- @ownership_allowlist do
      calls =
        root
        |> Path.join(entry.path)
        |> File.read!()
        |> ownership_calls()

      assert Enum.any?(calls, fn call ->
               call.function == entry.function and call.module == entry.module and
                 call.call == entry.call
             end),
             "stale ownership allowlist entry: #{inspect(entry)}"

      assert is_binary(entry.reason) and String.trim(entry.reason) != ""
    end
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

  defp ownership_violations_in_file(root, full_path) do
    path = Path.relative_to(full_path, root)

    full_path
    |> File.read!()
    |> ownership_calls()
    |> Enum.reject(&ownership_allowlisted?(path, &1))
    |> Enum.map(fn call ->
      {path, call.line, :atomic_ownership_access,
       "#{inspect(call.module)}.#{elem(call.call, 0)}/#{elem(call.call, 1)} in #{inspect(call.function)}"}
    end)
  end

  defp ownership_calls(source) do
    ast = Code.string_to_quoted!(source)
    aliases = collect_aliases(ast)
    functions = collect_functions(ast)
    imports = collect_imports(ast, aliases)
    bindings = collect_module_bindings(ast, aliases, functions)

    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _dot_meta, [{:__aliases__, _, [:Kernel]}, :apply]}, meta,
         [module_ast, name_ast, args_ast]} = node,
        calls ->
          line = meta[:line] || 1
          function = enclosing_function(functions, line)

          call =
            dynamic_apply_call(
              module_ast,
              name_ast,
              args_ast,
              line,
              aliases,
              bindings,
              function
            )

          {node, maybe_add_call(calls, call)}

        {{:., _dot_meta, [module_ast, name]}, meta, args} = node, calls
        when is_atom(name) and is_list(args) ->
          line = meta[:line] || 1
          function = enclosing_function(functions, line)
          module = resolve_module(module_ast, aliases, bindings, function, line)
          call = ownership_call(module, name, length(args), line, function)
          {node, maybe_add_call(calls, call)}

        {:apply, meta, [module_ast, name_ast, args_ast]} = node, calls ->
          line = meta[:line] || 1
          function = enclosing_function(functions, line)

          call =
            dynamic_apply_call(
              module_ast,
              name_ast,
              args_ast,
              line,
              aliases,
              bindings,
              function
            )

          {node, maybe_add_call(calls, call)}

        {name, meta, args} = node, calls when is_atom(name) and is_list(args) ->
          imported_module = imported_owner(imports, name, length(args))

          call =
            ownership_call(
              imported_module,
              name,
              length(args),
              meta[:line] || 1,
              enclosing_function(functions, meta[:line] || 1)
            )

          {node, maybe_add_call(calls, call)}

        node, calls ->
          {node, calls}
      end)

    calls |> Enum.uniq() |> Enum.sort_by(&{&1.line, &1.module, &1.call})
  end

  defp collect_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta, [{{:., _, [base_ast, :{}]}, _, children}]} = node, aliases ->
          base = resolve_module(base_ast, aliases)

          aliases =
            Enum.reduce(children, aliases, fn child, acc ->
              child_name = alias_name(child)

              if base && child_name,
                do: Map.put(acc, child_name, Module.concat(base, child_name)),
                else: acc
            end)

          {node, aliases}

        {:alias, _meta, [module_ast]} = node, aliases ->
          module = resolve_module(module_ast, aliases)
          as = module && module |> Module.split() |> List.last()
          {node, if(module && as, do: Map.put(aliases, as, module), else: aliases)}

        {:alias, _meta, [module_ast, opts]} = node, aliases when is_list(opts) ->
          module = resolve_module(module_ast, aliases)
          as_ast = Keyword.get(opts, :as)
          as = alias_name(as_ast) || (module && module |> Module.split() |> List.last())
          {node, if(module && as, do: Map.put(aliases, as, module), else: aliases)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp collect_imports(ast, aliases) do
    {_ast, imports} =
      Macro.prewalk(ast, [], fn
        {:import, _meta, [module_ast | opts]} = node, imports ->
          module = resolve_module(module_ast, aliases)
          only = opts |> List.first([]) |> Keyword.get(:only, :all)
          {node, if(module, do: [{module, only} | imports], else: imports)}

        node, imports ->
          {node, imports}
      end)

    imports
  end

  defp collect_module_bindings(ast, aliases, functions) do
    Enum.reduce(1..3, %{}, fn _pass, bindings ->
      {_ast, next} =
        Macro.prewalk(ast, bindings, fn
          {:=, meta, [{name, _var_meta, context}, rhs]} = node, acc
          when is_atom(name) and (is_atom(context) or is_nil(context)) ->
            function = enclosing_function(functions, meta[:line] || 1)

            line = meta[:line] || 1
            module = resolve_module(rhs, aliases, acc, function, line)
            entries = Map.get(acc, {function, name}, [])
            {node, Map.put(acc, {function, name}, entries ++ [{line, module}])}

          node, acc ->
            {node, acc}
        end)

      next
    end)
  end

  defp collect_functions(ast) do
    {_ast, functions} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [{name, _head_meta, args} | _]} = node, functions
        when kind in [:def, :defp] and is_atom(name) ->
          {node, [{meta[:line] || 1, {name, length(args || [])}} | functions]}

        node, functions ->
          {node, functions}
      end)

    Enum.sort(functions)
  end

  defp resolve_module({:__aliases__, _meta, [first | rest]}, aliases) do
    case Map.get(aliases, Atom.to_string(first)) do
      nil -> Module.concat([first | rest])
      base -> Module.concat([base | rest])
    end
  end

  defp resolve_module(module, _aliases) when is_atom(module), do: module
  defp resolve_module(_module, _aliases), do: nil

  defp resolve_module({:unquote, _meta, [inner]}, aliases, bindings, function, line),
    do: resolve_module(inner, aliases, bindings, function, line)

  defp resolve_module({name, _meta, context}, _aliases, bindings, function, line)
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: binding_at(bindings, {function, name}, line)

  defp resolve_module(module_ast, aliases, _bindings, _function, _line),
    do: resolve_module(module_ast, aliases)

  defp binding_at(bindings, key, line) do
    bindings
    |> Map.get(key, [])
    |> Enum.take_while(fn {binding_line, _module} -> binding_line <= line end)
    |> List.last()
    |> case do
      {_line, module} -> module
      nil -> nil
    end
  end

  defp alias_name({:__aliases__, _meta, [name]}), do: Atom.to_string(name)
  defp alias_name(_ast), do: nil

  defp imported_owner(imports, name, arity) do
    Enum.find_value(imports, fn {module, only} ->
      if only == :all or {name, arity} in only, do: module
    end)
  end

  defp dynamic_apply_call(
         module_ast,
         name_ast,
         args_ast,
         line,
         aliases,
         bindings,
         function
       ) do
    module = resolve_module(module_ast, aliases, bindings, function, line)
    name = if is_atom(name_ast), do: name_ast, else: :__dynamic_apply__
    arity = if is_list(args_ast), do: length(args_ast), else: :dynamic
    ownership_call(module, name, arity, line, function)
  end

  defp ownership_call(nil, _name, _arity, _line, _function), do: nil

  defp ownership_call(module, name, arity, line, function) do
    if forbidden_ownership_call?(module, name) do
      %{
        module: module,
        call: {name, arity},
        line: line,
        function: function
      }
    end
  end

  defp forbidden_ownership_call?(module, _name)
       when module in [
              Ezagent.Agent.CreationInventory,
              Ezagent.AgentLineage,
              Ezagent.WorkspaceRegistry,
              Ezagent.Workspace.TaskWorkspace.Provision,
              Ezagent.Workspace.TaskWorkspace.Store,
              Ezagent.Workspace.TaskWorkspace.LaunchAuthority
            ],
       do: true

  defp forbidden_ownership_call?(Ezagent.Agent.LaunchAuthority, name),
    do: name in [:resolve, :acknowledge, :__dynamic_apply__]

  defp forbidden_ownership_call?(Ezagent.Agent.LaunchCoordinator, name),
    do: name in [:consume_before_start, :__dynamic_apply__]

  defp forbidden_ownership_call?(_module, _name), do: false

  defp enclosing_function(functions, line) do
    functions
    |> Enum.take_while(fn {function_line, _function} -> function_line <= line end)
    |> List.last()
    |> case do
      {_line, function} -> function
      nil -> {:__module__, 0}
    end
  end

  defp maybe_add_call(calls, nil), do: calls
  defp maybe_add_call(calls, call), do: [call | calls]

  defp ownership_allowlisted?(path, call) do
    Enum.any?(@ownership_allowlist, fn entry ->
      entry.path == path and entry.function == call.function and entry.module == call.module and
        entry.call == call.call
    end)
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
