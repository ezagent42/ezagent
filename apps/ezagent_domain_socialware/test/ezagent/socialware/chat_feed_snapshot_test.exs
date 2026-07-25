defmodule Ezagent.Socialware.ChatFeedSnapshotTest do
  @moduledoc """
  P4 — the windowed snapshot-refresh read model for the chat_feed `:pull`
  adapter, exercised at the `ChatFeed` source layer (where the channel's
  join/advisory handlers delegate). This REPLACES the former lower-bound cursor
  join/replay protocol: chat has NO settlement model, so the live view just
  re-reads the CURRENT latest-N snapshot on every advisory.

  Correctness invariant: a message posted after a read appears on the NEXT read
  (`snapshot/2` always returns current state); a dropped advisory is
  self-healing because the next `snapshot/2` re-reads current state. There is no
  cursor to strand on.

  Authorization is the LIVE chat membership predicate (P4-3): the caller is an
  owner/member of the live `:chat` slice. The session is a real chat `Session`
  Kind so `Ezagent.Kind.read(session, :session, spawn: :never)` reflects join/leave live.

  ## Controlling order

  Snapshot ordering is `routed_at` (a FRESH `now` captured per
  `MessageStore.write/2`), so sequential `post/2` calls give strictly-increasing
  route timestamps, exactly how a real feed orders.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.ChatFeed

  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "chat-owner")
  @sender Ezagent.URI.entity(:team_alpha, :agent, "chat-bot")

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :default, "chatfeed-#{System.unique_integer([:positive])}")
  end

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session,
        owner_uri: owner(),
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    %{session: session, workspace: workspace}
  end

  # Write a external-visible chat message via the production store path.
  defp post(session, text) do
    msg = Message.new(@sender, %{text: text, attachments: []}, visibility: :external_visible)
    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  defp post_internal(session, text) do
    msg = Message.new(@sender, %{text: text, attachments: []}, visibility: :internal)
    {:ok, written} = MessageStore.write(msg, session)
    written
  end

  defp rendered_texts({:ok, %{page: page}}), do: rendered_texts(page)
  defp rendered_texts(%{page: page}), do: rendered_texts(page)
  defp rendered_texts(%{children: children}), do: Enum.map(children, & &1.props.text)

  defp rendered_keys({:ok, %{page: page}}), do: Enum.map(page.children, & &1.key)

  describe "snapshot/2 — windowed snapshot-refresh read" do
    test "renders the latest-N external-visible messages (oldest→newest)", ctx do
      post(ctx.session, "first")
      post(ctx.session, "second")
      post(ctx.session, "third")

      {:ok, snap} = ChatFeed.snapshot(ctx.session, owner())
      assert rendered_texts(snap) == ["first", "second", "third"]
    end

    test "internal messages never leak into the snapshot", ctx do
      post(ctx.session, "public")
      post_internal(ctx.session, "secret")
      post(ctx.session, "also public")

      {:ok, snap} = ChatFeed.snapshot(ctx.session, owner())
      texts = rendered_texts(snap)
      assert texts == ["public", "also public"]
      refute "secret" in texts
    end

    test "a message posted AFTER a read appears on the next (advisory) re-read", ctx do
      post(ctx.session, "before")
      {:ok, first} = ChatFeed.snapshot(ctx.session, owner())
      assert rendered_texts(first) == ["before"]

      # A new message arrives — the next snapshot (what an advisory triggers)
      # re-reads CURRENT state and includes it.
      late = post(ctx.session, "after")
      {:ok, second} = ChatFeed.snapshot(ctx.session, owner())
      assert "after" in rendered_texts(second)
      assert late.id in rendered_keys({:ok, second})
    end

    test "SELF-HEALING: a dropped advisory loses nothing — a later re-read shows current state",
         ctx do
      {:ok, _join} = ChatFeed.snapshot(ctx.session, owner())

      # Simulate the advisory for THIS message being dropped (we simply don't
      # re-read here). A LATER, unrelated advisory triggers a re-read.
      dropped = post(ctx.session, "advisory-dropped")
      _later_trigger = post(ctx.session, "later")

      {:ok, healed} = ChatFeed.snapshot(ctx.session, owner())
      texts = rendered_texts(healed)
      assert "advisory-dropped" in texts
      assert "later" in texts
      assert dropped.id in rendered_keys({:ok, healed})
    end

    test "a cross-session relayed message windows in after the next re-read", ctx do
      post(ctx.session, "native")
      {:ok, _first} = ChatFeed.snapshot(ctx.session, owner())

      # The cross-session relay path routes the SAME %Message{} (original, OLD
      # inserted_at) into THIS session via the production write path. routed_at is
      # a fresh now, so it windows at the END of the current snapshot.
      old_inserted_at = ~U[2026-01-01 00:00:00.000000Z]

      relayed =
        Message.new(@sender, %{text: "relayed-from-elsewhere", attachments: []},
          visibility: :external_visible,
          inserted_at: old_inserted_at
        )

      {:ok, _} = MessageStore.write(relayed, ctx.session)

      {:ok, after_relay} = ChatFeed.snapshot(ctx.session, owner())
      texts = rendered_texts(after_relay)
      assert "relayed-from-elsewhere" in texts
      # routed_at-ordered, so the relayed message windows AFTER the native one
      # (it entered the session later) despite its OLD inserted_at.
      assert texts == ["native", "relayed-from-elsewhere"]
    end

    test "snapshot reflects the most-recent window when more than the limit exist", ctx do
      n = ChatFeed.history_limit() + 5
      for i <- 1..n, do: post(ctx.session, "m#{i}")

      {:ok, snap} = ChatFeed.snapshot(ctx.session, owner())
      texts = rendered_texts(snap)
      # The latest-N window: exactly history_limit messages, ending at the newest.
      assert length(texts) == ChatFeed.history_limit()
      assert List.last(texts) == "m#{n}"
    end
  end

  describe "snapshot/2 — LIVE authorization (every read, fail-closed)" do
    test "a non-member is denied", ctx do
      stranger = Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "not-a-member")
      assert {:error, :unauthorized} = ChatFeed.snapshot(ctx.session, stranger)
    end

    test "the owner is allowed", ctx do
      post(ctx.session, "hi")
      assert {:ok, _snap} = ChatFeed.snapshot(ctx.session, owner())
    end

    test "a nil / crafted caller is denied (delegates to ChatMembership)", ctx do
      assert {:error, :unauthorized} = ChatFeed.snapshot(ctx.session, nil)
      assert {:error, :unauthorized} = ChatFeed.snapshot(ctx.session, "not-a-uri")
    end
  end
end
