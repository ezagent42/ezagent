defmodule EzagentPluginEmail.PluginBootTest do
  use ExUnit.Case, async: true

  test "plugin_info declares the email slug" do
    info = EzagentPluginEmail.Application.plugin_info()
    assert info.slug == "email"
    assert info.name == "Email"
    assert is_binary(info.version)
  end

  test "the OTP app is loaded" do
    assert Enum.any?(Application.loaded_applications(), &(elem(&1, 0) == :ezagent_plugin_email))
  end
end
