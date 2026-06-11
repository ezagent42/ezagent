defmodule EzagentPluginCr.PublisherTest do
  @moduledoc """
  Tests for EzagentPluginCr.Publisher (publish, init_tenant, rollback).

  Requires BOTH:
  - EzagentCore.DataCase (DB sandbox for CrStore)
  - tmp EZAGENT_HOME (filesystem isolation for TenantPaths)

  Each test uses a unique tid to avoid cross-test interference.
  """

  use EzagentCore.DataCase, async: false

  alias EzagentPluginContent.{TenantContent, TenantPaths}
  alias EzagentPluginCr.{CrStore, Publisher}

  # Unique tenant id per test; must match ~r/^[a-zA-Z0-9_-]+$/
  defp tid, do: "pt#{System.unique_integer([:positive])}"

  @actor "system://publisher-test"

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("publisher_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original_home = System.get_env("EZAGENT_HOME")
    original_profile = System.get_env("EZAGENT_PROFILE")

    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", "default")

    on_exit(fn ->
      File.rm_rf!(tmp)

      case original_home do
        nil -> System.delete_env("EZAGENT_HOME")
        val -> System.put_env("EZAGENT_HOME", val)
      end

      case original_profile do
        nil -> System.delete_env("EZAGENT_PROFILE")
        val -> System.put_env("EZAGENT_PROFILE", val)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # init_tenant
  # ---------------------------------------------------------------------------

  describe "init_tenant/2 — fresh tenant" do
    test "returns {:ok, %{version: 1}} and _current resolves" do
      t = tid()
      assert {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)

      # _current symlink must resolve
      assert {:ok, current} = TenantPaths.current_dir(t)
      assert String.ends_with?(current, "/v1")
    end

    test "release v1 contains souls/customer_soul.md AND config/agents.yaml (full copy)" do
      t = tid()
      {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)

      {:ok, current} = TenantPaths.current_dir(t)
      assert File.exists?(Path.join(current, "souls/customer_soul.md"))
      assert File.exists?(Path.join(current, "config/agents.yaml"))
    end

    test "CR is marked published with published_version 1" do
      t = tid()
      {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)

      assert {:ok, cr} = CrStore.get(t)
      assert cr["status"] == "published"
      assert cr["published_version"] == 1
    end
  end

  describe "init_tenant/2 — already initialized" do
    test "returns {:ok, :already_initialized} on second call without creating v2" do
      t = tid()
      {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)
      assert {:ok, :already_initialized} = Publisher.init_tenant(t, @actor)

      # v2 must NOT exist
      v2_dir = TenantPaths.release_dir(t, 2)
      refute File.dir?(v2_dir)
    end
  end

  describe "init_tenant/2 — half-init resume" do
    test "sandbox exists but no _current → publishes v1 (not :already_initialized)" do
      t = tid()
      sandbox = TenantPaths.sandbox_dir(t)

      # Manually create the sandbox as if cp_r succeeded but publish crashed.
      File.mkdir_p!(sandbox)
      File.cp_r!(TenantPaths.skeleton_dir(), sandbox)

      # _current must NOT exist yet
      assert {:error, :no_release} = TenantPaths.current_dir(t)

      # init_tenant should resume and publish v1
      assert {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)

      # _current now resolves to v1
      assert {:ok, current} = TenantPaths.current_dir(t)
      assert String.ends_with?(current, "/v1")
    end
  end

  describe "repair_current/1" do
    test "returns {:ok, :consistent} when _current already points at published version" do
      t = tid()
      {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)
      assert {:ok, :consistent} = Publisher.repair_current(t)
    end

    test "returns {:ok, :repaired} when _current lags behind published version" do
      t = tid()
      {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)

      # Publish v2 normally
      sandbox = TenantPaths.sandbox_dir(t)
      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)
      File.write!(Path.join(souls_dir, "customer.md"), "## v2\n")
      {:ok, %{version: 2}} = Publisher.publish(t, @actor)

      # Simulate crash-after-mark-before-flip by manually flipping _current
      # back to v1 (as if flip_current never ran for v2).
      v1_dir = TenantPaths.release_dir(t, 1)
      link = TenantPaths.current_link(t)
      tmp = link <> ".tmp"
      :ok = :file.make_symlink(String.to_charlist(v1_dir), String.to_charlist(tmp))
      :ok = :file.rename(tmp, link)

      # _current now points at v1 but CR says published v2
      {:ok, current_before} = TenantPaths.current_dir(t)
      assert String.ends_with?(current_before, "/v1")

      # repair_current should detect the gap and flip to v2
      assert {:ok, :repaired} = Publisher.repair_current(t)

      # _current now resolves to v2
      {:ok, current_after} = TenantPaths.current_dir(t)
      assert String.ends_with?(current_after, "/v2")
    end

    test "returns {:ok, :consistent} when no CR exists yet" do
      t = tid()
      assert {:ok, :consistent} = Publisher.repair_current(t)
    end
  end

  # ---------------------------------------------------------------------------
  # publish
  # ---------------------------------------------------------------------------

  describe "publish/2 — version increment" do
    setup do
      t = tid()
      {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)
      %{t: t}
    end

    test "edit sandbox then publish → version 2, current_dir points at v2", %{t: t} do
      # Edit sandbox: write a unique marker into souls/customer.md override
      sandbox = TenantPaths.sandbox_dir(t)
      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)
      marker = "PUBLISHER_TEST_MARKER_#{System.unique_integer([:positive])}"
      File.write!(Path.join(souls_dir, "customer.md"), "## Override\n#{marker}\n")

      assert {:ok, %{version: 2}} = Publisher.publish(t, @actor)

      {:ok, current} = TenantPaths.current_dir(t)
      assert String.ends_with?(current, "/v2")
    end

    test "marker visible via TenantContent.provision_context/3 (release source)", %{t: t} do
      sandbox = TenantPaths.sandbox_dir(t)
      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)
      marker = "UNIQUE_RELEASE_MARKER_#{System.unique_integer([:positive])}"
      File.write!(Path.join(souls_dir, "customer.md"), "## Override\n#{marker}\n")

      {:ok, %{version: 2}} = Publisher.publish(t, @actor)

      # provision_context defaults to :release — should see v2
      assert {:ok, ctx} = TenantContent.provision_context(t, "slow")
      assert String.contains?(ctx.claude_md, marker)
    end
  end

  # ---------------------------------------------------------------------------
  # Lint gate — fatal (R03)
  # ---------------------------------------------------------------------------

  describe "publish/2 — lint fatal blocks copy" do
    setup do
      t = tid()
      {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)
      %{t: t}
    end

    test "soul referencing missing skill → {:error, {:missing_skill, …}}; no v3 dir, _current still v2",
         %{t: t} do
      # Get to v2 first with a clean publish
      sandbox = TenantPaths.sandbox_dir(t)
      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)
      File.write!(Path.join(souls_dir, "customer.md"), "## Clean v2\n")
      {:ok, %{version: 2}} = Publisher.publish(t, @actor)

      # Now write a soul that references a non-existent skill
      File.write!(Path.join(souls_dir, "customer.md"), """
      Use plugins/#{t}/skills/nope/SKILL.md for help.
      """)

      assert {:error, {:missing_skill, "nope/SKILL.md"}} = Publisher.publish(t, @actor)

      # v3 must NOT have been created
      v3_dir = TenantPaths.release_dir(t, 3)
      refute File.dir?(v3_dir)

      # _current still points at v2
      {:ok, current} = TenantPaths.current_dir(t)
      assert String.ends_with?(current, "/v2")
    end
  end

  # ---------------------------------------------------------------------------
  # Lint gate — warnings (R01)
  # ---------------------------------------------------------------------------

  describe "publish/2 — lint warnings are non-fatal" do
    setup do
      t = tid()
      {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)
      %{t: t}
    end

    test "soul with {{not.a.slot}} placeholder succeeds with warning in result", %{t: t} do
      sandbox = TenantPaths.sandbox_dir(t)
      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)
      File.write!(Path.join(souls_dir, "customer.md"), "Hello {{not.a.slot}}\n")

      assert {:ok, %{version: 2, warnings: warnings}} = Publisher.publish(t, @actor)
      assert "unresolved slot: {{not.a.slot}}" in warnings
    end
  end

  # ---------------------------------------------------------------------------
  # rollback
  # ---------------------------------------------------------------------------

  describe "rollback/3" do
    setup do
      t = tid()
      {:ok, %{version: 1}} = Publisher.init_tenant(t, @actor)

      # Publish v2 with a distinct marker
      sandbox = TenantPaths.sandbox_dir(t)
      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)
      File.write!(Path.join(souls_dir, "customer.md"), "## v2 content\n")
      {:ok, %{version: 2}} = Publisher.publish(t, @actor)

      %{t: t}
    end

    test "rollback to v1 → current_dir resolves v1", %{t: t} do
      assert {:ok, %{version: 1}} = Publisher.rollback(t, 1, @actor)

      {:ok, current} = TenantPaths.current_dir(t)
      assert String.ends_with?(current, "/v1")
    end

    test "rollback to missing version → {:error, :no_such_version}", %{t: t} do
      assert {:error, :no_such_version} = Publisher.rollback(t, 999, @actor)
    end
  end
end
