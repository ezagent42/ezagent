defmodule Ezagent.MessageStoreMultiSessionTest do
  @moduledoc """
  Phase 3a-step 3: validate Phase 3 fix for #P1-4 — same Message id
  can land in multiple Session contexts without PK collision.

  PR #149 (SPEC v2 §5.13): by_uri renamed to by_id; URIs no longer used for messages.
  """

  use ExUnit.Case
  alias Ezagent.{Message, MessageStore}
  alias EzagentCore.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Phase 9 PR-6 — MessageStore.write/2 derives workspace via
    # WorkspaceRegistry.lookup(session_uri). Bind every test session
    # to default workspace.
    default_ws = URI.new!("workspace://team-alpha")

    sessions = [
      URI.new!("session://system/default/main"),
      URI.new!("session://team-alpha/default/oncall"),
      URI.new!("session://team-alpha/default/A"),
      URI.new!("session://team-alpha/default/B")
    ]

    for s <- sessions, do: :ok = Ezagent.WorkspaceRegistry.bind(s, default_ws)

    on_exit(fn ->
      for s <- sessions, do: Ezagent.WorkspaceRegistry.unbind(s)
    end)

    :ok
  end

  test "same message id written to 2 sessions → messages 1 row + routings 2 rows" do
    sender = URI.new!("entity://team-alpha/agent/test_cc-builder")
    msg = Message.new(sender, %{text: "reply to both", attachments: []})

    session_a = URI.new!("session://system/default/main")
    session_b = URI.new!("session://team-alpha/default/oncall")

    assert {:ok, _} = MessageStore.write(msg, session_a)
    assert {:ok, _} = MessageStore.write(msg, session_b)

    # by_id returns ONE row (Phase 2 identity invariant unchanged)
    assert {:ok, loaded} = MessageStore.by_id(msg.id)
    assert loaded.id == msg.id

    # but sessions_for_message returns both
    sessions = MessageStore.sessions_for_message(msg.id)

    assert MapSet.new(sessions) ==
             MapSet.new(["session://system/default/main", "session://team-alpha/default/oncall"])
  end

  test "recent_in_session scoped via JOIN — message in both sessions appears in both queries" do
    sender = URI.new!("entity://team-alpha/agent/test_cc-builder")
    session_a = URI.new!("session://team-alpha/default/A")
    session_b = URI.new!("session://team-alpha/default/B")

    # 3 messages, only msg2 spans both sessions
    {:ok, _} =
      MessageStore.write(Message.new(sender, %{text: "msg-A1", attachments: []}), session_a)

    msg2 = Message.new(sender, %{text: "msg-shared", attachments: []})
    {:ok, _} = MessageStore.write(msg2, session_a)
    {:ok, _} = MessageStore.write(msg2, session_b)

    {:ok, _} =
      MessageStore.write(Message.new(sender, %{text: "msg-B1", attachments: []}), session_b)

    recent_a = MessageStore.recent_in_session(session_a, 100)
    recent_b = MessageStore.recent_in_session(session_b, 100)

    a_texts = recent_a |> Enum.map(&(&1.body["text"] || &1.body[:text])) |> MapSet.new()
    b_texts = recent_b |> Enum.map(&(&1.body["text"] || &1.body[:text])) |> MapSet.new()

    # session_a sees msg-A1 + msg-shared (2)
    # session_b sees msg-shared + msg-B1 (2)
    assert MapSet.size(a_texts) == 2
    assert MapSet.size(b_texts) == 2
    assert "msg-shared" in a_texts
    assert "msg-shared" in b_texts
  end

  test "write is idempotent on (message_id, session_uri) — duplicate write doesn't fail or double-insert routing" do
    sender = URI.new!("entity://system/user/admin")
    msg = Message.new(sender, %{text: "once", attachments: []})
    session = URI.new!("session://system/default/main")

    {:ok, _} = MessageStore.write(msg, session)
    {:ok, _} = MessageStore.write(msg, session)

    assert MessageStore.sessions_for_message(msg.id) == ["session://system/default/main"]
  end
end
