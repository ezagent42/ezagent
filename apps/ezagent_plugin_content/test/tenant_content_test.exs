defmodule EzagentPluginContent.TenantContentTest do
  use ExUnit.Case, async: false

  alias EzagentPluginContent.{TenantContent, TenantPaths}

  @moduledoc """
  Tests for TenantContent.provision_context/3.

  Uses a tmp EZAGENT_HOME (same pattern as tenant_paths_test.exs) so
  filesystem side-effects are isolated per test run.
  """

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("tenant_content_test_#{:erlang.unique_integer([:positive])}")

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

    %{tmp: tmp}
  end

  describe "no release" do
    test "returns {:error, :no_release} when no symlink exists" do
      assert TenantContent.provision_context("t1", "slow") == {:error, :no_release}
    end
  end

  describe "fixture release — slow role" do
    setup %{} do
      tid = "fixture_tenant"
      v1 = TenantPaths.release_dir(tid, 1)
      File.mkdir_p!(v1)
      File.cp_r!(TenantPaths.skeleton_dir(), v1)

      link = TenantPaths.current_link(tid)
      File.mkdir_p!(Path.dirname(link))
      :ok = :file.make_symlink("v1", link)

      %{tid: tid}
    end

    test "slow context: claude_md contains RESPONSE GATE (preamble)", %{tid: tid} do
      {:ok, ctx} = TenantContent.provision_context(tid, "slow")
      assert is_binary(ctx.claude_md)
      assert String.contains?(ctx.claude_md, "RESPONSE GATE")
    end

    test "slow context: claude_md contains rendered slot value (escalation_triggers)", %{
      tid: tid
    } do
      {:ok, ctx} = TenantContent.provision_context(tid, "slow")

      # skeleton customer.yaml has escalation_triggers: "转人工, 找真人, 我要人工, 投诉"
      assert String.contains?(ctx.claude_md, "转人工")
    end

    test "slow context: claude_md contains Skill Index", %{tid: tid} do
      {:ok, ctx} = TenantContent.provision_context(tid, "slow")
      assert String.contains?(ctx.claude_md, "## Skill Index")
    end

    test "slow context: kb_db_path is non-nil (skeleton has kb/kb.db)", %{tid: tid} do
      {:ok, ctx} = TenantContent.provision_context(tid, "slow")
      assert is_binary(ctx.kb_db_path)
      assert String.ends_with?(ctx.kb_db_path, "kb.db")
    end

    test "slow context: agent_config has effort == \"low\"", %{tid: tid} do
      {:ok, ctx} = TenantContent.provision_context(tid, "slow")
      assert ctx.agent_config["effort"] == "low"
    end

    test "slow context: system_prompt is nil", %{tid: tid} do
      {:ok, ctx} = TenantContent.provision_context(tid, "slow")
      assert ctx.system_prompt == nil
    end

    test "slow context: work_dir and skills_dir are binaries", %{tid: tid} do
      {:ok, ctx} = TenantContent.provision_context(tid, "slow")
      assert is_binary(ctx.work_dir)
      assert is_binary(ctx.skills_dir)
    end
  end

  describe "fixture release — fast role" do
    setup %{} do
      tid = "fast_tenant"
      v1 = TenantPaths.release_dir(tid, 1)
      File.mkdir_p!(v1)
      File.cp_r!(TenantPaths.skeleton_dir(), v1)

      link = TenantPaths.current_link(tid)
      File.mkdir_p!(Path.dirname(link))
      :ok = :file.make_symlink("v1", link)

      %{tid: tid}
    end

    test "fast context: system_prompt contains 在线客服", %{tid: tid} do
      {:ok, ctx} = TenantContent.provision_context(tid, "fast")
      assert is_binary(ctx.system_prompt)
      assert String.contains?(ctx.system_prompt, "在线客服")
    end

    test "fast context: claude_md is nil", %{tid: tid} do
      {:ok, ctx} = TenantContent.provision_context(tid, "fast")
      assert ctx.claude_md == nil
    end
  end

  describe "sandbox source" do
    test "uses sandbox dir and picks up tenant soul override", %{} do
      tid = "sandbox_tenant"
      sandbox = TenantPaths.sandbox_dir(tid)
      File.mkdir_p!(sandbox)
      File.cp_r!(TenantPaths.skeleton_dir(), sandbox)

      # Write a tenant soul override with a unique marker
      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)
      marker = "UNIQUE_SANDBOX_MARKER_XYZ"
      File.write!(Path.join(souls_dir, "customer.md"), "## Tenant Override\n#{marker}\n")

      {:ok, ctx} = TenantContent.provision_context(tid, "slow", source: :sandbox)
      assert String.contains?(ctx.claude_md, marker)
    end

    test "returns {:error, :no_sandbox} when sandbox dir does not exist" do
      assert TenantContent.provision_context("nosandbox_tenant", "slow", source: :sandbox) ==
               {:error, :no_sandbox}
    end
  end

  describe "unknown role" do
    test "returns {:error, {:unknown_role, role}} before any fs access" do
      assert TenantContent.provision_context("t1", "alien") ==
               {:error, {:unknown_role, "alien"}}
    end
  end
end
