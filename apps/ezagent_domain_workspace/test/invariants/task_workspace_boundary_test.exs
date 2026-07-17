defmodule Ezagent.Workspace.TaskWorkspace.BoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_secret_field ~r/(^|_)(access_token|auth_blob|key_material|credential_ref|authorization_header|private_key|secret|credential|environment)($|_)/
  @lifecycle_fields ~w(claim_token start_token start_claim_token start_token_consumed_at cleanup_reason cleaned_at)
  @migration_paths ~w(
    apps/ezagent_core/priv/repo_pg/migrations/20260717001000_create_git_task_workspace_provisions.exs
    apps/ezagent_core/priv/repo_pg/migrations/20260717002000_add_checkout_fingerprint_to_git_task_workspace_provisions.exs
    apps/ezagent_core/priv/repo_pg/migrations/20260717003000_add_retirement_handle_to_git_task_workspace_provisions.exs
    apps/ezagent_core/priv/repo_pg/migrations/20260717004000_harden_git_task_workspace_start.exs
  )
  @ownership_migration_paths ~w(
    apps/ezagent_core/priv/repo_pg/migrations/20260715001000_agent_creation_inventory.exs
    apps/ezagent_core/priv/repo_pg/migrations/20260717004000_harden_git_task_workspace_start.exs
  )
  @plan_c_migrations ~w(
    20260717001000_create_git_task_workspace_provisions.exs
    20260717002000_add_checkout_fingerprint_to_git_task_workspace_provisions.exs
    20260717003000_add_retirement_handle_to_git_task_workspace_provisions.exs
    20260717004000_harden_git_task_workspace_start.exs
  )
  @launch_context_allowlist [
    {"apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex", {:before_start, 1}, :authored_map,
     58},
    {"apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex",
     {:prepare, 1}, :authored_map, 23}
  ]

  test "cc plugin has no task-workspace transport knowledge" do
    refute_source_under(
      "apps/ezagent_plugin_cc/lib",
      ~r/WorkspaceProvision|TaskWorkspace|task_workspace_provisions|git\s+(clone|worktree)/
    )
  end

  test "workspace domain never invokes provider adapters" do
    refute_source_under(
      "apps/ezagent_domain_workspace/lib",
      ~r/AdapterRegistry|\.create_change_request\(|\.resolve_repository\(/
    )
  end

  test "workspace provision registry implementation is consumed only by its ActionSet" do
    assert_only_production_calls("WorkspaceProvisionRegistry.implementation", [
      "apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex"
    ])
  end

  test "authorized workspace request constructor is called only by its ActionSet" do
    assert_only_production_calls("Request.new_authorized", [
      "apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex"
    ])
  end

  test "durable provision schema contains no credential material" do
    refute_secret_schema_and_migration_fields()
  end

  test "secret field scanner parses all supported schema and migration call syntaxes" do
    for source <- [
          "field(:credential_ref, :string)",
          "field :credential_ref, :string",
          "add(:credential_ref, :text)",
          "add :credential_ref, :text"
        ] do
      assert extract_call_names(source) == ["credential_ref"]
      assert forbidden_field_names(extract_call_names(source)) == ["credential_ref"]
    end
  end

  test "secret field scanner allows exact lifecycle names but rejects deceptive variants" do
    source = """
    field(:claim_token, :string)
    field :start_token, :string
    add(:cleanup_reason, :text)
    add :claim_token_credential_ref, :text
    "field(:credential_ref, :string)"
    # add :private_key, :text
    """

    assert extract_call_names(source) == [
             "claim_token",
             "start_token",
             "cleanup_reason",
             "claim_token_credential_ref"
           ]

    assert forbidden_field_names(extract_call_names(source)) == ["claim_token_credential_ref"]
  end

  test "task workspace start bridge has exact production call sites" do
    assert_only_production_calls("pre_start_ref:", [
      "apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/agent_start.ex"
    ])

    assert_only_production_calls("AgentStart.start(", [])

    assert_only_production_calls("LaunchAuthority.issue(", [
      "apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex"
    ])
  end

  test "core transports launch context without inspecting its value" do
    offenders =
      for path <- source_files("apps/ezagent_core/lib"),
          read <- opaque_context_reads(File.read!(project_path(path))),
          do: {path, read}

    assert offenders == []
  end

  test "launch context stays out of authored, serialized, logged, and process data" do
    offenders =
      for path <- production_source_files(),
          leak <- launch_context_leaks(File.read!(project_path(path)), path),
          do: {path, leak}

    assert offenders == []
  end

  test "launch context scanner rejects authored, rebound, durable, process, and rendered sinks" do
    mutants = [
      "%{launch_context: launch_context}",
      "%{\"launch_context\" => launch_context}",
      "opaque = Keyword.fetch!(opts, :launch_context)\nRepo.insert!(%Row{value: opaque})",
      "alias EzagentCore.Repo, as: Storage\nopaque = Keyword.fetch!(opts, :launch_context)\nStorage.insert!(%Row{value: opaque})",
      "opaque = Keyword.fetch!(opts, :launch_context)\nEcto.Multi.put(multi, :context, opaque)",
      "opaque = Keyword.fetch!(opts, :launch_context)\nEzagent.SnapshotStore.write(uri, :slice, opaque)",
      "opaque = Keyword.fetch!(opts, :launch_context)\n:persistent_term.put(:context, opaque)",
      "opaque = Keyword.fetch!(opts, :launch_context)\n:ets.insert(:contexts, {:context, opaque})",
      "opaque = Keyword.fetch!(opts, :launch_context)\nProcess.put(:context, opaque)",
      "opaque = Keyword.fetch!(opts, :launch_context)\nMap.put(state, :context, opaque)",
      "opaque = Keyword.fetch!(opts, :launch_context)\nsend(pid, {:context, opaque})",
      "opaque = Keyword.fetch!(opts, :launch_context)\nSystem.cmd(\"tool\", [inspect(opaque)])",
      "opaque = Keyword.fetch!(opts, :launch_context)\nSystem.put_env(\"CONTEXT\", inspect(opaque))",
      "opaque = Keyword.fetch!(opts, :launch_context)\nApplication.put_env(:app, :context, opaque)",
      "opaque = Keyword.fetch!(opts, :launch_context)\nLogger.info(\"context=\#{inspect(opaque)}\")",
      "opaque = Keyword.fetch!(opts, :launch_context)\n:telemetry.execute([:launch], %{}, %{context: opaque})",
      "opaque = Keyword.fetch!(opts, :launch_context)\nJason.encode!(%{context: opaque})",
      "serializer = Jason\nopaque = Keyword.fetch!(opts, :launch_context)\nserializer.encode!(%{context: opaque})",
      "opaque = Keyword.fetch!(opts, :launch_context)\nraise \"bad context \#{inspect(opaque)}\"",
      "def instantiate(_a, _b, _c, opts) do\n  handle = Keyword.fetch!(opts, :launch_context)\n  Jason.encode!(%{context: handle})\nend",
      "def instantiate(_a, _b, _c, opts) do\n  handle = Map.get(opts, :launch_context)\n  Repo.insert!(%Row{value: handle})\nend",
      "def instantiate(_a, _b, _c, launch_context: handle) do\n  payload = handle\n  :persistent_term.put(:context, payload)\nend",
      "def leak(opts) do\n  handle = Keyword.fetch!(opts, :launch_context)\n  (fn -> handle = :safe_value end).()\n  Jason.encode!(handle)\nend",
      "def leak(opts) do\n  serializer = Jason\n  handle = Keyword.fetch!(opts, :launch_context)\n  serializer.encode!(handle)\n  serializer = String\nend",
      "def leak(opts) do\n  handle = Keyword.fetch!(opts, :launch_context)\n  sink(handle)\nend\ndefp sink(value), do: Jason.encode!(value)",
      "def leak(opts) do handle = Keyword.fetch!(opts, :launch_context); if flag, do: Jason.encode!(handle), else: :ok end",
      "def leak(opts) do handle = Keyword.fetch!(opts, :launch_context); sink1(:safe, handle) end\ndefp sink1(_a, value), do: sink2(value)\ndefp sink2(value), do: sink3(value)\ndefp sink3(value), do: sink4(value)\ndefp sink4(value), do: sink5(value)\ndefp sink5(value), do: sink6(value)\ndefp sink6(value), do: Jason.encode!(value)",
      "def leak(opts) do handle = Keyword.fetch!(opts, :launch_context); serializer = if(flag, do: Jason, else: String); serializer.encode!(handle) end",
      "def leak(opts) do handle = Keyword.fetch!(opts, :launch_context); if Jason.encode!(handle), do: :ok, else: :error end",
      "def leak(opts) do handle = Keyword.fetch!(opts, :launch_context); case Jason.encode!(handle) do _ -> :ok end end",
      "def leak(opts) do handle = Keyword.fetch!(opts, :launch_context); case value do x when Jason.encode!(handle) -> x; _ -> :ok end end"
    ]

    for source <- mutants do
      assert launch_context_leaks(source) != [], source
    end

    assert launch_context_leaks("def harmless(launch_context), do: Jason.encode!(launch_context)") ==
             []

    shadowed = """
    def harmless(opts) do
      handle = Keyword.fetch!(opts, :launch_context)
      handle = :safe_value
      Jason.encode!(handle)
    end
    """

    assert launch_context_leaks(shadowed) == []

    safe_sink_rebind = """
    def harmless(opts) do
      serializer = Jason
      handle = Keyword.fetch!(opts, :launch_context)
      serializer = String
      serializer.upcase(handle)
    end
    """

    assert launch_context_leaks(safe_sink_rebind) == []

    branch_shadow = """
    def harmless(opts) do
      handle = Keyword.fetch!(opts, :launch_context)
      if flag do
        handle = :safe
        Jason.encode!(handle)
      else
        :ok
      end
    end
    """

    assert launch_context_leaks(branch_shadow) == []

    for_shadow =
      "def harmless(opts) do handle = Keyword.fetch!(opts, :launch_context); for x <- xs, do: (handle = :safe); Jason.encode!(handle) end"

    try_shadow =
      "def harmless(opts) do handle = Keyword.fetch!(opts, :launch_context); try do handle = :safe rescue _ -> :ok end; Jason.encode!(handle) end"

    receive_shadow =
      "def harmless(opts) do handle = Keyword.fetch!(opts, :launch_context); receive do _ -> handle = :safe after 0 -> :ok end; Jason.encode!(handle) end"

    for source <- [for_shadow, try_shadow, receive_shadow] do
      assert launch_context_leaks(source) != [], source
    end

    second_map = """
    def prepare(ref) do
      handle = Keyword.fetch!(ref, :launch_context)
      safe = %{launch_context: handle}
      Jason.encode!(safe)
    end
    """

    assert launch_context_leaks(
             second_map,
             "apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex"
           ) != []
  end

  test "ownership schemas contain no secret material and no forbidden follow-up migration" do
    names =
      Enum.flat_map(@ownership_migration_paths, fn path ->
        path
        |> project_path()
        |> File.read!()
        |> extract_call_names([:add])
      end)

    inventory_schema_names =
      "apps/ezagent_domain_agent/lib/ezagent/agent/creation_inventory_entry.ex"
      |> project_path()
      |> File.read!()
      |> extract_call_names([:field])

    assert forbidden_field_names(names ++ inventory_schema_names) == []

    migration_names =
      project_path("apps/ezagent_core/priv/repo_pg/migrations/*.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)

    assert forbidden_plan_c_migrations(migration_names) == []

    assert forbidden_plan_c_migrations(@plan_c_migrations ++ ["20260718001000_more_receipts.exs"]) ==
             [
               "20260718001000_more_receipts.exs"
             ]
  end

  test "core template vocabulary remains domain neutral" do
    refute_source_under(
      "apps/ezagent_core/lib/ezagent/kind/template",
      ~r/Git|Workspace|Task|provider|flavor|recipe|plugin/
    )
  end

  test "production pre-start has no configurable runner seam" do
    refute_source_under(
      "apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex",
      ~r/Application\.get_env[\s\S]*task_workspace_git_runner/
    )
  end

  test "task workspace production code uses approved URI parsers" do
    offenders =
      for path <-
            source_files("apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace"),
          Regex.match?(~r/(?<!Ezagent\.)\bURI\.new!?\(/, File.read!(project_path(path))),
          do: path

    assert offenders == []
  end

  defp source_files(root) do
    absolute = project_path(root)

    if File.regular?(absolute) do
      [root]
    else
      absolute
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, project_root()))
    end
  end

  defp production_source_files do
    project_path("apps/*/lib/**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, project_root()))
  end

  defp refute_source_under(root, regex) do
    offenders =
      for path <- source_files(root),
          Regex.match?(regex, File.read!(project_path(path))),
          do: path

    assert offenders == []
  end

  defp assert_only_production_calls(needle, allowed) do
    callers =
      for absolute <- Path.wildcard(project_path("apps/*/lib/**/*.{ex,exs}")),
          String.contains?(File.read!(absolute), needle),
          path = Path.relative_to(absolute, project_root()),
          do: path

    assert Enum.sort(callers) == Enum.sort(allowed)
  end

  defp refute_secret_schema_and_migration_fields do
    schema_names =
      "apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provision.ex"
      |> project_path()
      |> File.read!()
      |> extract_call_names([:field])

    migration_names =
      Enum.flat_map(@migration_paths, fn path ->
        path
        |> project_path()
        |> File.read!()
        |> extract_call_names([:add])
      end)

    names = Enum.uniq(schema_names ++ migration_names)
    forbidden = forbidden_field_names(names)

    assert length(schema_names) == 30
    assert length(migration_names) == 30
    assert Enum.all?(@lifecycle_fields, &(&1 in names))
    assert forbidden == []
  end

  defp extract_call_names(source, calls \\ [:field, :add]) do
    ast = Code.string_to_quoted!(source)

    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {call, _meta, [name | _args]} = node, acc when is_atom(name) ->
          if call in calls,
            do: {node, [Atom.to_string(name) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(names)
  end

  defp launch_context_leaks(source, path \\ "<mutation>") do
    ast = Code.string_to_quoted!(source)
    aliases = collect_module_aliases(ast)
    helper_sinks = sink_helper_summaries(ast, aliases)
    aliases = Map.put(aliases, "__sink_helpers__", helper_sinks)

    ast
    |> lexical_scopes()
    |> Enum.flat_map(fn {function, scope} ->
      scan_launch_scope(
        scope,
        function,
        path,
        aliases,
        authority_source_variables(scope)
      )
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.line, &1.kind})
  end

  defp sink_helper_summaries(ast, aliases) do
    sink_helper_fixpoint(ast, aliases, MapSet.new())
  end

  defp sink_helper_fixpoint(ast, aliases, summaries) do
    summary_aliases = Map.put(aliases, "__sink_helpers__", summaries)

    next =
      ast
      |> lexical_scopes()
      |> Enum.reduce(summaries, fn {function, scope}, acc ->
        scope
        |> function_parameter_variables()
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {params, index}, inner_acc ->
          if params != MapSet.new() and
               scan_launch_scope(scope, function, "<summary>", summary_aliases, params) != [] do
            MapSet.put(inner_acc, {function, index})
          else
            inner_acc
          end
        end)
      end)

    if next == summaries, do: next, else: sink_helper_fixpoint(ast, aliases, next)
  end

  defp function_parameter_variables({kind, _meta, [{_name, _head_meta, args} | _]})
       when kind in [:def, :defp],
       do: Enum.map(args || [], &variables_in/1)

  defp function_parameter_variables(_scope), do: []

  defp scan_launch_scope(scope, function, path, aliases, initial_tainted) do
    aliases = Map.put(aliases, "__current_function__", function)
    state = %{tainted: initial_tainted, modules: %{}, leaks: []}
    %{leaks: leaks} = launch_scan(scope, state, function, path, aliases)
    leaks
  end

  defp launch_scan({:__block__, _, nodes}, state, function, path, aliases),
    do: Enum.reduce(nodes, state, &launch_scan(&1, &2, function, path, aliases))

  defp launch_scan({kind, _, [{_name, _, _args}, body]}, state, function, path, aliases)
       when kind in [:def, :defp],
       do: launch_scan(body, state, function, path, aliases)

  defp launch_scan(
         {kind, _, [{:when, _, [_head | _guards]}, body]},
         state,
         function,
         path,
         aliases
       )
       when kind in [:def, :defp],
       do: launch_scan(body, state, function, path, aliases)

  defp launch_scan({:=, _, [left, right]} = node, state, function, path, aliases) do
    state = launch_scan(right, state, function, path, aliases)
    assigned = variables_in(left)
    tainted? = authority_source?(right) or tainted_node?(right, state.tainted)

    tainted =
      if tainted?,
        do: MapSet.union(state.tainted, assigned),
        else: MapSet.difference(state.tainted, assigned)

    modules =
      Enum.reduce(assigned, state.modules, fn variable, acc ->
        Map.put(acc, Atom.to_string(variable), launch_module_value(right, state.modules, aliases))
      end)

    record_launch_state(
      node,
      %{state | tainted: tainted, modules: modules},
      function,
      path,
      aliases
    )
  end

  defp launch_scan({:if, _, [condition, opts]}, state, function, path, aliases) do
    state = launch_scan(condition, state, function, path, aliases)
    branches = [Keyword.get(opts, :do), Keyword.get(opts, :else)] |> Enum.reject(&is_nil/1)
    results = Enum.map(branches, &launch_scan(&1, state, function, path, aliases))
    results = if length(branches) < 2, do: [state | results], else: results
    merge_launch_states(results, state)
  end

  defp launch_scan({:case, _, [subject, opts]}, state, function, path, aliases) do
    state = launch_scan(subject, state, function, path, aliases)
    launch_clause_join(Keyword.get(opts, :do, []), state, function, path, aliases)
  end

  defp launch_scan({:cond, _, [opts]}, state, function, path, aliases),
    do: launch_clause_join(Keyword.get(opts, :do, []), state, function, path, aliases)

  defp launch_scan({:with, _, args}, state, function, path, aliases) do
    opts = List.last(args)
    with_state = launch_scan(Enum.drop(args, -1), state, function, path, aliases)
    success = launch_scan(Keyword.get(opts, :do), with_state, function, path, aliases)
    failure = launch_clause_join(Keyword.get(opts, :else, []), state, function, path, aliases)
    merge_launch_states([success, failure], state)
  end

  defp launch_scan({:for, _, args}, state, function, path, aliases) do
    child = launch_scan(args, state, function, path, aliases)
    %{state | leaks: Enum.uniq(state.leaks ++ child.leaks)}
  end

  defp launch_scan({kind, _, [opts]}, state, function, path, aliases)
       when kind in [:try, :receive] and is_list(opts) do
    ordinary = [:do, :after] |> Enum.map(&Keyword.get(opts, &1)) |> Enum.reject(&is_nil/1)

    clauses =
      [:rescue, :catch, :else, :do, :after]
      |> Enum.flat_map(&List.wrap(Keyword.get(opts, &1, [])))
      |> Enum.filter(&match?({:->, _, _}, &1))

    ordinary_states = Enum.map(ordinary, &launch_scan(&1, state, function, path, aliases))
    clause_state = launch_clause_join(clauses, state, function, path, aliases)
    merged = merge_launch_states([clause_state | ordinary_states], state)
    %{state | leaks: Enum.uniq(state.leaks ++ merged.leaks)}
  end

  defp launch_scan({kind, _, args}, state, function, path, aliases)
       when kind in [:fn, :quote] do
    child = launch_scan_children(args, state, function, path, aliases)
    %{state | leaks: Enum.uniq(state.leaks ++ child.leaks)}
  end

  defp launch_scan(node, state, function, path, aliases) do
    state = record_launch_state(node, state, function, path, aliases)

    children =
      if is_tuple(node), do: Tuple.to_list(node), else: if(is_list(node), do: node, else: [])

    launch_scan_children(children, state, function, path, aliases)
  end

  defp launch_scan_children(nodes, state, function, path, aliases),
    do: Enum.reduce(List.wrap(nodes), state, &launch_scan(&1, &2, function, path, aliases))

  defp launch_clause_join(clauses, state, function, path, aliases) do
    results =
      Enum.map(List.wrap(clauses), fn
        {:->, _, [patterns, body]} ->
          branch = launch_scan(patterns, state, function, path, aliases)
          launch_scan(body, branch, function, path, aliases)

        other ->
          launch_scan(other, state, function, path, aliases)
      end)

    merge_launch_states(results, state)
  end

  defp record_launch_state(node, state, function, path, aliases) do
    call_aliases = Map.merge(aliases, state.modules)

    %{
      state
      | leaks: record_launch_leak(node, function, path, call_aliases, state.tainted, state.leaks)
    }
  end

  defp merge_launch_states([], fallback), do: fallback

  defp merge_launch_states(states, fallback) do
    # A disagreement is the taint lattice's unknown value.  Unknown remains
    # conservatively tainted at a later sink; only unanimous clean branches
    # may clear a binding.
    tainted = states |> Enum.flat_map(&MapSet.to_list(&1.tainted)) |> MapSet.new()

    module_keys = states |> Enum.flat_map(&Map.keys(&1.modules)) |> MapSet.new()

    modules =
      Enum.reduce(module_keys, %{}, fn key, acc ->
        values = Enum.map(states, &Map.get(&1.modules, key))
        Map.put(acc, key, if(Enum.uniq(values) |> length() == 1, do: hd(values), else: :unknown))
      end)

    leaks = states |> Enum.flat_map(& &1.leaks) |> Enum.uniq()
    %{fallback | tainted: tainted, modules: modules, leaks: leaks}
  end

  defp launch_module_value({:if, _, [_condition, opts]}, modules, aliases) do
    values =
      [Keyword.get(opts, :do), Keyword.get(opts, :else)]
      |> Enum.map(&launch_module_value(&1, modules, aliases))

    if Enum.uniq(values) |> length() == 1, do: hd(values), else: :unknown
  end

  defp launch_module_value({name, _, context}, modules, _aliases)
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: Map.get(modules, Atom.to_string(name))

  defp launch_module_value(ast, modules, aliases),
    do: resolve_sink_assignment(ast, aliases, modules)

  defp record_launch_leak(node, function, path, aliases, tainted, leaks) do
    case launch_context_leak_kind(node, tainted, aliases) do
      false ->
        leaks

      kind ->
        line = node |> elem(1) |> Keyword.get(:line, 1)
        leak = %{line: line, function: function, kind: kind, expression: Macro.to_string(node)}
        if launch_context_allowlisted?(path, leak), do: leaks, else: [leak | leaks]
    end
  end

  defp lexical_scopes(ast) do
    {_ast, scopes} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [{name, _head_meta, args} | _]} = node, scopes
        when kind in [:def, :defp] and is_atom(name) ->
          {node, [{{name, length(args || [])}, node} | scopes]}

        node, scopes ->
          {node, scopes}
      end)

    case scopes do
      [] -> [{{:__module__, 0}, ast}]
      _ -> Enum.reverse(scopes)
    end
  end

  defp authority_source_variables(scope) do
    {_scope, variables} =
      Macro.prewalk(scope, MapSet.new(), fn
        {key, value} = node, variables when key in [:launch_context, "launch_context"] ->
          {node, MapSet.union(variables, variables_in(value))}

        node, variables ->
          {node, variables}
      end)

    variables
  end

  defp opaque_context_reads(source) do
    ast = Code.string_to_quoted!(source)

    {_ast, reads} =
      Macro.prewalk(ast, [], fn node, reads ->
        if opaque_context_read?(node) do
          line = node |> elem(1) |> Keyword.get(:line, 1)
          {node, [{line, Macro.to_string(node)} | reads]}
        else
          {node, reads}
        end
      end)

    reads |> Enum.uniq() |> Enum.sort()
  end

  defp opaque_context_read?({{:., _dot_meta, [module, _function]}, _meta, args} = node)
       when is_list(args) do
    accessor? =
      Macro.to_string(module) in ["Map", "Access", "Keyword", "launch_context"]

    accessor? and contains_launch_context_variable?(node)
  end

  defp opaque_context_read?({:=, _meta, [left, right]} = node) do
    structured? = match?({:%{}, _, _}, left) or match?({:%{}, _, _}, right)
    structured? and contains_launch_context_variable?(node)
  end

  defp opaque_context_read?(_node), do: false

  defp contains_launch_context_variable?(node) do
    {_node, found?} =
      Macro.prewalk(node, false, fn
        {:launch_context, _meta, context} = variable, _found?
        when is_atom(context) or is_nil(context) ->
          {variable, true}

        child, found? ->
          {child, found?}
      end)

    found?
  end

  defp launch_context_leak_kind({:%{}, _meta, pairs}, _tainted, _aliases) do
    Enum.any?(pairs, fn
      {:launch_context, _value} -> true
      {"launch_context", _value} -> true
      _pair -> false
    end) && :authored_map
  end

  defp launch_context_leak_kind({:<<>>, _meta, _parts} = node, tainted, _aliases),
    do: tainted_node?(node, tainted) && :rendered_error

  defp launch_context_leak_kind(
         {{:., _dot_meta, [module, function]}, _meta, args} = node,
         tainted,
         aliases
       )
       when is_atom(function) and is_list(args) do
    resolved = resolve_sink_module(module, aliases)
    sink = resolved <> "." <> Atom.to_string(function)

    tainted_node?(node, tainted) &&
      if(resolved == ":unknown", do: :unknown_remote_sink, else: leak_sink_kind(sink, args))
  end

  defp launch_context_leak_kind({function, _meta, args} = node, tainted, _aliases)
       when function in [:inspect, :raise, :reraise, :send] and is_list(args) do
    tainted_node?(node, tainted) &&
      if(function == :send, do: :process_retention, else: :rendered_error)
  end

  defp launch_context_leak_kind({function, _meta, args}, tainted, aliases)
       when is_atom(function) and is_list(args) do
    helpers = Map.get(aliases, "__sink_helpers__", MapSet.new())
    current = Map.get(aliases, "__current_function__")

    if current == {function, length(args)} do
      false
    else
      args
      |> Enum.with_index()
      |> Enum.any?(fn {arg, index} ->
        tainted_node?(arg, tainted) and
          MapSet.member?(helpers, {{function, length(args)}, index})
      end)
      |> then(&(&1 && :local_helper_escape))
    end
  end

  defp launch_context_leak_kind(_node, _tainted, _aliases), do: false

  defp collect_module_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta, [module_ast, opts]} = node, aliases when is_list(opts) ->
          module = module_from_alias(module_ast)
          as = opts |> Keyword.get(:as) |> alias_tail()
          key = as || (module && module |> Module.split() |> List.last())
          {node, if(module && key, do: Map.put(aliases, key, module), else: aliases)}

        {:alias, _meta, [module_ast]} = node, aliases ->
          module = module_from_alias(module_ast)
          key = module && module |> Module.split() |> List.last()
          {node, if(module && key, do: Map.put(aliases, key, module), else: aliases)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp resolve_sink_assignment({:__aliases__, _meta, [first | rest]} = ast, aliases, bindings) do
    Map.get(bindings, Atom.to_string(first)) ||
      Map.get(aliases, Atom.to_string(first)) ||
      module_from_alias(ast) ||
      (rest == [] && first)
  end

  defp resolve_sink_assignment(_rhs, _aliases, _bindings), do: nil

  defp module_from_alias({:__aliases__, _meta, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts)
  end

  defp module_from_alias(_ast), do: nil

  defp alias_tail({:__aliases__, _meta, [tail]}), do: Atom.to_string(tail)
  defp alias_tail(_ast), do: nil

  defp resolve_sink_module({:__aliases__, _meta, [first | rest]}, aliases) do
    case Map.get(aliases, Atom.to_string(first)) do
      nil -> Module.concat([first | rest]) |> inspect()
      base -> Module.concat([base | rest]) |> inspect()
    end
  end

  defp resolve_sink_module({name, _meta, context}, aliases)
       when is_atom(name) and (is_atom(context) or is_nil(context)) do
    aliases |> Map.get(Atom.to_string(name), name) |> inspect()
  end

  defp resolve_sink_module(module, _aliases) when is_atom(module), do: inspect(module)
  defp resolve_sink_module(module, _aliases), do: Macro.to_string(module)

  defp leak_sink_kind(sink, args) do
    cond do
      Regex.match?(~r/^(?:Repo\.|EzagentCore\.Repo\.|Ecto\.|.*Snapshot.*\.)/, sink) ->
        :durable_persistence

      Regex.match?(~r/^(?::persistent_term\.|:ets\.|Process\.put)/, sink) ->
        :restart_retention

      String.starts_with?(sink, "Map.put") and state_like?(List.first(args)) ->
        :process_retention

      Regex.match?(~r/^(?:Logger\.|:telemetry\.)/, sink) ->
        :observability

      Regex.match?(~r/^(?:Jason\.|JSON\.|Yaml\.|YAML\.)/, sink) ->
        :serialization

      Regex.match?(
        ~r/^(?:System\.(?:cmd|put_env|get_env|fetch_env)|Application\.put_env|Port\.open|File\.(?:write|write!)|Config\.)/,
        sink
      ) ->
        :external_sink

      true ->
        false
    end
  end

  defp state_like?({name, _meta, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: name in [:state, :args, :snapshot, :config]

  defp state_like?(_node), do: false

  defp authority_source?({{:., _meta, [module, function]}, _call_meta, args})
       when is_atom(function) and is_list(args) do
    module_name = Macro.to_string(module)

    extraction? =
      module_name in ["Keyword", "Map"] and function in [:get, :get_lazy, :fetch, :fetch!] and
        Enum.any?(args, &(&1 in [:launch_context, "launch_context"]))

    issuance? =
      function in [:issue, :take] and
        (String.ends_with?(module_name, "LaunchAuthority") or
           String.ends_with?(module_name, "LaunchContextRelay"))

    extraction? or issuance?
  end

  defp authority_source?(_node), do: false

  defp variables_in(node) do
    {_node, variables} =
      Macro.prewalk(node, MapSet.new(), fn
        {name, _meta, context} = variable, variables
        when is_atom(name) and (is_atom(context) or is_nil(context)) ->
          {variable, MapSet.put(variables, name)}

        child, variables ->
          {child, variables}
      end)

    variables
  end

  defp tainted_node?(node, tainted) do
    not MapSet.disjoint?(variables_in(node), tainted)
  end

  defp launch_context_allowlisted?(path, leak) do
    {path, leak.function, leak.kind, leak.line} in @launch_context_allowlist
  end

  defp forbidden_plan_c_migrations(names) do
    Enum.filter(names, fn name ->
      case Integer.parse(String.slice(name, 0, 14)) do
        {timestamp, ""} when timestamp >= 20_260_717_001_000 ->
          name not in @plan_c_migrations

        _ ->
          false
      end
    end)
  end

  defp forbidden_field_names(names) do
    names
    |> Enum.reject(&(&1 in @lifecycle_fields))
    |> Enum.filter(&Regex.match?(@forbidden_secret_field, &1))
  end

  defp project_path(path), do: Path.join(project_root(), path)
  defp project_root, do: Path.expand("../../../..", __DIR__)
end
