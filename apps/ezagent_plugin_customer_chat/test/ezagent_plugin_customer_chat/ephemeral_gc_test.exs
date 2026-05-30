defmodule EzagentPluginCustomerChat.EphemeralGcTest do
  use ExUnit.Case, async: true
  alias EzagentPluginCustomerChat.EphemeralGc

  test "ephemeral_keys selects per-conversation cc_cust template keys only" do
    templates = %{
      "cc.agent.cc_cs_main" => %{},
      "cc.agent.cc_cust_abc" => %{},
      "cc.agent.cc_cust_xyz" => %{},
      "echo.agent.something" => %{}
    }

    assert EphemeralGc.ephemeral_keys(templates) |> Enum.sort() ==
             ["cc.agent.cc_cust_abc", "cc.agent.cc_cust_xyz"]
  end

  test "ephemeral_keys keeps provisioned + non-cc agents, returns [] when none match" do
    templates = %{"cc.agent.cc_cs_main" => %{}, "curl.agent.x" => %{}}
    assert EphemeralGc.ephemeral_keys(templates) == []
  end
end
