defmodule EzagentPluginContent.Tenant.TenantRuntime do
  @moduledoc "Runtime path management for tenant sandbox/release and agent work dirs."

  @default_base_dir Path.join(System.user_home(), ".ezagent/default/tenants")

  @spec base_dir() :: binary()
  def base_dir, do: Application.get_env(:ezagent_plugin_content, :tenant_base_dir, @default_base_dir)

  @spec sandbox_path(String.t()) :: binary()
  def sandbox_path(tid), do: Path.join([base_dir(), tid, "sandbox"])

  @spec release_path(String.t()) :: binary()
  def release_path(tid), do: Path.join([base_dir(), tid, "release"])

  @spec current_release_path(String.t()) :: binary()
  def current_release_path(tid), do: Path.join([release_path(tid), "_current"])

  @doc "Materialize agent work dir with symlinks to release/_current."
  @spec materialize(String.t(), String.t(), :sandbox | :release) :: binary()
  def materialize(tid, role, source \\ :release)

  def materialize(tid, role, :release) do
    work_dir = Path.join([base_dir(), tid, "cc-agents", "#{role}-work"])
    File.mkdir_p!(work_dir)
    # Symlink skills/
    dest = Path.join(work_dir, "skills")
    src = Path.join([current_release_path(tid), "skills", role])
    update_symlink(dest, src)
    # Symlink kb.db
    dest_kb = Path.join(work_dir, "kb.db")
    src_kb = Path.join([current_release_path(tid), "kb", "kb.db"])
    update_symlink(dest_kb, src_kb)
    work_dir
  end

  def materialize(tid, role, :sandbox) do
    work_dir = Path.join([base_dir(), tid, "cc-agents", "preview-#{role}-work"])
    File.mkdir_p!(work_dir)
    # Same but to sandbox
    dest = Path.join(work_dir, "skills")
    src = Path.join([sandbox_path(tid), "skills", role])
    update_symlink(dest, src)
    dest_kb = Path.join(work_dir, "kb.db")
    src_kb = Path.join([sandbox_path(tid), "kb", "kb.db"])
    update_symlink(dest_kb, src_kb)
    work_dir
  end

  defp update_symlink(dest, src) do
    File.rm_rf!(dest)
    if File.exists?(src), do: File.ln_s(src, dest)
  end
end
