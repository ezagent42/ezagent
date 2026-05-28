defmodule EzagentPluginLiveview.CustomerChat.ThemeTest do
  # async: false — test 3 mutates global Application env (:customer_chat_themes);
  # process-global put/delete must not race with concurrent cases.
  use ExUnit.Case, async: false
  alias EzagentPluginLiveview.CustomerChat.Theme

  test "unknown tenant returns defaults with the tenant title interpolated" do
    t = Theme.for_tenant("no_such_tenant")
    assert t.title == "no_such_tenant"
    assert t.primary_color == "#2563eb"
    assert is_binary(t.welcome_message)
    assert is_binary(t.placeholder)
    assert t.logo_url == nil
  end

  test "acme fixture overrides defaults" do
    t = Theme.for_tenant("acme")
    assert t.title == "Acme Support"
    assert t.primary_color == "#e11d48"
    assert t.welcome_message =~ "Acme"
  end

  test "config override beats fixture file" do
    Application.put_env(:ezagent_plugin_liveview, :customer_chat_themes, %{
      "acme" => %{"title" => "Overridden", "primary_color" => "#000000"}
    })
    on_exit(fn -> Application.delete_env(:ezagent_plugin_liveview, :customer_chat_themes) end)

    t = Theme.for_tenant("acme")
    assert t.title == "Overridden"
    assert t.primary_color == "#000000"
    # unspecified keys still fall back to defaults
    assert is_binary(t.placeholder)
  end
end
