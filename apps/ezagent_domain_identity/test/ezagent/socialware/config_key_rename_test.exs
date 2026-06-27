defmodule Ezagent.Socialware.ConfigKeyRenameTest do
  @moduledoc """
  Data-rename `advisor.behavior` → `agent.soul` (SPEC
  `docs/together/2026-06-26/specs/soul-config-key-rename.md`).

  `EzagentCore.DataCase` gives the SQL sandbox so the seeded + renamed rows are
  isolated + rolled back per test. The Ecto migration
  `RenameAdvisorBehaviorToAgentSoul` is a thin caller of
  `Ezagent.Socialware.ConfigKeyRename`, so testing the module here proves the
  migration's real behavior (forward, collision preflight, byte-identical
  down round-trip) without fighting the migrator/sandbox.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{ConfigKeyRename, ConfigObject, ConfigPointer}
  alias EzagentCore.Repo

  @old "advisor.behavior"
  @new "agent.soul"
  @ws "workspace://team-alpha"

  defp uniq, do: System.unique_integer([:positive])

  defp seed_object(key, opts \\ []) do
    subject = Keyword.get(opts, :subject, "entity://team-alpha/agent/obj-#{uniq()}")
    turn = Keyword.get(opts, :source_turn_id, "turn-#{uniq()}")

    {:ok, row} =
      %{
        id: Ecto.UUID.generate(),
        workspace_uri: @ws,
        subject_uri: subject,
        key: key,
        body: %{"soul_md" => "you are helpful"},
        created_by: "entity://team-alpha/user/admin",
        source_turn_id: turn
      }
      |> ConfigObject.changeset()
      |> Repo.insert()

    row
  end

  defp seed_pointer(key, opts \\ []) do
    layer = Keyword.get(opts, :layer, "user")
    subject = Keyword.get(opts, :subject, "entity://team-alpha/agent/ptr-#{uniq()}")
    id = ConfigPointer.id(layer, @ws, subject, key)

    {:ok, row} =
      %{
        id: id,
        layer: layer,
        workspace_uri: @ws,
        subject_uri: subject,
        key: key,
        config_id: Ecto.UUID.generate(),
        previous_config_id: nil,
        pointed_by: "entity://team-alpha/user/admin",
        source_turn_id: "turn-#{uniq()}"
      }
      |> ConfigPointer.changeset()
      |> Repo.insert()

    row
  end

  defp reload_object(id), do: Repo.get(ConfigObject, id)
  defp reload_pointer(id), do: Repo.get(ConfigPointer, id)

  describe "run/0 — forward rename" do
    test "renames the objects.key column from advisor.behavior to agent.soul" do
      obj = seed_object(@old)
      assert reload_object(obj.id).key == @old

      assert :ok = ConfigKeyRename.run()

      assert reload_object(obj.id).key == @new
    end

    test "renames pointers.key AND rebuilds the id PK to match ConfigPointer.id/4" do
      subject = "entity://team-alpha/agent/ptr-fixed-#{uniq()}"
      ptr = seed_pointer(@old, layer: "user", subject: subject)

      assert :ok = ConfigKeyRename.run()

      # old id PK no longer exists
      assert reload_pointer(ptr.id) == nil

      new_id = ConfigPointer.id("user", @ws, subject, @new)
      renamed = reload_pointer(new_id)
      assert renamed != nil
      assert renamed.key == @new
      # id is the canonical join with the new key (not substring arithmetic)
      assert renamed.id == new_id
      # non-key fields untouched
      assert renamed.config_id == ptr.config_id
      assert renamed.subject_uri == subject
    end

    test "leaves unrelated keys (e.g. model.settings) untouched" do
      other = seed_object("model.settings")
      assert :ok = ConfigKeyRename.run()
      assert reload_object(other.id).key == "model.settings"
    end

    test "is idempotent — a re-run over already-renamed rows is a no-op" do
      obj = seed_object(@old)
      ptr = seed_pointer(@old)

      assert :ok = ConfigKeyRename.run()
      first_ptr_id = ConfigPointer.id(ptr.layer, @ws, ptr.subject_uri, @new)

      assert :ok = ConfigKeyRename.run()

      assert reload_object(obj.id).key == @new
      assert reload_pointer(first_ptr_id).key == @new
    end
  end

  describe "run/0 — collision preflight (codex r1)" do
    test "raises if a pre-existing agent.soul POINTER collides at the same tuple" do
      subject = "entity://team-alpha/agent/collide-#{uniq()}"
      # both an old-key row AND a pre-existing new-key row at the same tuple
      seed_pointer(@old, layer: "user", subject: subject)
      seed_pointer(@new, layer: "user", subject: subject)

      assert_raise RuntimeError, ~r/rename collision.*pointer/, fn ->
        ConfigKeyRename.run()
      end
    end

    test "raises if a pre-existing agent.soul OBJECT collides at the same turn tuple" do
      subject = "entity://team-alpha/agent/collide-obj-#{uniq()}"
      turn = "turn-collide-#{uniq()}"
      seed_object(@old, subject: subject, source_turn_id: turn)
      seed_object(@new, subject: subject, source_turn_id: turn)

      assert_raise RuntimeError, ~r/rename collision.*object/, fn ->
        ConfigKeyRename.run()
      end
    end
  end

  describe "rollback/0 — byte-identical round-trip" do
    test "run then rollback restores the original key and the exact original id" do
      obj = seed_object(@old)
      ptr = seed_pointer(@old)
      original_obj_id = obj.id
      original_ptr_id = ptr.id

      assert :ok = ConfigKeyRename.run()
      assert :ok = ConfigKeyRename.rollback()

      restored_obj = reload_object(original_obj_id)
      assert restored_obj.key == @old

      restored_ptr = reload_pointer(original_ptr_id)
      assert restored_ptr != nil, "pointer id must round-trip byte-identical"
      assert restored_ptr.id == original_ptr_id
      assert restored_ptr.key == @old
    end
  end
end
