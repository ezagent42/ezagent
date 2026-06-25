defmodule Ezagent.MessageStoreMultiSessionTest do
  @moduledoc """
  Message session-scoping (2026-06-21): a Message belongs to exactly ONE session
  (the vestigial `message_routings` multi-routing was removed; cross-session
  forwarding copies a NEW message into the target session). These pin the
  session-scoped invariants — idempotent single-row write + cross-session
  isolation. (Was the Phase-3 multi-routing test before the collapse.)
  """

  use EzagentCore.DataCase, async: false
  alias Ezagent.{Message, MessageStore}
  # `Repo` is aliased by `use EzagentCore.DataCase`; no explicit alias needed (#92).

  setup do
    # Sandbox provided by EzagentCore.DataCase (#92).
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

  test "a message belongs to ONE session; writing the same id to another session is a no-op" do
    sender = URI.new!("entity://team-alpha/agent/test_cc-builder")
    msg = Message.new(sender, %{text: "first session wins", attachments: []})

    session_a = URI.new!("session://system/default/main")
    session_b = URI.new!("session://team-alpha/default/oncall")

    assert {:ok, _} = MessageStore.write(msg, session_a)
    # Same id to a different session is an `id` PK conflict no-op (no multi-routing).
    assert {:ok, _} = MessageStore.write(msg, session_b)

    # by_id still returns the one canonical row (Decision #40 identity invariant).
    assert {:ok, loaded} = MessageStore.by_id(msg.id)
    assert loaded.id == msg.id

    # Session-scoped: the message belongs to its first (only) session.
    assert MessageStore.sessions_for_message(msg.id) == ["session://system/default/main"]
  end

  test "cross-session isolation: a message in A appears in A's recent, NOT in B's" do
    sender = URI.new!("entity://team-alpha/agent/test_cc-builder")
    session_a = URI.new!("session://team-alpha/default/A")
    session_b = URI.new!("session://team-alpha/default/B")

    {:ok, _} =
      MessageStore.write(Message.new(sender, %{text: "msg-A1", attachments: []}), session_a)

    {:ok, _} =
      MessageStore.write(Message.new(sender, %{text: "msg-B1", attachments: []}), session_b)

    a_texts =
      MessageStore.recent_in_session(session_a, 100)
      |> Enum.map(& &1.body["text"])
      |> MapSet.new()

    b_texts =
      MessageStore.recent_in_session(session_b, 100)
      |> Enum.map(& &1.body["text"])
      |> MapSet.new()

    assert "msg-A1" in a_texts
    refute "msg-A1" in b_texts
    assert "msg-B1" in b_texts
    refute "msg-B1" in a_texts
  end

  test "write is idempotent on message id — a duplicate write is a no-op (single row)" do
    sender = URI.new!("entity://system/user/admin")
    msg = Message.new(sender, %{text: "once", attachments: []})
    session = URI.new!("session://system/default/main")

    {:ok, _} = MessageStore.write(msg, session)
    {:ok, _} = MessageStore.write(msg, session)

    assert MessageStore.sessions_for_message(msg.id) == ["session://system/default/main"]
  end
end
