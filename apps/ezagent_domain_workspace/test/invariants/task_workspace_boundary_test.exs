defmodule Ezagent.Workspace.TaskWorkspace.BoundaryTest do
  use ExUnit.Case, async: true

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
    refute_schema_fields(
      ~w(token credential secret private_key authorization_header environment)a
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
    root
    |> project_path()
    |> Path.join("**/*.{ex,exs}")
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

  defp refute_schema_fields(fields) do
    schema =
      project_path(
        "apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/provision.ex"
      )
      |> File.read!()

    names =
      ~r/field\(\s*:(?<name>[a-zA-Z0-9_]+)/
      |> Regex.scan(schema, capture: ["name"])
      |> List.flatten()
      |> Enum.map(&String.to_atom/1)

    assert MapSet.disjoint?(MapSet.new(names), MapSet.new(fields))
  end

  defp project_path(path), do: Path.join(project_root(), path)
  defp project_root, do: Path.expand("../../../..", __DIR__)
end
