defmodule Ezagent.Socialware.ChatFeedTest do
  @moduledoc """
  P4-1 — the PURE chat → `customer_tree` json-render projection.

  `ChatFeed.chat_tree/1` is a deterministic, side-effect-free projection of a
  chat message list into the SAME json-render shape the customer SPA renders
  (`%{type: "container", props: %{layout: "stack"}, children: [text nodes]}`),
  served over the SAME P3-2 Channel + SPA. Per-message visibility is applied:
  only `:customer_visible` messages are projected (an `:operator_only` chat
  message — if one ever exists — is dropped, so it never leaks to the external
  read). The membership gate (who may call at all) is enforced separately by the
  ChatMembership predicate (P4-3); this module is the pure render only.
  """
  use ExUnit.Case, async: true

  alias Ezagent.{Message, Socialware.ChatFeed}

  @sender Ezagent.URI.entity(:team_alpha, :user, "alice")
  @other Ezagent.URI.entity(:team_alpha, :agent, "bot")

  defp msg(text, opts) do
    visibility = Keyword.get(opts, :visibility, :customer_visible)
    id = Keyword.get(opts, :id, "m-#{System.unique_integer([:positive])}")
    sender = Keyword.get(opts, :sender, @sender)

    %Message{
      id: id,
      sender: sender,
      body: %{"text" => text},
      visibility: visibility,
      inserted_at: DateTime.utc_now()
    }
  end

  describe "chat_tree/1 — pure, deterministic projection" do
    test "msg helper default visibility (suppresses unused-default warning)" do
      assert ChatFeed.chat_tree([msg("x", [])]).children |> length() == 1
    end

    test "empty message list renders an empty stack container" do
      assert ChatFeed.chat_tree([]) == %{
               type: "container",
               props: %{layout: "stack"},
               children: []
             }
    end

    test "each customer-visible message becomes a text node in order" do
      messages = [msg("hello", id: "a"), msg("world", id: "b")]

      assert ChatFeed.chat_tree(messages) == %{
               type: "container",
               props: %{layout: "stack"},
               children: [
                 %{type: "text", key: "a", props: %{text: "hello"}},
                 %{type: "text", key: "b", props: %{text: "world"}}
               ]
             }
    end

    test "is deterministic — same input yields byte-identical output" do
      messages = [msg("one", id: "x"), msg("two", id: "y")]
      assert ChatFeed.chat_tree(messages) == ChatFeed.chat_tree(messages)
    end

    test "VISIBILITY: operator_only messages are filtered out of the projection" do
      messages = [
        msg("public", id: "p", visibility: :customer_visible),
        msg("secret", id: "s", visibility: :operator_only),
        msg("also public", id: "q", visibility: :customer_visible)
      ]

      tree = ChatFeed.chat_tree(messages)
      keys = Enum.map(tree.children, & &1.key)
      assert keys == ["p", "q"]
      refute Enum.any?(tree.children, &(&1.props.text == "secret"))
    end

    test "reads text from a string-keyed OR atom-keyed body" do
      atom_body = %Message{
        id: "atom",
        sender: @other,
        body: %{text: "atom-text"},
        visibility: :customer_visible,
        inserted_at: DateTime.utc_now()
      }

      tree = ChatFeed.chat_tree([atom_body])
      assert [%{props: %{text: "atom-text"}}] = tree.children
    end

    test "a message with no text renders an empty-string text node (never crashes)" do
      no_text = %Message{
        id: "nt",
        sender: @sender,
        body: %{"attachments" => []},
        visibility: :customer_visible,
        inserted_at: DateTime.utc_now()
      }

      assert [%{type: "text", key: "nt", props: %{text: ""}}] =
               ChatFeed.chat_tree([no_text]).children
    end
  end
end
