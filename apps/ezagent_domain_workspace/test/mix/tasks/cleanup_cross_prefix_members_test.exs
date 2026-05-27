defmodule Mix.Tasks.Ezagent.Workspace.CleanupCrossPrefixMembersTest do
  @moduledoc """
  Task #55 — cleanup mix task tests.

  Drives `Mix.Tasks.Ezagent.Workspace.CleanupCrossPrefixMembers.run/1`
  with `--dry-run` (default) and `--apply` against seeded
  `Ezagent.Workspace.Store` rows that contain cross-prefix members.
  """

  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureIO

  alias Ezagent.Workspace.Store
  alias Mix.Tasks.Ezagent.Workspace.CleanupCrossPrefixMembers

  setup do
    # Mix.shell uses Mix.Shell.IO by default in test env; restore at
    # the end so other tests aren't affected by the swap below.
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    Mix.shell(Mix.Shell.IO)
    :ok
  end

  describe "run/1 dry-run (default)" do
    test "reports cross-prefix violator without stripping" do
      workspace_name = "task55-dry-#{System.unique_integer([:positive])}"
      violator = URI.parse("entity://user/system/linyilun")
      legit = URI.parse("entity://user/#{workspace_name}/alice")

      {:ok, _} = Store.create(workspace_name, %{members: [violator, legit]})

      output =
        capture_io(fn ->
          assert :ok = CleanupCrossPrefixMembers.run([])
        end)

      assert output =~ "workspace://#{workspace_name}"
      assert output =~ "entity://user/system/linyilun"
      assert output =~ "Run with --apply to strip"

      # DB row unchanged.
      %{members: members_after} = Store.get_by_name(workspace_name)
      assert violator in members_after
      assert legit in members_after
    end

    test "explicit --dry-run flag behaves same as default" do
      workspace_name = "task55-explicit-dry-#{System.unique_integer([:positive])}"
      violator = URI.parse("entity://user/system/linyilun")

      {:ok, _} = Store.create(workspace_name, %{members: [violator]})

      output =
        capture_io(fn ->
          assert :ok = CleanupCrossPrefixMembers.run(["--dry-run"])
        end)

      assert output =~ "entity://user/system/linyilun"

      %{members: members_after} = Store.get_by_name(workspace_name)
      assert violator in members_after
    end

    test "clean workspace prints check mark + summary line" do
      workspace_name = "task55-clean-#{System.unique_integer([:positive])}"
      legit = URI.parse("entity://user/#{workspace_name}/alice")

      {:ok, _} = Store.create(workspace_name, %{members: [legit]})

      output =
        capture_io(fn ->
          assert :ok = CleanupCrossPrefixMembers.run([])
        end)

      assert output =~ "workspace://#{workspace_name} clean"
    end
  end

  describe "run/1 --apply" do
    test "strips cross-prefix violator from DB" do
      workspace_name = "task55-apply-#{System.unique_integer([:positive])}"
      violator = URI.parse("entity://user/system/linyilun")
      legit = URI.parse("entity://user/#{workspace_name}/alice")

      {:ok, _} = Store.create(workspace_name, %{members: [violator, legit]})

      output =
        capture_io(fn ->
          assert :ok = CleanupCrossPrefixMembers.run(["--apply"])
        end)

      assert output =~ "stripped"

      %{members: members_after} = Store.get_by_name(workspace_name)
      refute violator in members_after
      assert legit in members_after
    end

    test "strips multiple violators + keeps multiple legits" do
      workspace_name = "task55-mixed-#{System.unique_integer([:positive])}"
      violator_a = URI.parse("entity://user/system/v_a")
      violator_b = URI.parse("entity://agent/other-ws/cc_v_b")
      legit_a = URI.parse("entity://user/#{workspace_name}/legit_a")
      legit_b = URI.parse("entity://agent/#{workspace_name}/cc_legit_b")

      {:ok, _} =
        Store.create(workspace_name, %{
          members: [violator_a, violator_b, legit_a, legit_b]
        })

      capture_io(fn -> CleanupCrossPrefixMembers.run(["--apply"]) end)

      %{members: members_after} = Store.get_by_name(workspace_name)
      assert Enum.sort(Enum.map(members_after, &URI.to_string/1)) ==
               Enum.sort(Enum.map([legit_a, legit_b], &URI.to_string/1))
    end
  end
end
