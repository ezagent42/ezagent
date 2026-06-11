defmodule Ezagent.MessageStoreChatVisibleRecentTest do
  @moduledoc """
  P4 — the CHAT snapshot read primitive that backs the chat_feed `:pull` adapter.

  Chat has NO settlement model and (post-simplification) NO delta cursor — the
  external SPA just re-reads the latest-N window on every advisory. The single
  primitive is:

    * `chat_visible_recent/2` — the N most-recent `:customer_visible` messages,
      ASCENDING (oldest→newest), for the snapshot window.

  It filters per-message visibility (`:operator_only` excluded) and scopes by
  session + workspace (defense-in-depth, mirroring the existing chat queries),
  ordered by `routed_at` (the per-session ROUTE-INTO-THIS-SESSION time) so a
  cross-session-relayed message windows at its arrival position here.

  ## Controlling order

  `routed_at` is a FRESH `now` captured at each `MessageStore.write/2`, so the
  natural way a real feed orders is WRITE ORDER — sequential writes give
  strictly increasing `routed_at`. These tests therefore control ordering by the
  ORDER they call `write/2`, NOT by crafting `msg.inserted_at` (which does not
  drive the chat snapshot ordering).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :default, "chatcur-#{System.unique_integer([:positive])}")
  end

  defp sender, do: Ezagent.URI.entity(:team_alpha, :user, "alice")

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    %{session: session, workspace: workspace}
  end

  # WRITE a customer-visible chat message. `routed_at` is captured fresh at
  # write, so sequential calls produce strictly-increasing route timestamps —
  # the deterministic ordering driver for the chat snapshot (NOT msg.inserted_at).
  defp write(session, text, opts \\ []) do
    visibility = Keyword.get(opts, :visibility, :customer_visible)

    msg = Message.new(sender(), %{text: text, attachments: []}, visibility: visibility)

    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  describe "chat_visible_recent/2" do
    test "returns customer-visible messages ascending by write order, bounded by limit", %{
      session: s
    } do
      _a = write(s, "a")
      _b = write(s, "b")
      _c = write(s, "c")

      texts = s |> MessageStore.chat_visible_recent(10) |> Enum.map(&text(&1))
      assert texts == ["a", "b", "c"]

      # limit keeps the MOST RECENT N (latest by routed_at), still ascending
      assert s |> MessageStore.chat_visible_recent(2) |> Enum.map(&text(&1)) == ["b", "c"]
    end

    test "excludes operator_only messages", %{session: s} do
      write(s, "public")
      write(s, "secret", visibility: :operator_only)

      assert s |> MessageStore.chat_visible_recent(10) |> Enum.map(&text(&1)) == ["public"]
    end

    test "scopes by session", %{session: s, workspace: ws} do
      other = session_uri()
      :ok = Ezagent.WorkspaceRegistry.bind(other, ws)
      write(s, "mine")
      write(other, "theirs")

      assert s |> MessageStore.chat_visible_recent(10) |> Enum.map(&text(&1)) == ["mine"]
    end

    test "surfaces the per-session routed_at on each row", %{session: s} do
      write(s, "a")
      [row] = MessageStore.chat_visible_recent(s, 10)
      assert %DateTime{} = row.routed_at
    end
  end

  describe "multi-session routing: routed_at is the ROUTE-INTO-THIS-SESSION time" do
    test "the SAME message id routed into two sessions carries each session's OWN route time, NOT msg.inserted_at",
         %{session: s_a, workspace: ws_a} do
      # The PRODUCTION relay routes the SAME %Message{} (original, OLD
      # inserted_at) into a second session — it does NOT mutate inserted_at.
      old_inserted_at = ~U[2026-01-01 00:00:00.000000Z]

      m =
        Message.new(sender(), %{text: "shared", attachments: []},
          visibility: :customer_visible,
          inserted_at: old_inserted_at
        )

      {:ok, _} = MessageStore.write(m, s_a)

      # Route the SAME %Message{} (same id, same OLD inserted_at) into session B
      # — the realistic cross-session path. write/2 upserts the message row
      # (on_conflict :nothing → keeps the shared inserted_at) and inserts B's
      # routing with routed_at = a FRESH now.
      s_b = session_uri()
      ws_b = Ezagent.Capability.workspace_of(s_b)
      :ok = Ezagent.WorkspaceRegistry.bind(s_b, ws_b)
      {:ok, _} = MessageStore.write(m, s_b)

      [row_a] = MessageStore.chat_visible_recent(s_a, 10)
      [row_b] = MessageStore.chat_visible_recent(s_b, 10)

      assert row_a.id == m.id and row_b.id == m.id

      # Each session's routed_at is a fresh route timestamp — strictly AFTER the
      # message's OLD creation time, and B's is at-or-after A's (B routed later).
      assert DateTime.compare(row_a.routed_at, old_inserted_at) == :gt
      assert DateTime.compare(row_b.routed_at, old_inserted_at) == :gt
      assert DateTime.compare(row_b.routed_at, row_a.routed_at) in [:gt, :eq]

      # The shared `messages.inserted_at` stays the OLD value for BOTH (the
      # message row is shared) — proving routed_at ≠ messages.inserted_at, so the
      # snapshot windows the relayed message at its route-into-session time.
      assert row_a.inserted_at == old_inserted_at
      assert row_b.inserted_at == old_inserted_at

      _ = ws_a
    end
  end

  defp text(%Message{body: body}), do: Map.get(body, "text") || Map.get(body, :text)
end
