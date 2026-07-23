defmodule EzagentPluginHello.HomeWorkspaceTest do
  @moduledoc """
  Split-brain invariant (hello-A PR-1): there is exactly ONE source of truth
  for the hello home workspace — `EzagentPluginHello.home_workspace/0`
  (`:ezagent_plugin_hello, :home_workspace`, default `"ezagent"`) — and every
  consumer reads it:

    * the #185 credential-bridge destination (`CredentialBridge`);
    * the `/hello/<name>` serve side (`ChatFeedController.show_by_name/2` —
      covered end-to-end by `EzagentWeb.Socialware.ChatFeedControllerTest`,
      which overrides this same key);
    * the boot 官网 seed workspace (`OfficialSiteSeed` — the seed-side leg of
      this invariant is asserted in `OfficialSiteSeedTest`).

  A future edit that re-introduces a second literal/key turns this file RED.
  """
  use ExUnit.Case, async: false

  alias EzagentPluginHello.CredentialBridge

  test "the default home workspace is ezagent" do
    assert EzagentPluginHello.home_workspace() == "ezagent"
  end

  test "the credential-bridge destination IS the home workspace (one read point)" do
    assert CredentialBridge.destination_workspace() == EzagentPluginHello.home_workspace()
  end

  test "a config override moves BOTH the accessor and the bridge destination" do
    previous = Application.get_env(:ezagent_plugin_hello, :home_workspace)
    Application.put_env(:ezagent_plugin_hello, :home_workspace, "hello-home-override")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ezagent_plugin_hello, :home_workspace, previous),
        else: Application.delete_env(:ezagent_plugin_hello, :home_workspace)
    end)

    assert EzagentPluginHello.home_workspace() == "hello-home-override"
    assert CredentialBridge.destination_workspace() == "hello-home-override"
  end
end
