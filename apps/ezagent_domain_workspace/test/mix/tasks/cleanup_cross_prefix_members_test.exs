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
      violator = Ezagent.URI.new!("entity://system/user/linyilun")
      legit = Ezagent.URI.new!("entity://#{workspace_name}/user/alice")

      {:ok, _} = Store.create(workspace_name, %{members: [violator, legit]})

      output =
        capture_io(fn ->
          assert :ok = CleanupCrossPrefixMembers.run([])
        end)

      assert output =~ "workspace #{workspace_name}"
      assert output =~ "entity://system/user/linyilun"
      assert output =~ "Run with --apply to strip"

      # DB row unchanged.
      %{members: members_after} = Store.get_by_name(workspace_name)
      assert violator in members_after
      assert legit in members_after
    end

    test "explicit --dry-run flag behaves same as default" do
      workspace_name = "task55-explicit-dry-#{System.unique_integer([:positive])}"
      violator = Ezagent.URI.new!("entity://system/user/linyilun")

      {:ok, _} = Store.create(workspace_name, %{members: [violator]})

      output =
        capture_io(fn ->
          assert :ok = CleanupCrossPrefixMembers.run(["--dry-run"])
        end)

      assert output =~ "entity://system/user/linyilun"

      %{members: members_after} = Store.get_by_name(workspace_name)
      assert violator in members_after
    end

    test "clean workspace prints check mark + summary line" do
      workspace_name = "task55-clean-#{System.unique_integer([:positive])}"
      legit = Ezagent.URI.new!("entity://#{workspace_name}/user/alice")

      {:ok, _} = Store.create(workspace_name, %{members: [legit]})

      output =
        capture_io(fn ->
          assert :ok = CleanupCrossPrefixMembers.run([])
        end)

      assert output =~ "workspace #{workspace_name} clean"
    end
  end

  describe "run/1 --apply" do
    # Task #55 round-2 codex HIGH-2 (2026-05-27) — `--apply` now
    # dispatches `Behavior.Workspace.:remove_cross_prefix_members`
    # via `Ezagent.Workspace.remove_cross_prefix_members/1`. The
    # Workspace Kind GenServer must be alive for the dispatch to
    # reach the action body — `Ezagent.Workspace.create/2`
    # both persists the row AND spawns the Kind.

    test "strips cross-prefix violator from DB via dispatch + slice atomic update" do
      workspace_name = "task55-apply-#{System.unique_integer([:positive])}"
      violator = Ezagent.URI.new!("entity://system/user/linyilun")
      legit = Ezagent.URI.new!("entity://#{workspace_name}/user/alice")

      {:ok, _pid} = Ezagent.Workspace.create(workspace_name, %{members: [violator, legit]})

      output =
        capture_io(fn ->
          assert :ok = CleanupCrossPrefixMembers.run(["--apply"])
        end)

      assert output =~ "stripped"

      # DB is the source of recovery — must reflect the strip.
      %{members: members_after} = Store.get_by_name(workspace_name)
      refute violator in members_after
      assert legit in members_after

      # Slice is the live read source — must ALSO reflect the strip
      # (NO restart needed). This is the round-2 invariant: pre-fix the
      # direct-Store path left the slice stale until SIGHUP/restart.
      ws_uri = Ezagent.URI.new!("workspace://#{workspace_name}")

      {:ok, %{members: live_members}} =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{origin: :trusted_internal,
          target: Ezagent.URI.new!("workspace://#{workspace_name}?action=workspace.list_members"),
          mode: :call,
          args: %{},
          # Workspace's OWN self-authority — listing its own members (#154
          # elimination of `system://workspace-loader`).
          ctx: %{
            caller: ws_uri,
            caps: [signed_action_cap!(
              Ezagent.URI.new!("workspace://#{workspace_name}?action=workspace.list_members"),
              ws_uri
            )],
            reply: {:caller_inbox, self()}
          }
        })

      _ = ws_uri
      live_strs = Enum.map(live_members, &URI.to_string/1)
      refute URI.to_string(violator) in live_strs
      assert URI.to_string(legit) in live_strs
    end

    test "strips multiple violators + keeps multiple legits" do
      workspace_name = "task55-mixed-#{System.unique_integer([:positive])}"
      violator_a = Ezagent.URI.new!("entity://system/user/v_a")
      violator_b = Ezagent.URI.new!("entity://other-ws/agent/cc_v_b")
      legit_a = Ezagent.URI.new!("entity://#{workspace_name}/user/legit_a")
      legit_b = Ezagent.URI.new!("entity://#{workspace_name}/agent/cc_legit_b")

      {:ok, _pid} =
        Ezagent.Workspace.create(workspace_name, %{
          members: [violator_a, violator_b, legit_a, legit_b]
        })

      capture_io(fn -> CleanupCrossPrefixMembers.run(["--apply"]) end)

      %{members: members_after} = Store.get_by_name(workspace_name)

      assert Enum.sort(Enum.map(members_after, &URI.to_string/1)) ==
               Enum.sort(Enum.map([legit_a, legit_b], &URI.to_string/1))
    end
  end
end
