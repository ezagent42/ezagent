defmodule EzagentPluginCr.CrSnapshotTest do
  use ExUnit.Case
  alias EzagentPluginCr.CrSnapshot
  alias EzagentPluginContent.Tenant.TenantRuntime

  setup do
    tid = "test-snap-#{System.unique_integer([:positive])}"
    sandbox = TenantRuntime.sandbox_path(tid)
    release = TenantRuntime.release_path(tid)

    # Create sandbox with content
    File.mkdir_p!(sandbox)
    File.write!(Path.join(sandbox, "CLAUDE.md"), "# Test snapshot")
    File.mkdir_p!(Path.join(sandbox, "skills/agent1"))

    on_exit(fn ->
      File.rm_rf!(sandbox)
      File.rm_rf!(release)
    end)

    {:ok, tid: tid, sandbox: sandbox, release: release}
  end

  test "snapshot copies sandbox to release/v1", %{tid: tid, release: release} do
    assert {:ok, "v1"} = CrSnapshot.snapshot(tid)

    v1 = Path.join(release, "v1")
    assert File.exists?(v1)
    assert File.exists?(Path.join(v1, "CLAUDE.md"))
    assert File.read!(Path.join(v1, "CLAUDE.md")) == "# Test snapshot"
  end

  test "snapshot bumps version number", %{tid: tid, release: release} do
    assert {:ok, "v1"} = CrSnapshot.snapshot(tid)
    assert File.exists?(Path.join(release, "v1"))

    assert {:ok, "v2"} = CrSnapshot.snapshot(tid)
    assert File.exists?(Path.join(release, "v2"))
  end
end
