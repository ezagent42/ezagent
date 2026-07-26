defmodule EzagentCore.Invariants.PluginWorkspaceLocalityContractTest do
  @moduledoc """
  Static plugin contract gate for workspace locality.

  Plugin code must not make workspace-bound local runtime decisions by
  consulting the local Kind registry or locally spawning actors directly. Those
  paths must enter core through owner-gated APIs so a future distributed
  runtime has one place to enforce workspace ownership.
  """

  use ExUnit.Case, async: true

  alias EzagentCore.TestSupport.LegacyDynamicReceiverBaseline

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
      path: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/credential_bridge.ex",
      function: {:ensure_source_agent, 1},
      module: Ezagent.AgentLineage,
      call: {:record, 2},
      reason:
        "credential-bridge seeds the system source-credential agent and records its " <>
          "admin-owned lineage on fresh spawn (declared `# derivation-edge: recorded-by " <>
          "AgentLineage.record/2`); same class as hello bind_workspace — the seed path " <>
          "has no owner-gated lineage-record facade yet"
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
    }
    # V5 A1b-rest: the two codex `GenServer.call(pid, :recent_output, …)`
    # entries (bridge_sidecar.ex, app_server.ex) left the allowlist — both
    # sidecars migrated onto the resolver seam (`Resolver.call/3`), so the
    # direct-pid status call debt is GONE, not re-justified.
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
      "alias Ezagent.Agent.CreationInventory, as: Inventory\nowner = Inventory\nquote do: apply(unquote(owner), :record_exact, args)",
      "owner = Ezagent.Agent.CreationInventory\n(fn -> owner = String; owner end).()\napply(owner, :record_exact, args)",
      "owner = Ezagent.Agent.CreationInventory\nif(flag, do: (owner = String))\napply(owner, :record_exact, args)",
      "owner = Ezagent.Agent.CreationInventory\nquote(do: (owner = String))\napply(owner, :record_exact, args)",
      "owner = String\n(fn -> owner = Ezagent.Agent.CreationInventory; apply(owner, :record_exact, args) end).()",
      "owner = String\nif flag, do: (owner = Ezagent.Agent.CreationInventory; apply(owner, :record_exact, args))",
      "owner = String\ncase value do :x -> owner = Ezagent.Agent.CreationInventory; apply(owner, :record_exact, args); _ -> :ok end",
      "owner = String\nquote do owner = Ezagent.Agent.CreationInventory; apply(owner, :record_exact, args) end",
      "(fn -> owner = String end).(); owner = Ezagent.Agent.CreationInventory; apply(owner, :record_exact, args)",
      "owner = if(flag, do: Ezagent.Agent.CreationInventory, else: String); apply(owner, :record_exact, args)",
      "owner = Ezagent.Agent.CreationInventory; if apply(owner, :record_exact, args), do: :ok, else: :error",
      "owner = Ezagent.Agent.CreationInventory; case apply(owner, :record_exact, args) do _ -> :ok end",
      "owner = Ezagent.Agent.CreationInventory; case value do x when apply(owner, :record_exact, args) -> x; _ -> :ok end",
      "owner = if(flag, do: Ezagent.Agent.CreationInventory, else: String); owner.record_exact(repo, a, b, c, d)",
      "with owner <- Ezagent.Agent.CreationInventory do owner.record_exact(repo, a, b, c, d) end",
      "for owner <- [Ezagent.Agent.CreationInventory], do: owner.record_exact(repo, a, b, c, d)",
      "owner = if(flag, do: Ezagent.Agent.CreationInventory, else: String); owner.lookup(value)",
      "owner = if(flag, do: Ezagent.Agent.CreationInventory, else: String); owner.arbitrary(value)",
      "owner = Ezagent.Agent.CreationInventory; with owner <- String, false <- true do :ok else _ -> owner.record_exact(repo, a, b, c, d) end",
      "with {owner, _} <- {Ezagent.Agent.CreationInventory, :ok} do owner.record_exact(repo, a, b, c, d) end",
      "with %{owner: owner} <- %{owner: Ezagent.Agent.CreationInventory} do owner.record_exact(repo, a, b, c, d) end",
      "for {owner, _} <- [{Ezagent.Agent.CreationInventory, :ok}], do: owner.record_exact(repo, a, b, c, d)",
      "for owner <- [String, Ezagent.Agent.CreationInventory], do: owner.arbitrary(value)",
      "configured_module().arbitrary(value)",
      "for owner <- configured_modules(), do: owner.arbitrary(value)",
      "with {owner, _} <- configured_pair() do owner.arbitrary(value) end",
      "apply(configured_module(), :record_exact, args)",
      "owner = configured_module(); apply(owner, :record_exact, args)",
      "Kernel.apply(configured_module(), :record_exact, args)",
      "apply(configured_module(), configured_fun(), configured_args())",
      "def backend, do: Ezagent.Agent.CreationInventory; backend().record_exact(repo, a, b, c, d)",
      "owner = Application.get_env(:app, :ownership_module); owner.record_exact(repo, a, b, c, d)",
      "quote do: unquote(owner).record_exact(repo, a, b, c, d)",
      "owner = configured_module(); owner.rehydrate()",
      "def leak(owner), do: owner.record_exact(repo, a, b, c, d)",
      "def leak(%{owner: owner}), do: owner.rehydrate()"
    ]

    for source <- mutants do
      assert ownership_calls(source) != [], source
    end

    assert ownership_calls("# Inventory.record_exact(x)\n\"WorkspaceRegistry.bind(x)\"") == []

    safe_rebind =
      "owner = Ezagent.Agent.CreationInventory\nowner = String\napply(owner, :upcase, [\"ok\"])"

    assert ownership_calls(safe_rebind) == []
  end

  test "legacy dynamic receiver baseline is exact and changed-line ratcheted" do
    root = repo_root()

    actual =
      root
      |> production_plugin_files()
      |> Enum.flat_map(fn full_path ->
        path = Path.relative_to(full_path, root)

        full_path
        |> File.read!()
        |> ownership_calls()
        |> Enum.filter(&(&1.module == :unknown_value))
        |> Enum.map(&legacy_site(path, &1))
      end)
      |> Enum.sort()

    assert actual == Enum.sort(LegacyDynamicReceiverBaseline.sites())

    [site | rest] = actual
    refute site in rest
    refute put_elem(site, 1, elem(site, 1) + 1) in actual
    refute put_elem(site, 5, String.duplicate("0", 64)) in actual
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
    |> Enum.reject(&legacy_receiver_baseline?(path, &1))
    |> Enum.reject(&ownership_allowlisted?(path, &1))
    |> Enum.map(fn call ->
      {path, call.line, :atomic_ownership_access,
       "#{inspect(call.module)}.#{elem(call.call, 0)}/#{elem(call.call, 1)} in #{inspect(call.function)}"}
    end)
  end

  defp ownership_calls(source) do
    ast = Code.string_to_quoted!(source)
    aliases = collect_aliases(ast)
    imports = collect_imports(ast, aliases)
    {_env, calls} = ownership_scan(ast, %{}, aliases, imports, {:__module__, 0}, [])

    lines = String.split(source, "\n")

    calls
    |> Enum.uniq()
    |> Enum.map(fn call ->
      source_line = Enum.at(lines, call.line - 1, "")
      Map.put(call, :line_fingerprint, sha256(source_line))
    end)
    |> Enum.sort_by(&{&1.line, &1.module, &1.call})
  end

  defp legacy_receiver_baseline?(path, %{module: :unknown_value} = call),
    do: legacy_site(path, call) in LegacyDynamicReceiverBaseline.sites()

  defp legacy_receiver_baseline?(_path, _call), do: false

  defp legacy_site(path, call) do
    {name, arity} = call.call
    kind = if name == :__dynamic_apply__, do: :apply, else: :remote
    {path, call.line, call.function, kind, "#{name}/#{arity}", call.line_fingerprint}
  end

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp ownership_scan({:__block__, _, nodes}, env, aliases, imports, function, calls) do
    Enum.reduce(nodes, {env, calls}, fn node, {next_env, next_calls} ->
      ownership_scan(node, next_env, aliases, imports, function, next_calls)
    end)
  end

  defp ownership_scan({kind, _, [{name, _, args}, body]}, env, aliases, imports, _function, calls)
       when kind in [:def, :defp] and is_atom(name) do
    env = bind_data_patterns(args || [], env)

    {_child_env, calls} =
      ownership_scan(body, env, aliases, imports, {name, length(args || [])}, calls)

    {env, calls}
  end

  defp ownership_scan(
         {kind, _, [{:when, _, [{name, _, args} | _guards]}, body]},
         env,
         aliases,
         imports,
         _function,
         calls
       )
       when kind in [:def, :defp] and is_atom(name) do
    env = bind_data_patterns(args || [], env)

    {_child_env, calls} =
      ownership_scan(body, env, aliases, imports, {name, length(args || [])}, calls)

    {env, calls}
  end

  defp ownership_scan({:=, _, [{name, _, context}, rhs]}, env, aliases, imports, function, calls)
       when is_atom(name) and (is_atom(context) or is_nil(context)) do
    {_rhs_env, calls} = ownership_scan(rhs, env, aliases, imports, function, calls)
    {Map.put(env, name, receiver_value(rhs, env, aliases)), calls}
  end

  defp ownership_scan({:<-, _, [pattern, rhs]}, env, aliases, imports, function, calls) do
    {_rhs_env, calls} = ownership_scan(rhs, env, aliases, imports, function, calls)
    {bind_ownership_pattern(pattern, generator_element(rhs), env, aliases), calls}
  end

  defp ownership_scan({:fn, _, clauses}, env, aliases, imports, function, calls) do
    {_child_env, calls} =
      ownership_clause_join(clauses, env, aliases, imports, function, calls)

    {env, calls}
  end

  defp ownership_scan({:quote, _, args}, env, aliases, imports, function, calls) do
    calls = scan_ownership_children(args, env, aliases, imports, function, calls)
    {env, calls}
  end

  defp ownership_scan({:if, _, [condition, opts]}, env, aliases, imports, function, calls) do
    {env, calls} = ownership_scan(condition, env, aliases, imports, function, calls)

    ownership_branch_join(
      [Keyword.get(opts, :do), Keyword.get(opts, :else)],
      env,
      aliases,
      imports,
      function,
      calls,
      true
    )
  end

  defp ownership_scan({:case, _, [subject, opts]}, env, aliases, imports, function, calls) do
    {env, calls} = ownership_scan(subject, env, aliases, imports, function, calls)
    ownership_clause_join(Keyword.get(opts, :do, []), env, aliases, imports, function, calls)
  end

  defp ownership_scan({:cond, _, [opts]}, env, aliases, imports, function, calls),
    do: ownership_clause_join(Keyword.get(opts, :do, []), env, aliases, imports, function, calls)

  defp ownership_scan({:with, _, args}, env, aliases, imports, function, calls) do
    opts = List.last(args)

    {with_env, calls} =
      ownership_scan(Enum.drop(args, -1), env, aliases, imports, function, calls)

    {_, calls} =
      ownership_scan(Keyword.get(opts, :do), with_env, aliases, imports, function, calls)

    {_else_env, calls} =
      ownership_clause_join(
        Keyword.get(opts, :else, []),
        env,
        aliases,
        imports,
        function,
        calls
      )

    {env, calls}
  end

  defp ownership_scan({:for, _, args}, env, aliases, imports, function, calls) do
    {_child_env, child_calls} = ownership_scan(args, env, aliases, imports, function, calls)
    {env, child_calls}
  end

  defp ownership_scan({kind, _, [opts]}, env, aliases, imports, function, calls)
       when kind in [:try, :receive] and is_list(opts) do
    ordinary = [:do, :after] |> Enum.map(&Keyword.get(opts, &1)) |> Enum.reject(&is_nil/1)

    clauses =
      [:rescue, :catch, :else, :do, :after]
      |> Enum.flat_map(&List.wrap(Keyword.get(opts, &1, [])))
      |> Enum.filter(&match?({:->, _, _}, &1))

    {_env, calls} = ownership_branch_join(ordinary, env, aliases, imports, function, calls, false)
    {_env, calls} = ownership_clause_join(clauses, env, aliases, imports, function, calls)
    {env, calls}
  end

  defp ownership_scan(
         {{:., _, [kernel, :apply]}, meta, [module_ast, name_ast, args_ast]} = node,
         env,
         aliases,
         imports,
         function,
         calls
       ) do
    if resolve_module(kernel, aliases) == Kernel do
      call = dynamic_ownership_call(module_ast, name_ast, args_ast, meta, env, aliases, function)
      {env, maybe_add_call(calls, call)}
    else
      scan_ownership_children(Tuple.to_list(node), env, aliases, imports, function, calls)
      |> then(&{env, &1})
    end
  end

  defp ownership_scan(
         {:apply, meta, [module_ast, name_ast, args_ast]},
         env,
         aliases,
         _imports,
         function,
         calls
       ) do
    call = dynamic_ownership_call(module_ast, name_ast, args_ast, meta, env, aliases, function)
    {env, maybe_add_call(calls, call)}
  end

  defp ownership_scan(
         {{:., _, [module_ast, name]}, meta, args},
         env,
         aliases,
         imports,
         function,
         calls
       )
       when is_atom(name) and is_list(args) do
    module = receiver_value(module_ast, env, aliases)
    call = ownership_call(module, name, length(args), meta[:line] || 1, function)

    calls =
      scan_ownership_children(args, env, aliases, imports, function, maybe_add_call(calls, call))

    {env, calls}
  end

  defp ownership_scan({name, meta, args}, env, aliases, imports, function, calls)
       when is_atom(name) and is_list(args) do
    call =
      ownership_call(
        imported_owner(imports, name, length(args)),
        name,
        length(args),
        meta[:line] || 1,
        function
      )

    {env,
     scan_ownership_children(args, env, aliases, imports, function, maybe_add_call(calls, call))}
  end

  defp ownership_scan(nodes, env, aliases, imports, function, calls) when is_list(nodes) do
    Enum.reduce(nodes, {env, calls}, fn node, {next_env, next_calls} ->
      ownership_scan(node, next_env, aliases, imports, function, next_calls)
    end)
  end

  defp ownership_scan(node, env, aliases, imports, function, calls) do
    children =
      if is_tuple(node), do: Tuple.to_list(node), else: if(is_list(node), do: node, else: [])

    {env, scan_ownership_children(children, env, aliases, imports, function, calls)}
  end

  defp bind_data_patterns(patterns, env) do
    Enum.reduce(List.wrap(patterns), env, &bind_data_pattern/2)
  end

  defp bind_data_pattern({:when, _, [pattern | _guards]}, env),
    do: bind_data_pattern(pattern, env)

  defp bind_data_pattern({:=, _, [left, right]} = pattern, env) do
    value = if data_pattern?(left) or data_pattern?(right), do: :safe_data, else: :unknown_value
    Enum.reduce(variables_in(pattern), env, &Map.put(&2, &1, value))
  end

  defp bind_data_pattern(pattern, env) do
    value = if data_pattern?(pattern), do: :safe_data, else: :unknown_value
    Enum.reduce(variables_in(pattern), env, &Map.put(&2, &1, value))
  end

  defp data_pattern?({:%, _, [_module, {:%{}, _, _fields}]}), do: true
  defp data_pattern?({:%{}, _, _fields}), do: true
  defp data_pattern?({:{}, _, _items}), do: true
  defp data_pattern?(pattern) when is_tuple(pattern) and tuple_size(pattern) != 3, do: true
  defp data_pattern?(pattern) when is_list(pattern), do: true
  defp data_pattern?(_pattern), do: false

  defp ownership_branch_join(branches, env, aliases, imports, function, calls, include_missing?) do
    branches = Enum.reject(branches, &is_nil/1)

    ownership_branch_join_nonempty(
      branches,
      env,
      aliases,
      imports,
      function,
      calls,
      include_missing?
    )
  end

  defp ownership_branch_join_nonempty(
         [],
         env,
         _aliases,
         _imports,
         _function,
         calls,
         _include_missing?
       ),
       do: {env, calls}

  defp ownership_branch_join_nonempty(
         branches,
         env,
         aliases,
         imports,
         function,
         calls,
         include_missing?
       ) do
    results = Enum.map(branches, &ownership_scan(&1, env, aliases, imports, function, calls))
    branch_envs = Enum.map(results, &elem(&1, 0))

    branch_envs =
      if include_missing? and length(branches) < 2, do: [env | branch_envs], else: branch_envs

    {merge_ownership_envs(branch_envs), Enum.flat_map(results, &elem(&1, 1)) |> Enum.uniq()}
  end

  defp ownership_clause_join(clauses, env, aliases, imports, function, calls) do
    ownership_clause_join_nonempty(List.wrap(clauses), env, aliases, imports, function, calls)
  end

  defp ownership_clause_join_nonempty([], env, _aliases, _imports, _function, calls),
    do: {env, calls}

  defp ownership_clause_join_nonempty(clauses, env, aliases, imports, function, calls) do
    results =
      Enum.map(clauses, fn
        {:->, _, [patterns, body]} ->
          binding_patterns =
            Enum.map(patterns, fn
              {:when, _, [pattern | _guards]} -> pattern
              pattern -> pattern
            end)

          branch_env = bind_data_patterns(binding_patterns, env)

          {branch_env, branch_calls} =
            ownership_scan(patterns, branch_env, aliases, imports, function, calls)

          ownership_scan(body, branch_env, aliases, imports, function, branch_calls)

        other ->
          ownership_scan(other, env, aliases, imports, function, calls)
      end)

    {merge_ownership_envs(Enum.map(results, &elem(&1, 0))),
     Enum.flat_map(results, &elem(&1, 1)) |> Enum.uniq()}
  end

  defp scan_ownership_children(nodes, env, aliases, imports, function, calls) do
    Enum.reduce(List.wrap(nodes), calls, fn child, acc ->
      {_child_env, next} = ownership_scan(child, env, aliases, imports, function, acc)
      next
    end)
  end

  defp merge_ownership_envs([]), do: %{}

  defp merge_ownership_envs([first | rest]) do
    keys = [first | rest] |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

    Enum.reduce(keys, %{}, fn key, acc ->
      values = Enum.map([first | rest], &Map.get(&1, key))
      distinct = Enum.uniq(values)

      value =
        cond do
          length(distinct) == 1 -> hd(distinct)
          Enum.any?(distinct, &module_abstract?/1) -> :unknown
          true -> :unknown_value
        end

      Map.put(acc, key, value)
    end)
  end

  defp ownership_value({:unquote, _, [inner]}, env, aliases),
    do: ownership_value(inner, env, aliases)

  defp ownership_value({:if, _, [_condition, opts]}, env, aliases) do
    values =
      [Keyword.get(opts, :do), Keyword.get(opts, :else)]
      |> Enum.map(&ownership_value(&1, env, aliases))

    if Enum.uniq(values) |> length() == 1, do: hd(values), else: :unknown
  end

  defp ownership_value({name, _, context}, env, _aliases)
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: Map.get(env, name)

  defp ownership_value({{:., _, [receiver, _field]}, _, []}, env, aliases) do
    if receiver_value(receiver, env, aliases) == :safe_data, do: :safe_data
  end

  defp ownership_value(value, _env, _aliases)
       when is_binary(value) or is_number(value) or is_list(value),
       do: :safe_data

  defp ownership_value(module, _env, _aliases) when is_atom(module), do: module

  defp ownership_value(ast, _env, aliases), do: resolve_module(ast, aliases)

  defp receiver_value(ast, env, aliases),
    do: ownership_value(ast, env, aliases) || :unknown_value

  defp generator_element([value]), do: value
  defp generator_element(values) when is_list(values), do: {:__joined_elements__, [], values}
  defp generator_element(value), do: value

  defp bind_ownership_pattern({name, _, context}, rhs, env, aliases)
       when is_atom(name) and name != :_ and (is_atom(context) or is_nil(context)),
       do: Map.put(env, name, ownership_abstract_value(rhs, env, aliases))

  defp bind_ownership_pattern({:{}, _, patterns}, {:{}, _, values}, env, aliases)
       when length(patterns) == length(values),
       do:
         Enum.zip(patterns, values)
         |> Enum.reduce(env, fn {pattern, value}, acc ->
           bind_ownership_pattern(pattern, value, acc, aliases)
         end)

  defp bind_ownership_pattern(patterns, values, env, aliases)
       when is_tuple(patterns) and is_tuple(values) and tuple_size(patterns) == tuple_size(values) and
              tuple_size(patterns) != 3,
       do: bind_ownership_pattern(Tuple.to_list(patterns), Tuple.to_list(values), env, aliases)

  defp bind_ownership_pattern({:%{}, _, patterns}, {:%{}, _, values}, env, aliases),
    do:
      Enum.reduce(patterns, env, fn {key, pattern}, acc ->
        bind_ownership_pattern(pattern, Keyword.get(values, key), acc, aliases)
      end)

  defp bind_ownership_pattern({:|, _, [head, tail]}, [first | rest], env, aliases) do
    env = bind_ownership_pattern(head, first, env, aliases)
    bind_ownership_pattern(tail, rest, env, aliases)
  end

  defp bind_ownership_pattern(patterns, values, env, aliases)
       when is_list(patterns) and is_list(values) and length(patterns) == length(values),
       do:
         Enum.zip(patterns, values)
         |> Enum.reduce(env, fn {pattern, value}, acc ->
           bind_ownership_pattern(pattern, value, acc, aliases)
         end)

  defp bind_ownership_pattern(pattern, rhs, env, aliases) do
    value = ownership_abstract_value(rhs, env, aliases)
    Enum.reduce(variables_in(pattern), env, &Map.put(&2, &1, value))
  end

  defp ownership_abstract_value({:__joined_elements__, _, values}, env, aliases) do
    values = Enum.map(values, &ownership_abstract_value(&1, env, aliases)) |> Enum.uniq()
    if length(values) == 1, do: hd(values), else: :unknown
  end

  defp ownership_abstract_value(rhs, env, aliases) do
    resolved = ownership_value(rhs, env, aliases)
    resolved || :unknown_value
  end

  defp module_abstract?(value) when is_atom(value),
    do: value == :unknown or String.starts_with?(Atom.to_string(value), "Elixir.")

  defp module_abstract?(_value), do: false

  defp variables_in(node) do
    {_node, variables} =
      Macro.prewalk(node, MapSet.new(), fn
        {name, _meta, context} = variable, acc
        when is_atom(name) and name != :_ and (is_atom(context) or is_nil(context)) ->
          {variable, MapSet.put(acc, name)}

        child, acc ->
          {child, acc}
      end)

    variables
  end

  defp dynamic_ownership_call(module_ast, name_ast, args_ast, meta, env, aliases, function) do
    module = receiver_value(module_ast, env, aliases)
    name = if is_atom(name_ast), do: name_ast, else: :__dynamic_apply__
    arity = if is_list(args_ast), do: length(args_ast), else: :dynamic

    ownership_call(module, name, arity, meta[:line] || 1, function) ||
      if(module in [:unknown, :unknown_value],
        do: %{module: module, call: {name, arity}, line: meta[:line] || 1, function: function}
      )
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

  defp resolve_module({:__aliases__, _meta, [first | rest]}, aliases) do
    case Map.get(aliases, Atom.to_string(first)) do
      nil -> Module.concat([first | rest])
      base -> Module.concat([base | rest])
    end
  end

  defp resolve_module(module, _aliases) when is_atom(module), do: module
  defp resolve_module(_module, _aliases), do: nil

  defp alias_name({:__aliases__, _meta, [name]}), do: Atom.to_string(name)
  defp alias_name(_ast), do: nil

  defp imported_owner(imports, name, arity) do
    Enum.find_value(imports, fn {module, only} ->
      if only == :all or {name, arity} in only, do: module
    end)
  end

  defp ownership_call(nil, _name, _arity, _line, _function), do: nil

  defp ownership_call(:unknown, name, arity, line, function),
    do: %{module: :unknown, call: {name, arity}, line: line, function: function}

  defp ownership_call(:unknown_value, name, arity, line, function),
    do: %{module: :unknown_value, call: {name, arity}, line: line, function: function}

  defp ownership_call(:safe_data, name, arity, line, function),
    do: %{module: :unknown_value, call: {name, arity}, line: line, function: function}

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
