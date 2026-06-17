defmodule EzagentPluginLoom.Integration.FeishuMirrorTest do
  @moduledoc "飞书镜像预留桩:未配置凭证时 graceful no-op(不影响主链路);配置后绑定记录。"
  use ExUnit.Case, async: false

  alias EzagentPluginLoom.FeishuMirror

  @session Ezagent.URI.session("loom-fs-#{System.unique_integer([:positive])}", :loom, "main")

  test "no-op when feishu credentials are absent" do
    System.delete_env("FEISHU_BOT_TOKEN")

    refute FeishuMirror.configured?()
    assert {:error, :not_configured} = FeishuMirror.bind(@session, "oc_chat")
    assert {:noop, :not_configured} = FeishuMirror.mirror(@session, %{text: "hi"})
  end

  test "binds + reports delivery-not-wired when configured (stub)" do
    System.put_env("FEISHU_BOT_TOKEN", "stub-token")
    on_exit(fn -> System.delete_env("FEISHU_BOT_TOKEN") end)

    assert FeishuMirror.configured?()
    assert :ok = FeishuMirror.bind(@session, "oc_chat_123")
    assert FeishuMirror.bound_chat(@session) == "oc_chat_123"
    # 绑定了但真实投递未接通(预留)
    assert {:noop, :delivery_not_wired} = FeishuMirror.mirror(@session, %{text: "operator msg"})
  end
end
