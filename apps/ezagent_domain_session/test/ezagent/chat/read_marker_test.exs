defmodule Ezagent.Session.ReadMarkerTest do
  @moduledoc """
  Tests for `Ezagent.Session.ReadMarker` — Read receipts SPEC.

  Exercises:
  - `mark/4` insert + upsert + idempotency + out-of-order (`:already_ahead`)
  - `unread_count/2` with no marker (everything unread) + with marker
    using highest-confidence source
  - `last_read/3` + `list_for/2`
  - PubSub `:read_marker_updated` broadcast on session events topic
  """

  use EzagentCore.DataCase, async: false

  alias EzagentCore.Repo
  alias Ezagent.Session.ReadMarker

  # Sandbox provided by EzagentCore.DataCase (#92).

  # Canonical (`authority: nil`) construction — `ReadMarker.mark/4`
  # rebuilds the broadcast URIs via `Ezagent.URI.new!/1`, so a test
  # pinning `^session`/`^user` must hold the same canonical struct.
  # `URI.parse/1` yields the non-canonical `authority`-bearing shape and
  # the assert_receive pin would never match.
  defp unique_session_uri(suffix) do
    Ezagent.URI.new!(
      "session://team-alpha/default/read_marker_#{suffix}_#{System.unique_integer([:positive])}"
    )
  end

  defp unique_user_uri(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/user/read_marker_user_#{suffix}_#{System.unique_integer([:positive])}"
    )
  end

  defp insert_message(session_uri, sender, opts \\ []) do
    msg_uri = "msg://#{System.unique_integer([:positive])}"
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())

    Repo.insert_all("messages", [
      %{
        id: msg_uri,
        workspace_uri: URI.to_string(Ezagent.Capability.workspace_of(session_uri)),
        session_uri: URI.to_string(session_uri),
        sender: URI.to_string(sender),
        mentions: [],
        body: %{text: "hi", attachments: []},
        ref_id: nil,
        inserted_at: inserted_at
      }
    ])

    # Message session-scoping (2026-06-21): the `messages` row above carries
    # `session_uri`; the `message_routings` join table was removed.
    msg_uri
  end

  describe "mark/4 — insert + upsert + idempotency" do
    test "first call inserts; returns :updated" do
      session = unique_session_uri("first_insert")
      user = unique_user_uri("first_insert")
      msg = insert_message(session, user)

      assert {:ok, :updated} = ReadMarker.mark(session, user, msg, :delivered)
      assert ReadMarker.last_read(session, user, :delivered) == msg
    end

    test "repeat with same message → :already_ahead" do
      session = unique_session_uri("repeat")
      user = unique_user_uri("repeat")
      msg = insert_message(session, user)

      assert {:ok, :updated} = ReadMarker.mark(session, user, msg, :delivered)
      assert {:ok, :already_ahead} = ReadMarker.mark(session, user, msg, :delivered)
    end

    test "newer message → updates marker" do
      session = unique_session_uri("newer")
      user = unique_user_uri("newer")
      old_msg = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:00.000000Z])
      new_msg = insert_message(session, user, inserted_at: ~U[2026-01-01 13:00:00.000000Z])

      assert {:ok, :updated} = ReadMarker.mark(session, user, old_msg, :delivered)
      assert {:ok, :updated} = ReadMarker.mark(session, user, new_msg, :delivered)
      assert ReadMarker.last_read(session, user, :delivered) == new_msg
    end

    test "OLDER message → :already_ahead (out-of-order events tolerated)" do
      session = unique_session_uri("older")
      user = unique_user_uri("older")
      old_msg = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:00.000000Z])
      new_msg = insert_message(session, user, inserted_at: ~U[2026-01-01 13:00:00.000000Z])

      assert {:ok, :updated} = ReadMarker.mark(session, user, new_msg, :delivered)
      assert {:ok, :already_ahead} = ReadMarker.mark(session, user, old_msg, :delivered)
      # Marker unchanged at new_msg
      assert ReadMarker.last_read(session, user, :delivered) == new_msg
    end

    test "invalid source returns {:error, _}" do
      session = unique_session_uri("bad_source")
      user = unique_user_uri("bad_source")

      assert {:error, {:invalid_source, :nonsense}} =
               ReadMarker.mark(session, user, "msg://x", :nonsense)
    end
  end

  describe "unread_count/2" do
    test "no marker → full session message count" do
      session = unique_session_uri("unread_none")
      user = unique_user_uri("unread_none")
      _m1 = insert_message(session, user)
      _m2 = insert_message(session, user)
      _m3 = insert_message(session, user)

      assert ReadMarker.unread_count(session, user) == 3
    end

    test "with marker on second message → 1 unread (the third)" do
      session = unique_session_uri("unread_some")
      user = unique_user_uri("unread_some")

      m1 = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:00.000000Z])
      m2 = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:01.000000Z])
      _m3 = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:02.000000Z])

      assert {:ok, :updated} = ReadMarker.mark(session, user, m2, :read)

      assert ReadMarker.unread_count(session, user) == 1
      _ = m1
    end

    test "highest-confidence source wins when multiple present" do
      session = unique_session_uri("unread_conf")
      user = unique_user_uri("unread_conf")

      m1 = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:00.000000Z])
      _m2 = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:01.000000Z])
      m3 = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:02.000000Z])

      # delivered = m3 (most recent), but read = m1 (older). HIGHEST
      # confidence (`:read`) should win → unread = 2 (m2 + m3).
      assert {:ok, :updated} = ReadMarker.mark(session, user, m3, :delivered)
      assert {:ok, :updated} = ReadMarker.mark(session, user, m1, :read)

      assert ReadMarker.unread_count(session, user) == 2
    end
  end

  describe "list_for/2 + PubSub broadcast" do
    test "list_for returns all sources keyed by atom" do
      session = unique_session_uri("list_for")
      user = unique_user_uri("list_for")
      msg = insert_message(session, user)

      {:ok, :updated} = ReadMarker.mark(session, user, msg, :delivered)
      {:ok, :updated} = ReadMarker.mark(session, user, msg, :read)

      result = ReadMarker.list_for(session, user)

      assert %{delivered: %{last_read_message_uri: ^msg}} = result
      assert %{read: %{last_read_message_uri: ^msg}} = result
    end

    test "mark/4 broadcasts :read_marker_updated on session :events topic" do
      session = unique_session_uri("broadcast")
      user = unique_user_uri("broadcast")
      msg = insert_message(session, user)

      Phoenix.PubSub.subscribe(
        EzagentCore.PubSub,
        Ezagent.ActionSet.Session.session_events_topic(session)
      )

      assert {:ok, :updated} = ReadMarker.mark(session, user, msg, :displayed)

      assert_receive {:read_marker_updated, ^session, ^user,
                      %{source: :displayed, last_read_message_uri: ^msg}},
                     1_000
    end
  end
end
