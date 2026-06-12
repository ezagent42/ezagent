defmodule EzagentPluginAutoservice.PublishRefreshTest do
  @moduledoc """
  Integration test: publish → running-agent refresh (Stage F4).

  Strategy:
  - Provision a tenant with `create_agents: false` (no real PTY/cc agents).
  - Flip a sentinel string into the sandbox soul file (sandbox/souls/customer.md).
  - Call `Publisher.publish/2` → assert `{:ok, %{version: v}}`.
  - Call `Refresh.refresh_agents/1` → assert `:ok` (no raise).
  - Assert the slow agent's work-dir `CLAUDE.md` on disk CONTAINS the sentinel
    (proves re-render + rewrite happened from the new release).

  The respawn path is NOT exercised here (no live PTY in tests); the test
  asserts the CLAUDE.md disk state and that `refresh_agents/1` returns `:ok`.
  The live respawn is exercised in Stage-G E2E.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentPluginAutoservice.Assembly
  alias EzagentPluginAutoservice.Assembly.Refresh
  alias EzagentPluginContent.TenantPaths
  alias EzagentPluginCr.Publisher

  @sentinel "SENTINEL_REFRESH_TEST_#{:erlang.unique_integer([:positive])}"

  defp priv_ctx do
    %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }
  end

  setup do
    n = System.unique_integer([:positive])
    tid = "refresh-test-#{n}"
    customer = "charlie#{n}"
    admin_actor_uri = URI.to_string(Ezagent.Entity.User.admin_uri())

    # Provision the tenant (create_agents: false — no real cc/curl spawn).
    assert {:ok, _uris} =
             Assembly.provision_session(tid, customer, priv_ctx(), create_agents: false)

    {:ok, tid: tid, admin_actor_uri: admin_actor_uri}
  end

  describe "publish + refresh_agents" do
    test "refresh_agents/1 rewrites slow work-dir CLAUDE.md with sentinel from sandbox soul",
         %{tid: tid, admin_actor_uri: admin_actor_uri} do
      # Step 1: write the sentinel into the sandbox soul override file.
      soul_path = Path.join([TenantPaths.sandbox_dir(tid), "souls", "customer.md"])
      soul_dir = Path.dirname(soul_path)
      :ok = File.mkdir_p(soul_dir)
      :ok = File.write(soul_path, "# Tenant Soul Override\n\n#{@sentinel}\n")

      # Step 2: publish — Lint → copy sandbox → flip _current.
      assert {:ok, %{version: v}} = Publisher.publish(tid, admin_actor_uri)
      assert is_integer(v) and v >= 1

      # Step 3: refresh_agents — must not raise; must return :ok.
      assert :ok = Refresh.refresh_agents(tid)

      # Step 4: assert slow work-dir CLAUDE.md contains the sentinel.
      # The slow agent work_dir is determined by TenantPaths.work_dir/2.
      claude_md_path = Path.join(TenantPaths.work_dir(tid, "slow"), "CLAUDE.md")

      assert File.exists?(claude_md_path),
             "Expected slow CLAUDE.md to exist at #{claude_md_path}"

      content = File.read!(claude_md_path)

      assert String.contains?(content, @sentinel),
             "Expected CLAUDE.md to contain sentinel #{@sentinel}; got:\n#{String.slice(content, 0, 500)}"
    end

    test "refresh_agents/1 returns :ok when slow provision succeeds even without live agents",
         %{tid: tid, admin_actor_uri: admin_actor_uri} do
      # Publish first so _current exists.
      assert {:ok, %{version: _v}} = Publisher.publish(tid, admin_actor_uri)

      # Should succeed without any live agents in KindRegistry.
      assert :ok = Refresh.refresh_agents(tid)
    end

    test "CLAUDE.md reflects multi-publish iterations (latest soul wins)",
         %{tid: tid, admin_actor_uri: admin_actor_uri} do
      n = System.unique_integer([:positive])
      sentinel_v1 = "SENTINEL_V1_#{n}"
      sentinel_v2 = "SENTINEL_V2_#{n}"

      soul_path = Path.join([TenantPaths.sandbox_dir(tid), "souls", "customer.md"])
      :ok = File.mkdir_p(Path.dirname(soul_path))

      # First publish with sentinel_v1.
      :ok = File.write(soul_path, "# Soul\n\n#{sentinel_v1}\n")
      assert {:ok, %{version: v1}} = Publisher.publish(tid, admin_actor_uri)
      assert :ok = Refresh.refresh_agents(tid)

      claude_md = File.read!(Path.join(TenantPaths.work_dir(tid, "slow"), "CLAUDE.md"))
      assert String.contains?(claude_md, sentinel_v1)

      # Second publish with sentinel_v2 — CLAUDE.md must update.
      :ok = File.write(soul_path, "# Soul\n\n#{sentinel_v2}\n")
      assert {:ok, %{version: v2}} = Publisher.publish(tid, admin_actor_uri)
      assert v2 > v1
      assert :ok = Refresh.refresh_agents(tid)

      claude_md2 = File.read!(Path.join(TenantPaths.work_dir(tid, "slow"), "CLAUDE.md"))

      assert String.contains?(claude_md2, sentinel_v2),
             "Expected CLAUDE.md to contain v2 sentinel after second publish"
    end
  end
end
