defmodule EzagentPluginCr.CrRollbackTest do
  use ExUnit.Case
  alias EzagentPluginCr.CrRollback
  alias EzagentPluginContent.Tenant.TenantRuntime

  setup do
    tid = "test-rollback-#{System.unique_integer([:positive])}"
    release = TenantRuntime.release_path(tid)

    # Create two release versions
    v1 = Path.join(release, "v1")
    v2 = Path.join(release, "v2")
    File.mkdir_p!(v1)
    File.mkdir_p!(v2)

    # Create a _current pointing at v1
    current = TenantRuntime.current_release_path(tid)
    File.ln_s(v1, current)

    on_exit(fn -> File.rm_rf!(release) end)

    {:ok, tid: tid, v1: v1, v2: v2}
  end

  test "rollback switches _current to specified version", %{tid: tid} do
    assert :ok = CrRollback.rollback(tid, "v2")

    current = TenantRuntime.current_release_path(tid)
    assert File.read_link!(current) |> String.ends_with?("/v2")
  end

  test "rollback to nonexistent version returns error", %{tid: tid} do
    assert {:error, _} = CrRollback.rollback(tid, "v99")
  end
end
