defmodule EzagentPluginCr.CrEngineTest do
  use ExUnit.Case
  alias EzagentPluginCr.CrEngine
  alias EzagentPluginContent.Tenant.TenantRuntime

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    tid = "test-cr-#{System.unique_integer([:positive])}"

    # Create a minimal valid sandbox for publish (lint R02 requires CLAUDE.md, skills/, kb/)
    sandbox = TenantRuntime.sandbox_path(tid)
    File.mkdir_p!(sandbox)
    File.write!(Path.join(sandbox, "CLAUDE.md"), "# Test CR Engine")
    File.mkdir_p!(Path.join(sandbox, "skills"))
    File.mkdir_p!(Path.join(sandbox, "kb"))

    on_exit(fn ->
      File.rm_rf!(sandbox)
      base = TenantRuntime.release_path(tid)
      if File.exists?(base), do: File.rm_rf!(base)
    end)

    {:ok, tid: tid}
  end

  describe "ensure_active_cr/1" do
    test "creates a new open CR when none exists", %{tid: tid} do
      assert {:ok, cr} = CrEngine.ensure_active_cr(tid)
      assert cr["status"] == "open"
      assert cr["tenant_id"] == tid
      assert String.starts_with?(cr["cr_id"], "cr-")
    end

    test "returns existing open CR", %{tid: tid} do
      {:ok, cr1} = CrEngine.ensure_active_cr(tid)
      {:ok, cr2} = CrEngine.ensure_active_cr(tid)
      assert cr1["cr_id"] == cr2["cr_id"]
      assert cr1["status"] == "open"
    end
  end

  describe "publish/1" do
    test "publishes the active CR", %{tid: tid} do
      {:ok, published} = CrEngine.publish(tid)
      assert published["status"] == "published"
      assert published["published_version"] == "v1"
      assert published["published_at"]
    end

    test "bumps version on subsequent publishes", %{tid: tid} do
      {:ok, cr1} = CrEngine.publish(tid)
      assert cr1["published_version"] == "v1"

      # After publishing, the CR is no longer open, so a new one is created
      {:ok, cr2} = CrEngine.publish(tid)
      assert cr2["published_version"] == "v2"
      assert cr2["cr_id"] != cr1["cr_id"]
    end
  end

  describe "cancel/1" do
    test "cancels the active CR", %{tid: tid} do
      {:ok, cr} = CrEngine.ensure_active_cr(tid)
      {:ok, cancelled} = CrEngine.cancel(tid)
      assert cancelled["status"] == "cancelled"
      assert cancelled["cr_id"] == cr["cr_id"]
    end
  end

  test "full lifecycle: create -> publish -> new create -> cancel", %{tid: tid} do
    # First CR: create and publish
    {:ok, cr1} = CrEngine.ensure_active_cr(tid)
    assert cr1["status"] == "open"

    {:ok, published} = CrEngine.publish(tid)
    assert published["status"] == "published"
    assert published["published_version"] == "v1"

    # After publish, a new CR is automatically created for the second publish
    {:ok, cr2} = CrEngine.ensure_active_cr(tid)
    assert cr2["status"] == "open"
    assert cr2["cr_id"] != cr1["cr_id"]

    # Publish second CR
    {:ok, published2} = CrEngine.publish(tid)
    assert published2["published_version"] == "v2"

    # Create and cancel third
    {:ok, cr3} = CrEngine.ensure_active_cr(tid)
    {:ok, cancelled} = CrEngine.cancel(tid)
    assert cancelled["status"] == "cancelled"
    assert cancelled["cr_id"] == cr3["cr_id"]
  end
end
