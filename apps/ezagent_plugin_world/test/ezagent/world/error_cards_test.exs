defmodule Ezagent.World.ErrorCardsTest do
  @moduledoc """
  G5 source 2 — async agent-reply errors: `ErrorCards.enrich/3`
  decodes the structured payload from a reply body and renders the per-viewer
  Layer 1/2/3 card through the SAME ErrorMatcher/ErrorRenderer pipeline the
  sync dispatch path uses.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Agent.ErrorSignal
  alias Ezagent.World.ErrorCards

  @row %{"id" => "msg-123", "text" => "[agent error] no_api_key"}

  defp ctx(can_fix, founder \\ "allen") do
    %{user_can_fix: can_fix, fix_owner_display_name: founder}
  end

  test "a body without an error payload passes through unchanged" do
    body = %{text: "hello", attachments: []}
    assert ErrorCards.enrich(@row, body, ctx(false)) == @row
  end

  test "the lazy viewer-ctx fun is NOT resolved for ordinary messages" do
    body = %{text: "hello", attachments: []}

    assert ErrorCards.enrich(@row, body, fn ->
             flunk("viewer ctx resolved for a message without an error payload")
           end) == @row
  end

  test "member view (cannot fix): no_api_key renders the Layer 2 card + notify action" do
    body = ErrorSignal.reply_body({:no_api_key, "deepseek"})

    row = ErrorCards.enrich(@row, body, ctx(false, "allen"))

    assert %{layer: 2, fix_owner_name: "allen", notify_action: notify} = row["error_card"]
    assert notify.action == "notification.send"
    assert notify.args.type == "error_fix_request"
    assert notify.args.body.error_code == "agent_credential_missing"
  end

  test "admin view (can fix): no_api_key renders the Layer 1 card + fix link" do
    body = ErrorSignal.reply_body({:no_api_key, "deepseek"})

    row = ErrorCards.enrich(@row, body, ctx(true))

    assert %{layer: 1, fix_link: link} = row["error_card"]
    assert is_binary(link)
  end

  test "string-keyed body (post-MessageStore round-trip) is enriched too" do
    body = %{
      "text" => "[agent error] no_api_key",
      "error" => ErrorSignal.encode({:no_api_key, "x"})
    }

    row = ErrorCards.enrich(@row, body, ctx(false, "allen"))
    assert %{layer: 2} = row["error_card"]
  end

  test "unregistered reason renders Layer 3 with a message-deterministic issue id" do
    body = ErrorSignal.reply_body({:generation_failed, "boom"})

    row = ErrorCards.enrich(@row, body, ctx(false))

    assert %{layer: 3, issue_id: "G5-unregistered-msg-123"} = row["error_card"]

    # Deterministic: re-rendering the same durable message mints the SAME id.
    row2 = ErrorCards.enrich(@row, body, ctx(false))
    assert row2["error_card"].issue_id == "G5-unregistered-msg-123"
  end

  test "an undecodable payload still renders the Layer 3 card — never a silent drop" do
    body = %{text: "[agent error] x", error: %{"reason" => ["surely_not_an_existing_atom_g5"]}}

    row = ErrorCards.enrich(@row, body, ctx(false))
    assert %{layer: 3} = row["error_card"]
  end
end
