defmodule Ezagent.MessageStoreChatVisibleRecentTest do
  @moduledoc """
  P4 — the CHAT snapshot read primitive that backs the chat_feed `:pull` adapter.

  Chat has NO settlement model and (post-simplification) NO delta cursor — the
  external SPA just re-reads the latest-N window on every advisory. The single
  primitive is:

    * `chat_visible_recent/2` — the N most-recent `:external_visible` messages,
      ASCENDING (oldest→newest), for the snapshot window.

  It filters per-message visibility (`:internal` excluded) and scopes by
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

  # WRITE a external-visible chat message. `routed_at` is captured fresh at
  # write, so sequential calls produce strictly-increasing route timestamps —
  # the deterministic ordering driver for the chat snapshot (NOT msg.inserted_at).
  defp write(session, text, opts \\ []) do
    visibility = Keyword.get(opts, :visibility, :external_visible)

    msg = Message.new(sender(), %{text: text, attachments: []}, visibility: visibility)

    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  describe "chat_visible_recent/2" do
    test "returns external-visible messages ascending by write order, bounded by limit", %{
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

    test "excludes internal messages", %{session: s} do
      write(s, "public")
      write(s, "secret", visibility: :internal)

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

    test "persists message hop budget with default of eight", %{session: s} do
      default_msg = write(s, "default hops")
      assert default_msg.hops == 8

      custom_msg = Message.new(sender(), %{text: "custom hops", attachments: []}, hops: 3)
      {:ok, written} = MessageStore.write(custom_msg, s)
      assert written.hops == 3
    end
  end

  # NOTE: the prior "multi-session routing: routed_at per-session for the SAME
  # message id" describe block was removed with the message session-scoping
  # collapse (2026-06-21) — a message id can no longer live in two sessions, so
  # `routed_at` is simply this session's route/creation time (a real column,
  # covered by "surfaces the per-session routed_at on each row" above).

  defp text(%Message{body: body}), do: Map.get(body, "text") || Map.get(body, :text)
end
