defmodule EzagentWeb.Socialware.FeedEncodingTest do
  @moduledoc """
  Render-card mechanism (transport only): the customer-SPA feed encoder carries
  an optional `render` json-render node tree + `render_css` from a message body to
  the wire, keyed purely on the body field. These tests use NO producer/agent —
  they construct a message that simply HAS a render body and assert the encoder
  surfaces it (the positive path) and defaults to nil when absent (the empty path).
  """
  use ExUnit.Case, async: true

  alias EzagentWeb.Socialware.FeedEncoding

  defp sender, do: Ezagent.URI.new!("entity://system/user/admin")

  test "a body carrying a render tree (+css) is surfaced on the wire (producer-free)" do
    # Card > Table shape borrowed in structure from #1023; ASCII content only.
    render_tree = %{
      "type" => "Card",
      "props" => %{"title" => "Order summary"},
      "children" => [
        %{
          "type" => "Table",
          "props" => %{"columns" => ["Item", "Qty"], "rows" => [["Widget", 2]]}
        }
      ]
    }

    msg =
      Ezagent.Message.new(sender(), %{
        text: "here is the data",
        render: render_tree,
        render_css: "table{font-size:12px}"
      })

    assert [row] = FeedEncoding.encode_messages([msg])
    assert row.text == "here is the data"
    assert row.render == render_tree
    assert row.render_css == "table{font-size:12px}"
    assert row.sender == URI.to_string(sender())
  end

  test "string-keyed render body is surfaced the same as atom-keyed" do
    # Bodies loaded from the store can be string-keyed; the encoder reads either.
    tree = %{"type" => "Text", "props" => %{"text" => "hi"}}
    msg = %Ezagent.Message{sender: sender(), body: %{"text" => "x", "render" => tree}}

    assert FeedEncoding.message_render(msg) == tree
    assert [%{render: ^tree}] = FeedEncoding.encode_messages([msg])
  end

  test "a body with no render tree surfaces render: nil (plain-text default)" do
    msg = Ezagent.Message.new(sender(), %{text: "plain"})

    assert [%{render: nil, render_css: nil}] = FeedEncoding.encode_messages([msg])
  end
end
