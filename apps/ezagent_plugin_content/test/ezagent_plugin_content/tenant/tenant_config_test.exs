defmodule EzagentPluginContent.Tenant.TenantConfigTest do
  use ExUnit.Case
  alias EzagentPluginContent.Tenant.TenantConfig

  @test_tid "test-tenant-config"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)

    # Write a test tenant config for resolution
    Ezagent.Socialware.ConfigStore.write_and_point(%{
      layer: "workspace",
      workspace_uri: "workspace://#{@test_tid}",
      subject_uri: "entity://system/tenant-config",
      key: "tenant:#{@test_tid}:config",
      body: %{"brand_name" => "TestConfigBrand", "industry" => "cloud-comms"},
      actor_uri: "system://test",
      source_turn_id: "test-turn"
    })

    # Write a test CR
    Ezagent.Socialware.ConfigStore.write_and_point(%{
      layer: "workspace",
      workspace_uri: "workspace://#{@test_tid}",
      subject_uri: "entity://system/cr",
      key: "cr:#{@test_tid}:cr-2026-01-01-001",
      body: %{"cr_id" => "cr-2026-01-01-001", "tenant_id" => @test_tid, "status" => "open"},
      actor_uri: "system://test",
      source_turn_id: "test-turn-cr"
    })

    :ok
  end

  test "read_config returns tenant config body" do
    assert {:ok, body} = TenantConfig.read_config(@test_tid)
    assert body["brand_name"] == "TestConfigBrand"
    assert body["industry"] == "cloud-comms"
  end

  test "read_config returns :none for nonexistent tenant" do
    assert :none = TenantConfig.read_config("nonexistent-tid-xyz")
  end

  test "read_cr returns CR body" do
    assert {:ok, body} = TenantConfig.read_cr(@test_tid, "cr-2026-01-01-001")
    assert body["cr_id"] == "cr-2026-01-01-001"
    assert body["status"] == "open"
  end
end
