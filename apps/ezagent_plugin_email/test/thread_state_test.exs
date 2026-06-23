defmodule Ezagent.Email.ThreadStateTest do
  @moduledoc """
  #88 PR-1 (SPEC §4.3 / HIGH 5) — durable RFC 5322 threading state.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Email.ThreadState
  alias Ezagent.ExternalMirror.BindingRow

  @ws "workspace://system"

  # Insert a parent binding row so the FK holds (binding_row_id REFERENCES
  # external_mirror_bindings(id)). Returns the row id (= the thread key).
  defp parent_binding!(target \\ "human@example.com") do
    session_uri =
      Ezagent.URI.new!("session://system/default/ts-#{System.unique_integer([:positive])}")

    id = BindingRow.row_id(session_uri, "email", target)

    {:ok, _} =
      BindingRow.insert(%{
        id: id,
        session_uri: URI.to_string(session_uri),
        adapter_id: "email",
        target_id: target,
        opts_json: "{}",
        bound_by: "entity://system/user/admin",
        bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        workspace_uri: @ws
      })

    {id, session_uri}
  end

  test "load/1 returns nil for an unknown binding" do
    assert ThreadState.load("does-not-exist") == nil
  end

  test "upsert then load round-trips the threading fields" do
    {id, _} = parent_binding!()

    assert {:ok, _} =
             ThreadState.upsert(id, %{
               root_message_id: "<r@ezagent.chat>",
               last_message_id: "<r@ezagent.chat>",
               references_chain: "<r@ezagent.chat>",
               workspace_uri: @ws
             })

    row = ThreadState.load(id)
    assert row.root_message_id == "<r@ezagent.chat>"
    assert row.last_message_id == "<r@ezagent.chat>"
    assert row.references_chain == "<r@ezagent.chat>"
    assert row.workspace_uri == @ws
  end

  test "a second upsert advances last_message_id + grows the References chain, root unchanged" do
    {id, _} = parent_binding!()

    {:ok, _} =
      ThreadState.upsert(id, %{
        root_message_id: "<m1@ezagent.chat>",
        last_message_id: "<m1@ezagent.chat>",
        references_chain: "<m1@ezagent.chat>",
        workspace_uri: @ws
      })

    {:ok, _} =
      ThreadState.upsert(id, %{
        root_message_id: "<m1@ezagent.chat>",
        last_message_id: "<m2@ezagent.chat>",
        references_chain: "<m1@ezagent.chat> <m2@ezagent.chat>",
        workspace_uri: @ws
      })

    row = ThreadState.load(id)
    assert row.root_message_id == "<m1@ezagent.chat>"
    assert row.last_message_id == "<m2@ezagent.chat>"
    assert row.references_chain == "<m1@ezagent.chat> <m2@ezagent.chat>"
  end

  test "deleting the parent binding CASCADE-deletes the thread row (no orphan)" do
    {id, session_uri} = parent_binding!("cascade@example.com")

    {:ok, _} =
      ThreadState.upsert(id, %{
        root_message_id: "<x@ezagent.chat>",
        last_message_id: "<x@ezagent.chat>",
        references_chain: "<x@ezagent.chat>",
        workspace_uri: @ws
      })

    assert ThreadState.load(id) != nil

    {:ok, :deleted} =
      BindingRow.delete_by_natural_key(session_uri, "email", "cascade@example.com")

    assert ThreadState.load(id) == nil
  end
end
