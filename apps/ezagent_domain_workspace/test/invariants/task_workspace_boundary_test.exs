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
          leak <- launch_context_leaks(File.read!(project_path(path))),
          do: {path, leak}

    assert offenders == []
  end

  test "launch context leak scanner handles multiline sinks and authored map keys" do
    source = """
    Logger.info(
      "context=\#{inspect(launch_context)}"
    )

    Jason.encode!(%{"launch_context" => launch_context})
    System.cmd("tool", [inspect(launch_context)])
    """

    assert length(launch_context_leaks(source)) >= 3
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

    assert Path.wildcard(
             project_path("apps/ezagent_core/priv/repo_pg/migrations/20260717005000*.exs")
           ) == []
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

  defp launch_context_leaks(source) do
    ast = Code.string_to_quoted!(source)

    {_ast, leaks} =
      Macro.prewalk(ast, [], fn node, leaks ->
        if launch_context_leak?(node) do
          line = node |> elem(1) |> Keyword.get(:line, 1)
          {node, [{line, Macro.to_string(node)} | leaks]}
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

  defp launch_context_leak?({:%{}, _meta, pairs}) do
    Enum.any?(pairs, fn
      {"launch_context", _value} -> true
      _pair -> false
    end)
  end

  defp launch_context_leak?({:<<>>, _meta, _parts} = node),
    do: contains_launch_context_variable?(node)

  defp launch_context_leak?({{:., _dot_meta, [module, function]}, _meta, args} = node)
       when is_atom(function) and is_list(args) do
    sink = Macro.to_string(module) <> "." <> Atom.to_string(function)
    launch_context_node?(node) and leak_sink?(sink)
  end

  defp launch_context_leak?({function, _meta, args} = node)
       when function in [:inspect, :raise, :reraise] and is_list(args),
       do: launch_context_node?(node)

  defp launch_context_leak?(_node), do: false

  defp launch_context_node?(node),
    do: String.contains?(Macro.to_string(node), "launch_context")

  defp leak_sink?(sink) do
    Regex.match?(
      ~r/^(?:Logger\.|:telemetry\.|Jason\.|JSON\.|Yaml\.|YAML\.|System\.(?:cmd|put_env|get_env|fetch_env)|Application\.put_env|Port\.open|File\.(?:write|write!)|Config\.)/,
      sink
    )
  end

  defp forbidden_field_names(names) do
    names
    |> Enum.reject(&(&1 in @lifecycle_fields))
    |> Enum.filter(&Regex.match?(@forbidden_secret_field, &1))
  end

  defp project_path(path), do: Path.join(project_root(), path)
  defp project_root, do: Path.expand("../../../..", __DIR__)
end
