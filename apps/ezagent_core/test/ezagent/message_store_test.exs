defmodule Ezagent.MessageStoreTest do
  @moduledoc """
  Phase 2 2a-step 3: MessageStore CRUD + query tests.

  Sandbox-mode integration against the SQLite Repo. Validates the 4
  public functions (write/2, in_session_since/2, recent_in_session/2,
  by_id/1) including rejoin-replay edge cases (strict-after timestamp
  semantics) and the @replay_cap bound.

  PR #149 (SPEC v2 §5.13): by_uri renamed to by_id; ref opt renamed to ref_id.
  """

  use EzagentCore.DataCase, async: false
  alias Ezagent.{Message, MessageStore}
  # `Repo` is aliased by `use EzagentCore.DataCase`; no explicit alias needed (#92).

  @session_a URI.new!("session://system/default/main")
  @session_b URI.new!("session://team-alpha/default/other")
  @admin URI.new!("entity://system/user/admin")
  @bot URI.new!("entity://team-alpha/agent/test_cc-builder")

  setup do
    # Sandbox provided by EzagentCore.DataCase (#92).
    # Phase 9 PR-6 (SPEC v3 §7) — MessageStore.write/2 derives
    # workspace_uri via WorkspaceRegistry.lookup/1 on session_uri.
    # Bind both test sessions to the default workspace so writes
    # don't crash on "no workspace binding".
    default_ws = URI.new!("workspace://team-alpha")
    :ok = Ezagent.WorkspaceRegistry.bind(@session_a, default_ws)
    :ok = Ezagent.WorkspaceRegistry.bind(@session_b, default_ws)

    on_exit(fn ->
      Ezagent.WorkspaceRegistry.unbind(@session_a)
      Ezagent.WorkspaceRegistry.unbind(@session_b)
    end)

    :ok
  end

  defp insert_msg(sender, session, body_text, opts \\ []) do
    msg = Message.new(sender, %{text: body_text, attachments: []}, opts)
    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  describe "write/2" do
    test "assigns a durable monotonic session sequence even when timestamps tie" do
      fixed = ~U[2026-07-22 00:00:00.000000Z]

      assert MessageStore.current_session_sequence(@session_a) == 0

      first = insert_msg(@admin, @session_a, "first-at-tie", inserted_at: fixed)
      second = insert_msg(@admin, @session_a, "second-at-tie", inserted_at: fixed)

      assert first.session_seq == 1
      assert second.session_seq == 2
      assert MessageStore.current_session_sequence(@session_a) == 2

      assert [^first, ^second] = MessageStore.in_session_after_sequence(@session_a, 0)
      assert [^second] = MessageStore.in_session_after_sequence(@session_a, 1)
    end

    test "persists message with caller-supplied session_uri" do
      msg = Message.new(@admin, %{text: "hi", attachments: []})
      {:ok, written} = MessageStore.write(msg, @session_a)

      assert written.session_uri == @session_a
      assert written.sender == @admin

      # Round-trip load to confirm SQLite saw it (not just changeset roundtrip).
      assert {:ok, loaded} = MessageStore.by_id(msg.id)
      assert loaded.session_uri == @session_a
    end

    test "preserves the Message envelope identity (Decision #40)" do
      mention = URI.new!("entity://team-alpha/agent/test_cc-builder")
      ref_id = "aabbccdd00000000"

      msg =
        Message.new(@admin, %{text: "carry-through", attachments: []},
          mentions: [mention],
          ref_id: ref_id
        )

      {:ok, written} = MessageStore.write(msg, @session_a)

      # `session_uri` is metadata stamped at write boundary; sender /
      # mentions / ref_id / id / inserted_at all unchanged (Decision
      # #40 — Message identity invariant).
      assert written.id == msg.id
      assert written.sender == msg.sender
      assert written.mentions == [mention]
      assert written.ref_id == ref_id
      assert written.inserted_at == msg.inserted_at

      # PR-EM-6-PRE codex r2 HIGH (2026-05-25) — `write/2` now returns
      # the actually-persisted row (not the caller's struct) so
      # downstream consumers (chat slice `:last_message` →
      # SliceChange.new_slice → external mirror Publisher event) can't
      # publish content the DB never stored. The body field is
      # JSON-roundtripped by ecto_sqlite3, so what comes back has
      # string keys regardless of how the caller built the input —
      # Chat already tolerates both (`body_text/1` + `body_attachments/1`
      # pattern-match atom OR string keys). Assert the LOGICAL identity
      # by checking the values via the shape helpers.
      assert written.body["text"] == "carry-through"
      assert written.body["attachments"] == []
    end

    test "defaults visibility to customer_visible and round-trips internal" do
      default_msg = Message.new(@admin, %{text: "default visible", attachments: []})
      {:ok, default_written} = MessageStore.write(default_msg, @session_a)
      assert default_written.visibility == :external_visible

      draft =
        Message.new(@bot, %{text: "operator draft", attachments: []}, visibility: :internal)

      {:ok, draft_written} = MessageStore.write(draft, @session_a)
      assert draft_written.visibility == :internal

      assert {:ok, loaded} = MessageStore.by_id(draft.id)
      assert loaded.visibility == :internal
    end
  end

  describe "by_id/1" do
    test "returns {:ok, message} for stored id" do
      msg = insert_msg(@admin, @session_a, "lookup-me")
      assert {:ok, loaded} = MessageStore.by_id(msg.id)
      assert loaded.id == msg.id
    end

    test "returns :error for missing id" do
      assert :error = MessageStore.by_id("0000000000000000")
    end
  end

  describe "recent_in_session/2" do
    test "returns descending by inserted_at, bounded by limit, scoped to session" do
      now = DateTime.utc_now()

      # 3 messages in session_a at distinct times
      m1 =
        insert_msg(@admin, @session_a, "first", inserted_at: DateTime.add(now, -300, :second))

      m2 =
        insert_msg(@admin, @session_a, "second", inserted_at: DateTime.add(now, -200, :second))

      m3 =
        insert_msg(@bot, @session_a, "third", inserted_at: DateTime.add(now, -100, :second))

      # 1 message in session_b — must NOT leak into session_a query
      _other = insert_msg(@admin, @session_b, "other-session")

      result = MessageStore.recent_in_session(@session_a, 10)
      ids = Enum.map(result, & &1.id)

      assert ids == [m3.id, m2.id, m1.id]
    end

    test "respects limit" do
      now = DateTime.utc_now()

      for i <- 1..5 do
        insert_msg(@admin, @session_a, "msg-#{i}",
          inserted_at: DateTime.add(now, -i * 10, :second)
        )
      end

      result = MessageStore.recent_in_session(@session_a, 3)
      assert length(result) == 3
    end
  end

  describe "older_than/3 (Phase 5 PR 5 pagination)" do
    test "100-message back-pagination matches spec invariant (51-100 then 1-50)" do
      base = ~U[2026-05-17 10:00:00.000000Z]

      written =
        for i <- 1..100 do
          insert_msg(@admin, @session_a, "msg-#{i}", inserted_at: DateTime.add(base, i, :second))
        end

      # Step 1 — initial recent_in_session(50) reveals msgs 51-100 (descending).
      first_page = MessageStore.recent_in_session(@session_a, 50)
      assert length(first_page) == 50

      first_ids = Enum.map(first_page, & &1.id)
      expected_first = written |> Enum.slice(50, 50) |> Enum.reverse() |> Enum.map(& &1.id)
      assert first_ids == expected_first

      # Step 2 — cursor is the oldest visible (msg-51's inserted_at).
      oldest_visible = List.last(first_page)
      assert oldest_visible.body["text"] == "msg-51"

      # Step 3 — older_than(cursor, 50) reveals msgs 1-50 (descending order).
      second_page = MessageStore.older_than(@session_a, oldest_visible.inserted_at, 50)
      assert length(second_page) == 50

      second_ids = Enum.map(second_page, & &1.id)
      expected_second = written |> Enum.take(50) |> Enum.reverse() |> Enum.map(& &1.id)
      assert second_ids == expected_second

      # Step 4 — no overlap between pages (invariant: each message appears once).
      assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))

      # Step 5 — paging past the start returns []; cursor stays harmless.
      oldest_of_all = List.last(second_page)
      assert oldest_of_all.body["text"] == "msg-1"
      assert MessageStore.older_than(@session_a, oldest_of_all.inserted_at, 50) == []
    end

    test "scoped to session — doesn't bleed across sessions" do
      base = ~U[2026-05-17 11:00:00.000000Z]

      for i <- 1..10 do
        insert_msg(@admin, @session_a, "a-#{i}", inserted_at: DateTime.add(base, i, :second))
      end

      for i <- 1..10 do
        insert_msg(@admin, @session_b, "b-#{i}", inserted_at: DateTime.add(base, i, :second))
      end

      cursor = DateTime.add(base, 11, :second)
      result = MessageStore.older_than(@session_a, cursor, 100)

      assert length(result) == 10
      Enum.each(result, fn m -> assert m.session_uri == @session_a end)
    end
  end

  describe "in_session_since/2" do
    test "returns strictly-after `since`, ascending, scoped to session" do
      t0 = ~U[2026-05-16 10:00:00.000000Z]
      t1 = ~U[2026-05-16 10:05:00.000000Z]
      t2 = ~U[2026-05-16 10:10:00.000000Z]
      t3 = ~U[2026-05-16 10:15:00.000000Z]

      _at_t0 = insert_msg(@admin, @session_a, "at-t0", inserted_at: t0)
      at_t1 = insert_msg(@admin, @session_a, "at-t1", inserted_at: t1)
      at_t2 = insert_msg(@bot, @session_a, "at-t2", inserted_at: t2)
      at_t3 = insert_msg(@admin, @session_a, "at-t3", inserted_at: t3)
      _other_session = insert_msg(@admin, @session_b, "other", inserted_at: t2)

      # since = t1 → must EXCLUDE at_t1 (strict-after), include t2, t3.
      result = MessageStore.in_session_since(@session_a, t1)
      ids = Enum.map(result, & &1.id)
      assert ids == [at_t2.id, at_t3.id]

      # since = t0 → includes everything after t0 (t1/t2/t3) in session_a.
      result_t0 = MessageStore.in_session_since(@session_a, t0)
      assert Enum.map(result_t0, & &1.id) == [at_t1.id, at_t2.id, at_t3.id]
    end

    test "empty result when nothing newer than since" do
      msg = insert_msg(@admin, @session_a, "only-one")
      # Use msg's own inserted_at as the since → strict-after must exclude self
      assert MessageStore.in_session_since(@session_a, msg.inserted_at) == []
    end
  end
end
