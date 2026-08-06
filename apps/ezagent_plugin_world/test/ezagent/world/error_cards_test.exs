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

  @front_desk_uri Ezagent.URI.new!("entity://system/agent/front-desk-1")
  @llm_uri Ezagent.URI.new!("entity://system/agent/llm-1")
  @row %{
    "id" => "msg-123",
    "text" => "[agent error] no_api_key",
    "sender" => URI.to_string(@front_desk_uri),
    "sender_kind" => "agent"
  }

  defp ctx(can_fix, founder \\ "allen") do
    %{
      user_can_fix: can_fix,
      fix_owner_display_name: founder,
      role_members: %{"llm" => @llm_uri}
    }
  end

  test "a body without an error payload passes through unchanged" do
    body = %{text: "hello", attachments: []}
    assert ErrorCards.enrich(@row, body, ctx(false)) == @row
  end

  # Adversarial review #1 — forgeable cards: a NON-agent sender (user/plugin)
  # smuggling an `error` payload into a normal chat body must NOT produce a
  # card (nor its founder-notify action). sender_kind is server-derived from
  # the sender URI, not caller-supplied body data.
  test "a user-sent message with a forged error payload is NOT enriched" do
    body = ErrorSignal.reply_body({:no_api_key, "deepseek"})

    for kind <- ["user", "other", nil] do
      row = Map.put(@row, "sender_kind", kind)
      assert ErrorCards.enrich(row, body, ctx(false)) == row
    end
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

    assert link ==
             "/identities/agents/#{URI.encode_www_form(URI.to_string(@llm_uri))}/api-keys"

    refute link =~ URI.encode_www_form(URI.to_string(@front_desk_uri))
  end

  test "admin view without a unique llm member does not emit a misleading direct link" do
    body = ErrorSignal.reply_body({:no_api_key, "deepseek"})
    viewer_ctx = %{ctx(true) | role_members: %{}}

    row = ErrorCards.enrich(@row, body, viewer_ctx)

    assert row["error_card"].layer != 1
    assert row["error_card"].fix_link == nil
  end

  test "viewer context indexes only unique session role members" do
    front_desk_members = %{
      @front_desk_uri => %{role_name: "front-desk"},
      @llm_uri => %{role_name: "llm"}
    }

    assert %{role_members: %{"front-desk" => @front_desk_uri, "llm" => @llm_uri}} =
             ErrorCards.viewer_ctx(nil, MapSet.new(), nil, front_desk_members)

    duplicate_llm_uri = Ezagent.URI.new!("entity://system/agent/llm-2")
    duplicate_members = Map.put(front_desk_members, duplicate_llm_uri, %{role_name: "llm"})
    viewer_ctx = ErrorCards.viewer_ctx(nil, MapSet.new(), nil, duplicate_members)

    refute Map.has_key?(viewer_ctx.role_members, "llm")

    non_agent_uri = Ezagent.URI.new!("entity://system/user/not-an-agent")

    non_agent_ctx =
      ErrorCards.viewer_ctx(nil, MapSet.new(), nil, %{
        non_agent_uri => %{"role_name" => "llm"}
      })

    refute Map.has_key?(non_agent_ctx.role_members, "llm")
  end

  test "string-keyed body (post-MessageStore round-trip) is enriched too" do
    body = %{
      "text" => "[agent error] no_api_key",
      "error" => ErrorSignal.encode({:no_api_key, "x"})
    }

    row = ErrorCards.enrich(@row, body, ctx(false, "allen"))
    assert %{layer: 2} = row["error_card"]
  end

  test "generation timeout renders an explicit timeout card" do
    body = ErrorSignal.reply_body(:generation_timeout)

    row = ErrorCards.enrich(@row, body, ctx(false))

    assert %{what: what, impact: impact} = row["error_card"]
    assert what =~ "超时"
    assert impact =~ "重新发送"
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
