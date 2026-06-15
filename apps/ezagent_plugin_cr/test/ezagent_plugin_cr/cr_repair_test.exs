defmodule EzagentPluginCr.CrRepairTest do
  @moduledoc """
  Crash-recovery for the mark-before-flip publish gap.

  `CrEngine.publish/1` marks the CR "published vN" (a durable write) BEFORE
  flipping `_current` → vN. A crash between the two leaves the CR saying
  "published vN" while `_current` still points at vN-1 (or is absent).
  `repair_current/1` detects that gap and completes the flip idempotently.
  """
  use ExUnit.Case

  alias EzagentPluginCr.CrEngine
  alias EzagentPluginContent.Tenant.TenantRuntime

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    tid = "test-cr-repair-#{System.unique_integer([:positive])}"

    sandbox = TenantRuntime.sandbox_path(tid)
    File.mkdir_p!(sandbox)
    File.write!(Path.join(sandbox, "CLAUDE.md"), "# Repair test")
    File.mkdir_p!(Path.join(sandbox, "skills"))
    File.mkdir_p!(Path.join(sandbox, "kb"))

    on_exit(fn ->
      File.rm_rf!(sandbox)
      base = TenantRuntime.release_path(tid)
      if File.exists?(base), do: File.rm_rf!(base)
    end)

    {:ok, tid: tid}
  end

  defp current_target(tid) do
    case File.read_link(TenantRuntime.current_release_path(tid)) do
      {:ok, dest} -> Path.expand(dest)
      _ -> nil
    end
  end

  test "repair_current/1 completes a half-finished publish (marked, pointer not flipped)",
       %{tid: tid} do
    # Publish normally to establish v1.
    {:ok, _} = CrEngine.publish(tid)
    v1 = Path.expand(Path.join(TenantRuntime.release_path(tid), "v1"))
    assert current_target(tid) == v1

    # Simulate a crash mid-publish of v2: the v2 release dir is materialized and
    # the CR pointer is marked "published v2", but _current was NEVER flipped
    # (it still points at v1). We reproduce that on-disk state directly.
    release = TenantRuntime.release_path(tid)
    File.cp_r!(TenantRuntime.sandbox_path(tid), Path.join(release, "v2"))
    v2 = Path.expand(Path.join(release, "v2"))

    # Mark the active CR pointer as "published v2" (durable write done; flip not).
    {:ok, cr} = CrEngine.ensure_active_cr(tid)

    {:ok, _} =
      Ezagent.Socialware.ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: "workspace://#{tid}",
        subject_uri: "entity://system/cr",
        key: "cr:#{tid}:active",
        body:
          Map.merge(cr, %{
            "status" => "published",
            "published_version" => "v2",
            "published_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }),
        actor_uri: "system://cr-engine",
        source_turn_id: "publish"
      })

    # Pre-condition: gap exists — CR says v2 but pointer still at v1.
    assert current_target(tid) == v1

    # Repair completes the flip.
    assert {:ok, :repaired} = CrEngine.repair_current(tid)
    assert current_target(tid) == v2

    # Idempotent: a second repair is a no-op.
    assert {:ok, :consistent} = CrEngine.repair_current(tid)
    assert current_target(tid) == v2
  end

  test "repair_current/1 is consistent when no publish has happened", %{tid: tid} do
    {:ok, _} = CrEngine.ensure_active_cr(tid)
    assert {:ok, :consistent} = CrEngine.repair_current(tid)
  end

  test "repair_current/1 is consistent right after a clean publish", %{tid: tid} do
    {:ok, _} = CrEngine.publish(tid)
    assert {:ok, :consistent} = CrEngine.repair_current(tid)
  end

  test "publish/1 self-heals a half-finished prior publish before allocating", %{tid: tid} do
    {:ok, _} = CrEngine.publish(tid)

    # Inject the same v2 half-finished gap.
    release = TenantRuntime.release_path(tid)
    File.cp_r!(TenantRuntime.sandbox_path(tid), Path.join(release, "v2"))
    {:ok, cr} = CrEngine.ensure_active_cr(tid)

    {:ok, _} =
      Ezagent.Socialware.ConfigStore.write_and_point(%{
        layer: "workspace",
        workspace_uri: "workspace://#{tid}",
        subject_uri: "entity://system/cr",
        key: "cr:#{tid}:active",
        body: Map.merge(cr, %{"status" => "published", "published_version" => "v2"}),
        actor_uri: "system://cr-engine",
        source_turn_id: "publish"
      })

    # A fresh publish first repairs (flips to v2), then publishes v3.
    {:ok, published} = CrEngine.publish(tid)
    assert published["published_version"] == "v3"
    assert current_target(tid) == Path.expand(Path.join(release, "v3"))
  end
end
