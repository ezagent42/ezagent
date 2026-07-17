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
    {"apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex", {:before_start, 1}, :authored_map},
    {"apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/pre_start.ex",
     {:prepare, 1}, :authored_map}
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
      "opaque = launch_context\nRepo.insert!(%Row{value: opaque})",
      "alias EzagentCore.Repo, as: Storage\nopaque = launch_context\nStorage.insert!(%Row{value: opaque})",
      "opaque = launch_context\nEcto.Multi.put(multi, :context, opaque)",
      "opaque = launch_context\nEzagent.SnapshotStore.write(uri, :slice, opaque)",
      "opaque = launch_context\n:persistent_term.put(:context, opaque)",
      "opaque = launch_context\n:ets.insert(:contexts, {:context, opaque})",
      "opaque = launch_context\nProcess.put(:context, opaque)",
      "opaque = launch_context\nMap.put(state, :context, opaque)",
      "opaque = launch_context\nsend(pid, {:context, opaque})",
      "opaque = launch_context\nSystem.cmd(\"tool\", [inspect(opaque)])",
      "opaque = launch_context\nSystem.put_env(\"CONTEXT\", inspect(opaque))",
      "opaque = launch_context\nApplication.put_env(:app, :context, opaque)",
      "opaque = launch_context\nLogger.info(\"context=\#{inspect(opaque)}\")",
      "opaque = launch_context\n:telemetry.execute([:launch], %{}, %{context: opaque})",
      "opaque = launch_context\nJason.encode!(%{context: opaque})",
      "opaque = launch_context\nraise \"bad context \#{inspect(opaque)}\""
    ]

    for source <- mutants do
      assert launch_context_leaks(source) != [], source
    end
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
    tainted = tainted_variables(ast, MapSet.new([:launch_context]))
    functions = collect_functions(ast)
    aliases = collect_module_aliases(ast)

    {_ast, leaks} =
      Macro.prewalk(ast, [], fn node, leaks ->
        kind = launch_context_leak_kind(node, tainted, aliases)

        if kind do
          line = node |> elem(1) |> Keyword.get(:line, 1)
          function = enclosing_function(functions, line)
          leak = %{line: line, function: function, kind: kind, expression: Macro.to_string(node)}

          if launch_context_allowlisted?(path, leak) do
            {node, leaks}
          else
            {node, [leak | leaks]}
          end
        else
          {node, leaks}
        end
      end)

    leaks |> Enum.uniq() |> Enum.sort()
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
    sink = resolve_sink_module(module, aliases) <> "." <> Atom.to_string(function)
    tainted_node?(node, tainted) && leak_sink_kind(sink, args)
  end

  defp launch_context_leak_kind({function, _meta, args} = node, tainted, _aliases)
       when function in [:inspect, :raise, :reraise, :send] and is_list(args) do
    tainted_node?(node, tainted) &&
      if(function == :send, do: :process_retention, else: :rendered_error)
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

  defp tainted_variables(ast, tainted) do
    {_ast, expanded} =
      Macro.prewalk(ast, tainted, fn
        {:=, _meta, [left, right]} = node, current ->
          if tainted_node?(right, current) do
            {node, MapSet.union(current, variables_in(left))}
          else
            {node, current}
          end

        node, current ->
          {node, current}
      end)

    if expanded == tainted, do: expanded, else: tainted_variables(ast, expanded)
  end

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

  defp enclosing_function(functions, line) do
    functions
    |> Enum.take_while(fn {function_line, _function} -> function_line <= line end)
    |> List.last()
    |> case do
      {_line, function} -> function
      nil -> {:__module__, 0}
    end
  end

  defp launch_context_allowlisted?(path, leak) do
    {path, leak.function, leak.kind} in @launch_context_allowlist
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
