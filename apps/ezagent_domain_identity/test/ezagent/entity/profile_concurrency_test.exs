defmodule Ezagent.Entity.ProfileConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ezagent.Entity.Profile
  alias EzagentCore.Repo

  test "different Agent URIs concurrently requesting one base get unique valid names" do
    workspace = unique_workspace("different")
    first = Ezagent.URI.agent(workspace, "one")
    second = Ezagent.URI.agent(workspace, "two")

    on_exit(fn -> delete_workspace_profiles(workspace) end)

    results =
      concurrently([
        fn -> Profile.ensure_agent_display_name(first, "builder") end,
        fn -> Profile.ensure_agent_display_name(second, "builder") end
      ])

    assert [
             {:ok, %Profile{display_name: first_name}},
             {:ok, %Profile{display_name: second_name}}
           ] = results

    assert MapSet.new([first_name, second_name]) == MapSet.new(["builder", "builder-2"])
  end

  test "concurrent calls for the same Agent URI are idempotent" do
    workspace = unique_workspace("same")
    agent_uri = Ezagent.URI.agent(workspace, "one")

    on_exit(fn -> delete_workspace_profiles(workspace) end)

    results =
      concurrently([
        fn -> Profile.ensure_agent_display_name(agent_uri, "builder") end,
        fn -> Profile.ensure_agent_display_name(agent_uri, "builder") end
      ])

    assert [
             {:ok, %Profile{entity_uri: first_uri, display_name: "builder"}},
             {:ok, %Profile{entity_uri: second_uri, display_name: "builder"}}
           ] = results

    assert first_uri == URI.to_string(agent_uri)
    assert second_uri == first_uri
    assert workspace_profile_count(workspace) == 1
  end

  defp concurrently(functions) do
    parent = self()
    ready_ref = make_ref()

    workers =
      Enum.map(functions, fn function ->
        spawn_monitor(fn ->
          owner = Sandbox.start_owner!(Repo, shared: false, sandbox: false)
          send(parent, {ready_ref, self(), :ready})

          receive do
            {^ready_ref, :go} -> :ok
          end

          result = function.()
          Sandbox.stop_owner(owner)
          send(parent, {ready_ref, self(), {:result, result}})
        end)
      end)

    Enum.each(workers, fn {pid, _monitor} ->
      assert_receive {^ready_ref, ^pid, :ready}, 2_000
    end)

    Enum.each(workers, fn {pid, _monitor} -> send(pid, {ready_ref, :go}) end)

    Enum.map(workers, fn {pid, monitor} ->
      assert_receive {^ready_ref, ^pid, {:result, result}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
      result
    end)
  end

  defp delete_workspace_profiles(workspace) do
    Sandbox.unboxed_run(Repo, fn ->
      import Ecto.Query

      workspace_uri = URI.to_string(Ezagent.URI.workspace(workspace))
      Repo.delete_all(from(profile in Profile, where: profile.workspace_uri == ^workspace_uri))
    end)
  end

  defp workspace_profile_count(workspace) do
    Sandbox.unboxed_run(Repo, fn ->
      import Ecto.Query

      workspace_uri = URI.to_string(Ezagent.URI.workspace(workspace))

      Repo.aggregate(
        from(profile in Profile, where: profile.workspace_uri == ^workspace_uri),
        :count
      )
    end)
  end

  defp unique_workspace(prefix) do
    "profile-concurrency-#{prefix}-#{System.unique_integer([:positive])}"
  end
end
