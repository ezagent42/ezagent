defmodule Ezagent.Workspace.TaskWorkspace.PathsTest do
  use ExUnit.Case, async: false

  alias Ezagent.Workspace.TaskWorkspace.Paths

  setup do
    previous_home = System.get_env("EZAGENT_HOME")

    root =
      Path.join(System.tmp_dir!(), "task-workspace-paths-#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", root)

    on_exit(fn ->
      restore_env("EZAGENT_HOME", previous_home)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "derives deterministic tenant-authorized cache and per-generation worktree paths" do
    assert {:ok, first} = Paths.derive(input())
    assert {:ok, same} = Paths.derive(input())
    assert first == same

    assert {:ok, next} = Paths.derive(%{input() | provision_id: "provision-two", generation: 2})
    assert first.cache_path == next.cache_path
    refute first.worktree_path == next.worktree_path

    root = Path.expand(Ezagent.Home.path("git-task-workspaces"))
    assert beneath?(first.cache_path, root)
    assert beneath?(first.worktree_path, root)
  end

  test "rejects traversal and foreign-workspace coordinates before resolution" do
    assert {:error, {:unsafe_segment, "../escape"}} =
             Paths.derive(%{input() | provision_id: "../escape"})

    foreign = Ezagent.URI.resource("other", "git-repository", "widgets")

    assert {:error, :repository_workspace_mismatch} =
             Paths.derive(%{input() | repository_uri: foreign})

    wrong_type = Ezagent.URI.resource("paths-team", "not-a-repository", "widgets")

    assert {:error, :invalid_repository_uri} =
             Paths.derive(%{input() | repository_uri: wrong_type})
  end

  defp input do
    %{
      workspace_uri: Ezagent.URI.workspace("paths-team"),
      repository_uri: Ezagent.URI.resource("paths-team", "git-repository", "widgets"),
      base_ref: "main",
      provision_id: "provision-one",
      generation: 1,
      allowed_head_ref: "task/task-one"
    }
  end

  defp beneath?(path, root), do: String.starts_with?(Path.expand(path), root <> "/")

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
