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
