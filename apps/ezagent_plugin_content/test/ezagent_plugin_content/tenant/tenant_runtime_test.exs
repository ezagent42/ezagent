defmodule EzagentPluginContent.Tenant.TenantRuntimeTest do
  use ExUnit.Case
  alias EzagentPluginContent.Tenant.TenantRuntime

  @test_tid "test-tenant-runtime"
  @test_role "customer"

  setup do
    # Override base_dir to a temp directory for clean test isolation
    tmp = Path.join(System.tmp_dir!(), "tenant_runtime_test_#{System.unique_integer()}")
    prev = Application.get_env(:ezagent_plugin_content, :tenant_base_dir)
    Application.put_env(:ezagent_plugin_content, :tenant_base_dir, tmp)

    on_exit(fn ->
      if prev, do: Application.put_env(:ezagent_plugin_content, :tenant_base_dir, prev)
      File.rm_rf!(tmp)
    end)

    {:ok, base_dir: tmp}
  end

  test "base_dir resolves from env or default" do
    assert String.contains?(TenantRuntime.base_dir(), "tenant_runtime_test")
  end

  test "sandbox_path returns correct path" do
    path = TenantRuntime.sandbox_path(@test_tid)
    assert path =~ "#{@test_tid}/sandbox"
    assert String.starts_with?(path, TenantRuntime.base_dir())
  end

  test "release_path returns correct path" do
    path = TenantRuntime.release_path(@test_tid)
    assert path =~ "#{@test_tid}/release"
    assert not String.contains?(path, "_current")
  end

  test "current_release_path returns path ending in _current" do
    path = TenantRuntime.current_release_path(@test_tid)
    assert path =~ "#{@test_tid}/release/_current"
  end

  test "materialize :release creates work dir and symlinks" do
    # Setup required source files first
    curr = TenantRuntime.current_release_path(@test_tid)
    skills_src = Path.join([curr, "skills", @test_role])
    kb_dir = Path.join(curr, "kb")
    File.mkdir_p!(skills_src)
    File.mkdir_p!(kb_dir)
    File.write!(Path.join(kb_dir, "kb.db"), "test kb")
    # Write a dummy skill file so the dir is non-empty
    File.write!(Path.join(skills_src, "SKILL.md"), "# dummy")

    work_dir = TenantRuntime.materialize(@test_tid, @test_role, :release)

    assert File.dir?(work_dir)
    assert work_dir =~ "cc-agents/#{@test_role}-work"
    dest_skills = Path.join(work_dir, "skills")
    dest_kb = Path.join(work_dir, "kb.db")
    assert File.dir?(dest_skills)
    assert File.exists?(dest_kb)
  end

  test "materialize :sandbox creates preview work dir and symlinks" do
    sb = TenantRuntime.sandbox_path(@test_tid)
    skills_src = Path.join([sb, "skills", @test_role])
    kb_dir = Path.join(sb, "kb")
    File.mkdir_p!(skills_src)
    File.mkdir_p!(kb_dir)
    File.write!(Path.join(kb_dir, "kb.db"), "test kb")
    File.write!(Path.join(skills_src, "SKILL.md"), "# preview")

    work_dir = TenantRuntime.materialize(@test_tid, @test_role, :sandbox)

    assert File.dir?(work_dir)
    assert work_dir =~ "cc-agents/preview-#{@test_role}-work"
    dest_skills = Path.join(work_dir, "skills")
    dest_kb = Path.join(work_dir, "kb.db")
    assert File.dir?(dest_skills)
    assert File.exists?(dest_kb)
  end

  test "update_symlink does not crash when src does not exist" do
    work_dir = Path.join([TenantRuntime.base_dir(), @test_tid, "cc-agents", "#{@test_role}-work"])
    File.mkdir_p!(work_dir)
    # call materialize which internally calls update_symlink on non-existing src
    # This should not crash (update_symlink is resilient)
    result = TenantRuntime.materialize(@test_tid, @test_role, :release)
    assert File.dir?(result)
  end
end
