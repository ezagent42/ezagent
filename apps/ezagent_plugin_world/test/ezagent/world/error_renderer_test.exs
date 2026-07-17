defmodule Ezagent.World.ErrorRendererTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.{ErrorCode, ErrorRenderer}

  @credential_code ErrorCode.lookup("agent_credential_missing")

  describe "render/2 — Layer 1 (user can fix)" do
    test "returns layer 1 card with fix link" do
      card = ErrorRenderer.render(@credential_code, user_can_fix: true)
      assert card.layer == 1
      assert card.what == "Agent 未配置凭证"
      assert card.impact =~ "无法调用 AI 模型"
      assert card.fix_link != nil
      assert card.fix_owner_name == nil
      assert card.notify_action == nil
    end
  end

  describe "render/2 — Layer 2 (user cannot fix, owner exists)" do
    test "returns layer 2 card with notify action" do
      card = ErrorRenderer.render(@credential_code,
        user_can_fix: false,
        fix_owner_display_name: "陈瑞华"
      )
      assert card.layer == 2
      assert card.what == "Agent 未配置凭证"
      assert card.fix_owner_name == "陈瑞华"
      assert card.notify_action != nil
      assert card.notify_action.action == "notification.send"
      assert card.fix_link == nil
    end
  end

  describe "render/2 — Layer 3 (nil / unregistered)" do
    test "returns layer 3 card for nil error code" do
      card = ErrorRenderer.render(nil, [])
      assert card.layer == 3
      assert card.what =~ "内部错误"
      assert is_binary(card.issue_id)
      assert String.starts_with?(card.issue_id, "G5-")
    end
  end

  describe "fix_path_to_url/1" do
    test "agent_keys_page maps to URL" do
      assert ErrorRenderer.fix_path_to_url(:agent_keys_page) =~ "/api-keys"
    end

    test "unknown path returns nil" do
      assert ErrorRenderer.fix_path_to_url(:unknown) == nil
    end
  end
end
