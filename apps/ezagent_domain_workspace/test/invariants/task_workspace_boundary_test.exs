defmodule Ezagent.Workspace.TaskWorkspace.BoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_secret_field ~r/(^|_)(access_token|auth_blob|key_material|credential_ref|authorization_header|private_key|secret|credential|environment)($|_)/
  @lifecycle_fields ~w(claim_token start_token start_claim_token start_token_consumed_at cleanup_reason cleaned_at)

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

  test "task workspace start bridge has exact production call sites" do
    assert_only_production_calls("pre_start_ref:", [
      "apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/agent_start.ex"
    ])

    assert_only_production_calls("AgentStart.start(", [])
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
      |> extract_names(~r/field\(\s*:(?<name>[a-zA-Z0-9_]+)/)

    migration_names =
      "apps/ezagent_core/priv/repo_pg/migrations/*.exs"
      |> project_path()
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        if String.contains?(source, "git_task_workspace_provisions") do
          extract_names(source, ~r/add\s+:(?<name>[a-zA-Z0-9_]+)/)
        else
          []
        end
      end)

    names = Enum.uniq(schema_names ++ migration_names)
    lifecycle_names = Enum.filter(names, &(&1 in @lifecycle_fields))
    forbidden = Enum.filter(names -- lifecycle_names, &Regex.match?(@forbidden_secret_field, &1))

    assert Enum.sort(lifecycle_names) == Enum.sort(Enum.filter(@lifecycle_fields, &(&1 in names)))
    assert forbidden == []
  end

  defp extract_names(source, regex) do
    regex
    |> Regex.scan(source, capture: ["name"])
    |> List.flatten()
  end

  defp project_path(path), do: Path.join(project_root(), path)
  defp project_root, do: Path.expand("../../../..", __DIR__)
end
