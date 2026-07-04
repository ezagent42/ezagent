defmodule Ezagent.Identity.GrantMigrationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Identity.GrantMigration
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Test.SnapshotFixtures
  alias EzagentCore.Repo

  @old_behavior_string "Elixir.Ezagent.ActionSet.Chat"
  @new_behavior_string "Elixir.Ezagent.ActionSet.Session"
  @old_behavior_atom :"Elixir.Ezagent.ActionSet.Chat"
  @workspace "workspace://team-alpha"

  # A pre-migration caps_json holding a Behavior.Chat grant (the shape
  # `Ezagent.Capability.Normalize.to_map/1` + Jason.encode! produced under the
  # old code).
  defp legacy_caps_json do
    Jason.encode!([
      %{
        "kind" => "session",
        "behavior" => @old_behavior_string,
        "action" => "send",
        "instance" => "any",
        "workspace_uri" => @workspace,
        "granted_by" => "entity://system/user/admin",
        "granted_at" => "2026-01-01T00:00:00.000000Z"
      }
    ])
  end

  # Seed a users row directly with the given caps_json (bypassing Users.create,
  # which would prepend fresh Behavior.Session default caps).
  defp seed_user(uri, caps_json) do
    {:ok, row} =
      %Ezagent.Users{}
      |> Ecto.Changeset.change(
        uri: uri,
        password_hash: "x",
        caps_json: caps_json,
        workspace_uri: @workspace
      )
      |> Repo.insert()

    row
  end

  defp user_caps_json(uri) do
    Repo.get_by!(Ezagent.Users, uri: uri).caps_json
  end

  describe "rewrite_caps_json/1 (pure)" do
    test "rewrites the Behavior.Chat behavior string to Behavior.Session" do
      assert {:changed, new} = GrantMigration.rewrite_caps_json(legacy_caps_json())
      assert String.contains?(new, @new_behavior_string)
      refute String.contains?(new, @old_behavior_string)
    end

    test "leaves a json without the old behavior unchanged" do
      json = Jason.encode!([%{"behavior" => @new_behavior_string}])
      assert {:unchanged, ^json} = GrantMigration.rewrite_caps_json(json)
    end
  end

  describe "rewrite_cap/1 (pure)" do
    test "rewrites a cap whose behavior is the old Chat atom" do
      cap = %Ezagent.Capability{
        behavior: @old_behavior_atom,
        kind: :session,
        action: :send,
        instance: :any,
        workspace_uri: :any,
        granted_by: :system,
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      assert %{behavior: Ezagent.ActionSet.Session} = GrantMigration.rewrite_cap(cap)
    end

    test "leaves a non-Chat cap unchanged" do
      cap = %Ezagent.Capability{behavior: Ezagent.ActionSet.Session, kind: :session, action: :send, instance: :any, workspace_uri: :any, granted_by: :system, granted_at: ~U[2026-01-01 00:00:00Z]}
      assert GrantMigration.rewrite_cap(cap) == cap
    end
  end

  describe "run/1 against a seeded Behavior.Chat caps_json row" do
    test "rewrites users.caps_json Behavior.Chat → Behavior.Session" do
      uri = "entity://team-alpha/user/legacy-grant-holder"
      seed_user(uri, legacy_caps_json())

      assert String.contains?(user_caps_json(uri), @old_behavior_string)

      assert {:ok, counts} = GrantMigration.run()
      assert counts.users_rewritten >= 1

      after_json = user_caps_json(uri)
      assert String.contains?(after_json, @new_behavior_string)
      refute String.contains?(after_json, @old_behavior_string)
    end

    test "rewrites a Behavior.Chat cap in an :identity snapshot slice" do
      uri = "entity://team-alpha/user/snapshot-grant-holder"

      old_cap = %Ezagent.Capability{
        behavior: @old_behavior_atom,
        kind: :session,
        action: :send,
        instance: :any,
        workspace_uri: :any,
        granted_by: :system,
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      state = %{
        identity: %{state: %{caps: MapSet.new([old_cap])}, transients: %{}}
      }

      {:ok, _} =
        SnapshotFixtures.upsert_kind_snapshot(
          uri,
          "user",
          :erlang.term_to_binary(state),
          0,
          @workspace
        )

      assert {:ok, counts} = GrantMigration.run()
      assert counts.snapshots_rewritten >= 1

      {:ok, post} = KindSnapshot.decode_state(KindSnapshot.get(uri))
      caps = post[:identity][:state][:caps] |> MapSet.to_list()
      assert Enum.all?(caps, &(&1.behavior == Ezagent.ActionSet.Session))
      refute Enum.any?(caps, &(&1.behavior == @old_behavior_atom))
    end

    test "--dry-run reports without writing" do
      uri = "entity://team-alpha/user/dry-run-grant"
      seed_user(uri, legacy_caps_json())

      assert {:ok, counts} = GrantMigration.run(dry_run: true)
      assert counts.dry_run >= 1
      # unchanged on disk
      assert String.contains?(user_caps_json(uri), @old_behavior_string)
    end
  end

  describe "gate/0" do
    test "reports the count of persisted Behavior.Chat grants; 0 after migration" do
      uri = "entity://team-alpha/user/gate-grant"
      seed_user(uri, legacy_caps_json())

      assert {:ok, n} = GrantMigration.gate()
      assert n >= 1

      {:ok, _} = GrantMigration.run()
      assert {:ok, 0} = GrantMigration.gate()
    end
  end
end
