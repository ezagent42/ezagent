defmodule EzagentPluginContent.TenantPaths do
  @moduledoc "Tenant content roots: sandbox (admin edits) vs release/_current (agents read)."

  def tenant_root(tid), do: Path.join([Ezagent.Home.profile_dir(), "tenants", tid])
  def sandbox_dir(tid), do: Path.join(tenant_root(tid), "sandbox")
  def release_root(tid), do: Path.join(tenant_root(tid), "release")
  def release_dir(tid, n), do: Path.join(release_root(tid), "v#{n}")
  def current_link(tid), do: Path.join(release_root(tid), "_current")

  def current_dir(tid) do
    link = current_link(tid)

    case File.read_link(link) do
      {:ok, target} -> {:ok, Path.expand(target, release_root(tid))}
      {:error, _} -> {:error, :no_release}
    end
  end

  def work_dir(tid, role),
    do: Path.join([Ezagent.Home.profile_dir(), "tenants", tid, "cc-agents", "#{role}-work"])

  def skeleton_dir, do: Path.join(:code.priv_dir(:ezagent_plugin_content), "skeleton")
end
