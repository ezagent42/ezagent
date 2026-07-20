defmodule Ezagent.Socialware.MountRowTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.MountRow

  test "upsert persists a mount row that list_for_session reads back with matching fields" do
    session = session_uri("read-back")
    target = agent_uri("board")
    grantee = agent_uri("assistant")

    assert {:ok, row} = MountRow.upsert(mount_attrs(session, target, grantee))

    assert [read] = MountRow.list_for_session(session)
    assert read.id == row.id
    assert read.session_uri == URI.to_string(session)
    assert read.target_uri == URI.to_string(target)
    assert read.grantee_uri == URI.to_string(grantee)
    assert read.behavior == "Ezagent.ActionSet.Mindmap"
    assert Jason.decode!(read.actions_json) == ["get_tree", "export_markmap"]
    assert read.access == "operate"
    assert read.granted_by == "entity://composition/user/data-owner"
    assert read.workspace_uri == URI.to_string(Ezagent.URI.workspace_of(target))
    assert read.mounted_at
  end

  test "re-upserting the same natural key overwrites in place (no duplicate row)" do
    session = session_uri("overwrite")
    target = agent_uri("board")
    grantee = agent_uri("assistant")

    assert {:ok, _} = MountRow.upsert(mount_attrs(session, target, grantee))

    assert {:ok, _} =
             MountRow.upsert(
               mount_attrs(session, target, grantee, actions: ["get_tree"], access: "read")
             )

    assert [read] = MountRow.list_for_session(session)
    assert Jason.decode!(read.actions_json) == ["get_tree"]
    assert read.access == "read"
  end

  test "delete_by_natural_key removes the row" do
    session = session_uri("delete")
    target = agent_uri("board")
    grantee = agent_uri("assistant")

    assert {:ok, _} = MountRow.upsert(mount_attrs(session, target, grantee))
    assert [_] = MountRow.list_for_session(session)

    assert {:ok, :deleted} =
             MountRow.delete_by_natural_key(session, target, grantee, "Ezagent.ActionSet.Mindmap")

    assert MountRow.list_for_session(session) == []
  end

  test "mount_id is stable for the same params and session-scoped across sessions" do
    session_a = session_uri("scope-a")
    session_b = session_uri("scope-b")
    target = agent_uri("board")
    grantee = agent_uri("assistant")
    behavior = "Ezagent.ActionSet.Mindmap"

    id_a1 = MountRow.mount_id(session_a, target, grantee, behavior)
    id_a2 = MountRow.mount_id(session_a, target, grantee, behavior)
    id_b = MountRow.mount_id(session_b, target, grantee, behavior)

    assert id_a1 == id_a2
    assert id_a1 != id_b
  end

  describe "person-scope 行(㊵ 人本位)" do
    test "person upsert 落行:scope=person、session 为空,list_person_mounts_for_grantee 读回" do
      target = agent_uri("p-board")
      grantee = person_uri("alice")

      assert {:ok, row} = MountRow.upsert(person_attrs(target, grantee))
      assert row.scope == "person"
      assert row.session_uri == nil

      assert [read] = MountRow.list_person_mounts_for_grantee(grantee)
      assert read.id == row.id
      assert read.target_uri == URI.to_string(target)
      assert read.grantee_uri == URI.to_string(grantee)
      assert MountRow.get_person(target, grantee, "Ezagent.ActionSet.Mindmap") != nil
    end

    test "person 行不出现在 list_for_session(无 session 轴,任何 session 都不命中)" do
      target = agent_uri("p-board")
      grantee = person_uri("bob")

      assert {:ok, _} = MountRow.upsert(person_attrs(target, grantee))
      assert MountRow.list_for_session(session_uri("unrelated")) == []
    end

    test "同 person 自然键再 upsert → 原地覆盖仍 1 行" do
      target = agent_uri("p-board")
      grantee = person_uri("carol")

      assert {:ok, _} = MountRow.upsert(person_attrs(target, grantee))

      assert {:ok, _} =
               MountRow.upsert(
                 person_attrs(target, grantee, actions: ["get_tree"], access: "read")
               )

      assert [read] = MountRow.list_person_mounts_for_grantee(grantee)
      assert Jason.decode!(read.actions_json) == ["get_tree"]
      assert read.access == "read"
    end

    test "delete_person_by_natural_key 删行,再删 :not_found" do
      target = agent_uri("p-board")
      grantee = person_uri("dave")
      behavior = "Ezagent.ActionSet.Mindmap"

      assert {:ok, _} = MountRow.upsert(person_attrs(target, grantee))
      assert {:ok, :deleted} = MountRow.delete_person_by_natural_key(target, grantee, behavior)
      assert {:ok, :not_found} = MountRow.delete_person_by_natural_key(target, grantee, behavior)
      assert MountRow.list_person_mounts_for_grantee(grantee) == []
    end

    test "person_mount_id 稳定,且与 session mount_id 不同域" do
      target = agent_uri("p-board")
      grantee = person_uri("erin")
      behavior = "Ezagent.ActionSet.Mindmap"

      id1 = MountRow.person_mount_id(target, grantee, behavior)
      id2 = MountRow.person_mount_id(target, grantee, behavior)

      assert id1 == id2
      assert id1 != MountRow.mount_id(session_uri("scope-s"), target, grantee, behavior)
    end

    test "session 行(scope 默认)不带 session_uri → 显式 raise 非静默 NULL 行" do
      assert_raise KeyError, fn ->
        MountRow.upsert(%{
          target_uri: agent_uri("nk-board"),
          grantee_uri: person_uri("frank"),
          behavior: "Ezagent.ActionSet.Mindmap",
          mounted_at: DateTime.utc_now()
        })
      end
    end
  end

  defp person_attrs(target, grantee, opts \\ []) do
    %{
      scope: :person,
      target_uri: target,
      grantee_uri: grantee,
      behavior: "Ezagent.ActionSet.Mindmap",
      actions: Keyword.get(opts, :actions, ["get_tree", "export_markmap"]),
      access: Keyword.get(opts, :access, "read"),
      granted_by: "entity://composition/user/data-owner",
      workspace_uri: Ezagent.URI.workspace_of(target),
      mounted_at: DateTime.utc_now()
    }
  end

  defp person_uri(name),
    do:
      Ezagent.URI.new!("entity://composition/user/#{name}-#{System.unique_integer([:positive])}")

  defp mount_attrs(session, target, grantee, opts \\ []) do
    %{
      session_uri: session,
      target_uri: target,
      grantee_uri: grantee,
      behavior: "Ezagent.ActionSet.Mindmap",
      actions: Keyword.get(opts, :actions, ["get_tree", "export_markmap"]),
      access: Keyword.get(opts, :access, "operate"),
      granted_by: "entity://composition/user/data-owner",
      workspace_uri: Ezagent.URI.workspace_of(target),
      mounted_at: DateTime.utc_now()
    }
  end

  defp agent_uri(name),
    do:
      Ezagent.URI.new!("entity://composition/agent/#{name}-#{System.unique_integer([:positive])}")

  defp session_uri(name),
    do:
      Ezagent.URI.new!(
        "session://composition/socialware/#{name}-#{System.unique_integer([:positive])}"
      )
end
