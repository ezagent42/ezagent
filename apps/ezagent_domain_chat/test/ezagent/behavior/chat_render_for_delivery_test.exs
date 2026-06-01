defmodule Ezagent.Behavior.ChatRenderForDeliveryTest do
  @moduledoc """
  Pure unit tests for the PR-4b delivery transform (team-routing-unification
  §3.4): `Chat.render_for_delivery/4` + `Chat.message_vars/2`. No DB / no full
  runtime — these are pure functions over a message + ctx + templates map.
  """
  use ExUnit.Case, async: true
  alias Ezagent.{Behavior.Chat, Message}

  @session URI.new!("session://default/system/main")

  defp msg(text) do
    Message.new(URI.new!("entity://user/system/admin"), %{text: text, attachments: []},
      mentions: []
    )
  end

  describe "render_for_delivery/4" do
    test "renders the matched rule's template into the message body" do
      templates = %{"telephone_hop" => "接龙：{body}（by {sender}）"}
      ctx = %{rule_id: 1, rule_set: "telephone", prompt_template_ref: "telephone_hop"}

      out = Chat.render_for_delivery(msg("山顶的雪化了"), ctx, templates, @session)
      assert out.body.text == "接龙：山顶的雪化了（by entity://user/system/admin）"
      # only the body text is rewritten; identity fields are preserved
      assert out.sender == URI.new!("entity://user/system/admin")
    end

    test "message is UNCHANGED when ctx has no / unknown / nil template ref" do
      m = msg("hello")
      assert Chat.render_for_delivery(m, %{prompt_template_ref: nil}, %{}, @session) == m
      assert Chat.render_for_delivery(m, nil, %{}, @session) == m
      assert Chat.render_for_delivery(m, %{prompt_template_ref: "missing"}, %{}, @session) == m

      # ref present but the template map has it → renders; sanity that the
      # "unchanged" cases above are genuinely the no-op path
      refute Chat.render_for_delivery(
               m,
               %{prompt_template_ref: "t"},
               %{"t" => "X {body}"},
               @session
             ) == m
    end
  end

  describe "message_vars/2" do
    test "extracts sender / body / session" do
      vars = Chat.message_vars(msg("hi there"), @session)
      assert vars.sender == "entity://user/system/admin"
      assert vars.body == "hi there"
      assert vars.session == "session://default/system/main"
      # sent_at present (Message defaults inserted_at); flavor "" (deferred)
      assert is_binary(vars.sent_at)
      assert vars.flavor == ""
    end
  end
end
