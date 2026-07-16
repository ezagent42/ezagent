defmodule Ezagent.DomainGit.Architecture.AdapterRegistryBoundaryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Task 4 local inventory gate. Runtime authorization ordering lands in Task 8;
  repository-wide adapter-call enforcement lands in Task 10.
  """

  test "only the GitTaskAccess ActionSet may call adapter-selecting lookup" do
    app_root = Path.expand("../..", __DIR__)
    registry = Path.join(app_root, "lib/ezagent/domain_git/adapter_registry.ex")
    future_action_set = Path.join(app_root, "lib/ezagent/action_set/git_task_access.ex")

    callers =
      app_root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(&1 == registry))
      |> Enum.filter(fn path ->
        File.read!(path) =~ ~r/\b(?:AdapterRegistry\.)?lookup_for_action_set\s*\(/
      end)

    assert callers -- [future_action_set] == [],
           "adapter-selecting lookup callers outside GitTaskAccess: #{inspect(callers)}"
  end
end
