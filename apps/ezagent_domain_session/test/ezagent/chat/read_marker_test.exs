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

  use ExUnit.Case, async: false

  alias EzagentCore.Repo
  alias Ezagent.Session.ReadMarker

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

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
        mentions: Jason.encode!([]),
        body: Jason.encode!(%{text: "hi", attachments: []}),
        ref_id: nil,
        inserted_at: inserted_at
      }
    ])

    Repo.insert_all("message_routings", [
      %{
        message_id: msg_uri,
        session_uri: URI.to_string(session_uri),
        inserted_at: inserted_at
      }
    ])

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
      m2 = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:01.000000Z])
      m3 = insert_message(session, user, inserted_at: ~U[2026-01-01 12:00:02.000000Z])

      # delivered = m3 (most recent), but read = m1 (older). HIGHEST
      # confidence (`:read`) should win → unread = 2 (m2 + m3).
      assert {:ok, :updated} = ReadMarker.mark(session, user, m3, :delivered)
      assert {:ok, :updated} = ReadMarker.mark(session, user, m1, :read)

      assert ReadMarker.unread_count(session, user) == 2
    end
  end

  describe "repoint/3 — re-key user_uri (anon→confirmed footprint transfer)" do
    test "plain re-point (to_user has NO existing markers) moves all rows + returns count" do
      session = unique_session_uri("repoint_plain")
      from_user = unique_user_uri("repoint_plain_from")
      to_user = unique_user_uri("repoint_plain_to")

      m1 = insert_message(session, from_user, inserted_at: ~U[2026-01-01 12:00:00.000000Z])
      m2 = insert_message(session, from_user, inserted_at: ~U[2026-01-01 12:00:01.000000Z])

      assert {:ok, :updated} = ReadMarker.mark(session, from_user, m1, :delivered)
      assert {:ok, :updated} = ReadMarker.mark(session, from_user, m2, :read)

      assert {:ok, 2} = ReadMarker.repoint(session, from_user, to_user)

      # from_user has no rows left; to_user now owns both markers unchanged.
      assert ReadMarker.last_read(session, from_user, :delivered) == nil
      assert ReadMarker.last_read(session, from_user, :read) == nil
      assert ReadMarker.last_read(session, to_user, :delivered) == m1
      assert ReadMarker.last_read(session, to_user, :read) == m2
    end

    test "collision (to_user already has a :read marker) keeps the MORE-ADVANCED one, no crash" do
      session = unique_session_uri("repoint_collide")
      from_user = unique_user_uri("repoint_collide_from")
      to_user = unique_user_uri("repoint_collide_to")

      old_msg = insert_message(session, from_user, inserted_at: ~U[2026-01-01 12:00:00.000000Z])
      new_msg = insert_message(session, from_user, inserted_at: ~U[2026-01-01 13:00:00.000000Z])

      # to_user is AHEAD on :read (new_msg); from_user is behind on :read (old_msg).
      assert {:ok, :updated} = ReadMarker.mark(session, to_user, new_msg, :read)
      assert {:ok, :updated} = ReadMarker.mark(session, from_user, old_msg, :read)

      # No duplicate-key crash; the more-advanced (to_user's new_msg) survives.
      assert {:ok, count} = ReadMarker.repoint(session, from_user, to_user)
      assert is_integer(count)

      assert ReadMarker.last_read(session, to_user, :read) == new_msg
      assert ReadMarker.last_read(session, from_user, :read) == nil
    end

    test "collision where FROM_USER is more advanced → to_user inherits the from_user marker" do
      session = unique_session_uri("repoint_collide2")
      from_user = unique_user_uri("repoint_collide2_from")
      to_user = unique_user_uri("repoint_collide2_to")

      old_msg = insert_message(session, from_user, inserted_at: ~U[2026-01-01 12:00:00.000000Z])
      new_msg = insert_message(session, from_user, inserted_at: ~U[2026-01-01 13:00:00.000000Z])

      # to_user behind on :read (old_msg); from_user ahead on :read (new_msg).
      assert {:ok, :updated} = ReadMarker.mark(session, to_user, old_msg, :read)
      assert {:ok, :updated} = ReadMarker.mark(session, from_user, new_msg, :read)

      assert {:ok, _count} = ReadMarker.repoint(session, from_user, to_user)

      assert ReadMarker.last_read(session, to_user, :read) == new_msg
      assert ReadMarker.last_read(session, from_user, :read) == nil
    end

    test "no-op when from_user has no rows → {:ok, 0}" do
      session = unique_session_uri("repoint_noop")
      from_user = unique_user_uri("repoint_noop_from")
      to_user = unique_user_uri("repoint_noop_to")

      assert {:ok, 0} = ReadMarker.repoint(session, from_user, to_user)
    end

    test "only re-keys rows for the GIVEN session, leaving other sessions untouched" do
      session_a = unique_session_uri("repoint_scoped_a")
      session_b = unique_session_uri("repoint_scoped_b")
      from_user = unique_user_uri("repoint_scoped_from")
      to_user = unique_user_uri("repoint_scoped_to")

      ma = insert_message(session_a, from_user)
      mb = insert_message(session_b, from_user)
      assert {:ok, :updated} = ReadMarker.mark(session_a, from_user, ma, :read)
      assert {:ok, :updated} = ReadMarker.mark(session_b, from_user, mb, :read)

      assert {:ok, 1} = ReadMarker.repoint(session_a, from_user, to_user)

      # session_a moved; session_b for from_user is untouched.
      assert ReadMarker.last_read(session_a, to_user, :read) == ma
      assert ReadMarker.last_read(session_b, from_user, :read) == mb
      assert ReadMarker.last_read(session_b, to_user, :read) == nil
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
        Ezagent.Behavior.Session.session_events_topic(session)
      )

      assert {:ok, :updated} = ReadMarker.mark(session, user, msg, :displayed)

      assert_receive {:read_marker_updated, ^session, ^user,
                      %{source: :displayed, last_read_message_uri: ^msg}},
                     1_000
    end
  end
end
