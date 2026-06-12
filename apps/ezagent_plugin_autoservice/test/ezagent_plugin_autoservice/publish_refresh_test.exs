defmodule EzagentPluginAutoservice.PublishRefreshTest do
  @moduledoc """
  publish → running-agent refresh (post-publish slow CLAUDE.md re-render).

  Strategy (no real PTY — `create_agents: false` style):
  - Build a minimal valid tenant sandbox (lint R02 requires CLAUDE.md/skills/kb)
    and write a sentinel into the sandbox soul (`sandbox/soul/slow.md`).
  - Pre-create the slow agent work dir the way `CustomerSession.maybe_slow_agent/7`
    does (`cc-agents/slow-<customer>-work`).
  - `CrEngine.publish/1` → copies sandbox into a new release version + flips
    `_current`.
  - `Refresh.after_publish/1` → re-renders CLAUDE.md from the NEW release.
  - Assert the slow work-dir `CLAUDE.md` on disk contains the sentinel — proving
    the re-render read from the published release, not the old content.

  The slow cc agent reads CLAUDE.md only at process start, so the rewrite IS the
  refresh: a new session / restart reads the published soul. A live hot-restart
  is a documented deferral (see `Refresh` moduledoc).
  """
  use ExUnit.Case

  alias EzagentPluginAutoservice.Refresh
  alias EzagentPluginCr.CrEngine
  alias EzagentPluginContent.Tenant.TenantRuntime

  defp slow_work_dir(tid, customer) do
    Path.join([TenantRuntime.base_dir(), tid, "cc-agents", "slow-#{customer}-work"])
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    n = System.unique_integer([:positive])
    tid = "refresh-test-#{n}"
    customer = "charlie#{n}"

    # Minimal valid sandbox (R02: CLAUDE.md, skills/, kb/).
    sandbox = TenantRuntime.sandbox_path(tid)
    File.mkdir_p!(Path.join(sandbox, "skills/slow"))
    # R03: skill dirs must be non-empty.
    File.write!(Path.join(sandbox, "skills/slow/SKILL.md"), "# Slow skill")
    File.mkdir_p!(Path.join(sandbox, "kb"))
    File.mkdir_p!(Path.join(sandbox, "soul"))
    File.write!(Path.join(sandbox, "CLAUDE.md"), "# Tenant sandbox CLAUDE")

    # Pre-create the slow agent work dir (as provision would have).
    File.mkdir_p!(slow_work_dir(tid, customer))

    on_exit(fn ->
      tenant_dir = Path.join(TenantRuntime.base_dir(), tid)
      if File.exists?(tenant_dir), do: File.rm_rf!(tenant_dir)
    end)

    {:ok, tid: tid, customer: customer}
  end

  test "after_publish/1 rewrites slow work-dir CLAUDE.md with sentinel from the new release",
       %{tid: tid, customer: customer} do
    sentinel = "SENTINEL_REFRESH_#{System.unique_integer([:positive])}"

    # Write the sentinel into the sandbox soul that the renderer reads
    # (release/_current/soul/slow.md after publish copies the sandbox).
    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "soul", "slow.md"])
    File.write!(soul_path, "# Slow Soul\n\n#{sentinel}\n")

    # Publish: copy sandbox -> release/vN + flip _current.
    assert {:ok, published} = CrEngine.publish(tid)
    assert published["status"] == "published"

    # Refresh: re-render CLAUDE.md from the new release into every slow work dir.
    assert :ok = Refresh.after_publish(tid)

    claude_md_path = Path.join(slow_work_dir(tid, customer), "CLAUDE.md")
    assert File.exists?(claude_md_path), "expected slow CLAUDE.md at #{claude_md_path}"

    content = File.read!(claude_md_path)

    assert String.contains?(content, sentinel),
           "expected CLAUDE.md to contain #{sentinel}; got:\n#{String.slice(content, 0, 500)}"
  end

  test "after_publish/1 returns :ok when no slow work dirs exist (nothing to rewrite)",
       %{tid: tid, customer: customer} do
    # Remove the pre-created work dir so there's nothing to rewrite.
    File.rm_rf!(slow_work_dir(tid, customer))

    assert {:ok, _} = CrEngine.publish(tid)
    assert :ok = Refresh.after_publish(tid)
  end

  test "after_publish/1 reflects the latest release across multiple publishes",
       %{tid: tid, customer: customer} do
    n = System.unique_integer([:positive])
    s1 = "SENTINEL_V1_#{n}"
    s2 = "SENTINEL_V2_#{n}"
    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "soul", "slow.md"])
    claude_md_path = Path.join(slow_work_dir(tid, customer), "CLAUDE.md")

    File.write!(soul_path, "# Soul\n\n#{s1}\n")
    assert {:ok, _} = CrEngine.publish(tid)
    assert :ok = Refresh.after_publish(tid)
    assert String.contains?(File.read!(claude_md_path), s1)

    File.write!(soul_path, "# Soul\n\n#{s2}\n")
    assert {:ok, _} = CrEngine.publish(tid)
    assert :ok = Refresh.after_publish(tid)

    content = File.read!(claude_md_path)
    assert String.contains?(content, s2), "expected v2 sentinel after second publish"
  end

  test "after_publish_for/2 rewrites a single customer's slow CLAUDE.md",
       %{tid: tid, customer: customer} do
    sentinel = "SENTINEL_SINGLE_#{System.unique_integer([:positive])}"
    soul_path = Path.join([TenantRuntime.sandbox_path(tid), "soul", "slow.md"])
    File.write!(soul_path, "# Soul\n\n#{sentinel}\n")

    assert {:ok, _} = CrEngine.publish(tid)
    assert :ok = Refresh.after_publish_for(tid, customer)

    content = File.read!(Path.join(slow_work_dir(tid, customer), "CLAUDE.md"))
    assert String.contains?(content, sentinel)
  end
end
