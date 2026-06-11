defmodule EzagentPluginContent.Tenant.TenantProvisionerTest do
  use ExUnit.Case
  alias EzagentPluginContent.Tenant.TenantProvisioner

  @test_tid "test-tenant-via-provisioner"
  @test_role "customer"

  setup do
    # Checkout Ecto sandbox for DB writes (ConfigStore)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)

    # Override tenant_base_dir to a temp directory for clean test isolation
    tmp = Path.join(System.tmp_dir!(), "prov_test_#{System.unique_integer()}")
    prev = Application.get_env(:ezagent_plugin_content, :tenant_base_dir)
    Application.put_env(:ezagent_plugin_content, :tenant_base_dir, tmp)
    on_exit(fn ->
      if prev, do: Application.put_env(:ezagent_plugin_content, :tenant_base_dir, prev)
      File.rm_rf!(tmp)
    end)
    {:ok, base_dir: tmp}
  end

  test "create_tenant creates sandbox directory structure" do
    assert {:ok, result} = TenantProvisioner.create_tenant(@test_tid, "TestBrand", industry: "cloud-comms", role: @test_role)

    assert result.tenant_id == @test_tid
    assert result.cr_id =~ "cr-"

    sandbox = result.sandbox
    assert File.dir?(sandbox)
    assert File.dir?(Path.join(sandbox, "slots"))
    assert File.dir?(Path.join(sandbox, "souls"))
    assert File.dir?(Path.join(sandbox, "skills/#{@test_role}"))
    assert File.dir?(Path.join(sandbox, "kb"))
    assert File.dir?(Path.join(sandbox, "config"))
  end

  test "create_tenant with custom industry and role" do
    assert {:ok, result} = TenantProvisioner.create_tenant("custom-tid", "CustomBrand", industry: "fintech", role: "agent")

    assert result.tenant_id == "custom-tid"
    sandbox = result.sandbox
    assert File.dir?(Path.join(sandbox, "skills/agent"))
    assert File.dir?(Path.join(sandbox, "souls"))
  end

  test "create_tenant with default opts" do
    assert {:ok, result} = TenantProvisioner.create_tenant("default-tid", "DefaultBrand")

    assert result.tenant_id == "default-tid"
    sandbox = result.sandbox
    assert File.dir?(Path.join(sandbox, "skills/customer"))
  end
end
