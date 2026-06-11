defmodule EzagentPluginContent.TenantPathsTest do
  use ExUnit.Case, async: false

  alias EzagentPluginContent.TenantPaths

  @moduledoc """
  Tests for TenantPaths path composition and symlink resolution.

  `Ezagent.Home.profile_dir/0` reads `EZAGENT_HOME` (default: ~/.ezagent)
  and `EZAGENT_PROFILE` (default: default) from the environment, so we
  override both in setup to redirect to a tmp dir.
  """

  setup do
    tmp =
      System.tmp_dir!() |> Path.join("tenant_paths_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original_home = System.get_env("EZAGENT_HOME")
    original_profile = System.get_env("EZAGENT_PROFILE")

    System.put_env("EZAGENT_HOME", tmp)
    # Use "default" profile (the default) so profile_dir == tmp/default
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

    profile_dir = Path.join(tmp, "default")
    %{tmp: tmp, profile_dir: profile_dir}
  end

  describe "path composition" do
    test "sandbox_dir/1 ends with tenants/<tid>/sandbox", %{profile_dir: profile_dir} do
      result = TenantPaths.sandbox_dir("t1")
      assert String.ends_with?(result, "tenants/t1/sandbox")
      assert String.starts_with?(result, profile_dir)
    end

    test "release_dir/2 ends with tenants/<tid>/release/v<n>", %{profile_dir: profile_dir} do
      result = TenantPaths.release_dir("t1", 3)
      assert String.ends_with?(result, "tenants/t1/release/v3")
      assert String.starts_with?(result, profile_dir)
    end

    test "current_link/1 ends with tenants/<tid>/release/_current", %{profile_dir: profile_dir} do
      result = TenantPaths.current_link("t1")
      assert String.ends_with?(result, "tenants/t1/release/_current")
      assert String.starts_with?(result, profile_dir)
    end

    test "work_dir/2 ends with tenants/<tid>/cc-agents/<role>-work", %{profile_dir: profile_dir} do
      result = TenantPaths.work_dir("t1", "customer")
      assert String.ends_with?(result, "tenants/t1/cc-agents/customer-work")
      assert String.starts_with?(result, profile_dir)
    end
  end

  describe "segment validation" do
    test "tenant_root/1 raises ArgumentError on path traversal '../evil'" do
      assert_raise ArgumentError, ~r/tenant id/, fn ->
        TenantPaths.tenant_root("../evil")
      end
    end

    test "tenant_root/1 raises ArgumentError on segment with slash 'a/b'" do
      assert_raise ArgumentError, ~r/tenant id/, fn ->
        TenantPaths.tenant_root("a/b")
      end
    end

    test "work_dir/2 raises ArgumentError on role with path traversal '../x'" do
      assert_raise ArgumentError, ~r/role/, fn ->
        TenantPaths.work_dir("t1", "../x")
      end
    end
  end

  describe "current_dir/1" do
    test "returns {:error, :no_release} when no symlink exists" do
      assert TenantPaths.current_dir("t1") == {:error, :no_release}
    end

    test "resolves symlink to the versioned dir" do
      tid = "t1"
      v1_dir = TenantPaths.release_dir(tid, 1)
      File.mkdir_p!(v1_dir)

      link = TenantPaths.current_link(tid)
      # Make the symlink point at "v1" (relative, as a real deploy would)
      :ok = :file.make_symlink("v1", link)

      assert {:ok, resolved} = TenantPaths.current_dir(tid)
      assert resolved == v1_dir
    end

    test "returns {:error, :no_release} when symlink points outside release_root" do
      tid = "t1"
      # Create a target directory outside the tenant tree
      outside_dir =
        System.tmp_dir!() |> Path.join("outside_tenant_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)

      # Ensure the release_root parent directory exists so we can create the symlink
      release_root = TenantPaths.release_root(tid)
      File.mkdir_p!(release_root)

      link = TenantPaths.current_link(tid)
      :ok = :file.make_symlink(outside_dir, link)

      assert TenantPaths.current_dir(tid) == {:error, :no_release}

      File.rm_rf!(outside_dir)
    end
  end

  describe "skeleton_dir/0" do
    test "returns an existing directory" do
      dir = TenantPaths.skeleton_dir()
      assert File.dir?(dir), "skeleton_dir #{inspect(dir)} does not exist"
    end

    test "skeleton contains souls/customer_soul.md" do
      soul = Path.join([TenantPaths.skeleton_dir(), "souls", "customer_soul.md"])
      assert File.exists?(soul), "missing #{soul}"
    end

    test "skeleton contains config/agents.yaml" do
      cfg = Path.join([TenantPaths.skeleton_dir(), "config", "agents.yaml"])
      assert File.exists?(cfg), "missing #{cfg}"
    end

    test "skeleton contains kb/kb.db" do
      kb = Path.join([TenantPaths.skeleton_dir(), "kb", "kb.db"])
      assert File.exists?(kb), "missing #{kb}"
    end
  end
end
