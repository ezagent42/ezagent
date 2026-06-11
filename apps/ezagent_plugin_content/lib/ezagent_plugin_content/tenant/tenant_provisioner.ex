defmodule EzagentPluginContent.Tenant.TenantProvisioner do
  @moduledoc "Create a new tenant: workspace + sandbox init + first CR."

  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Soul.SoulStore

  @spec create_tenant(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_tenant(tid, brand_name, opts \\ []) do
    industry = Keyword.get(opts, :industry, "cloud-comms")
    role = Keyword.get(opts, :role, "customer")

    # 1. Create sandbox directory structure
    sandbox = TenantRuntime.sandbox_path(tid)
    File.mkdir_p!(Path.join(sandbox, "slots"))
    File.mkdir_p!(Path.join(sandbox, "souls"))
    File.mkdir_p!(Path.join(sandbox, "skills/#{role}"))
    File.mkdir_p!(Path.join(sandbox, "kb"))
    File.mkdir_p!(Path.join(sandbox, "config"))

    # 2. Clone skeleton -> sandbox
    skel = Path.join(:code.priv_dir(:ezagent_plugin_content), "skeleton")
    copy_if_exists(Path.join(skel, "soul/soul.md"), Path.join(sandbox, "souls/#{role}_soul.md"))

    # 3. Copy platform skills
    plat_skills = Path.join(:code.priv_dir(:ezagent_plugin_content), "platform/skills/#{role}")
    copy_tree_if_exists(plat_skills, Path.join(sandbox, "skills/#{role}"))

    # 4. Initialize empty slots.yaml
    default_slots = SoulStore.defaults(tid, role)
    SoulStore.write_slots(TenantRuntime.base_dir(), tid, role, default_slots, :sandbox)

    # 5. Write tenant config to ConfigStore
    cr_id = "cr-#{Date.utc_today()}-001"
    cr = %{cr_id: cr_id, tenant_id: tid, status: "open",
           created_by: "system://tenant-provisioner", created_at: DateTime.utc_now() |> DateTime.to_iso8601()}

    config = %{brand_name: brand_name, industry: industry, roles: [role], channels: ["web"]}

    with {:ok, _} <- write_config(tid, config),
         {:ok, _} <- write_cr(tid, cr_id, cr) do
      {:ok, %{tenant_id: tid, sandbox: sandbox, cr_id: cr_id}}
    end
  end

  defp write_config(tid, config) do
    Ezagent.Socialware.ConfigStore.write_and_point(%{
      layer: "workspace",
      workspace_uri: "workspace://#{tid}",
      subject_uri: "entity://system/tenant-config",
      key: "tenant:#{tid}:config",
      body: config,
      actor_uri: "system://tenant-provisioner",
      source_turn_id: "bootstrap"
    })
  end

  defp write_cr(tid, cr_id, cr) do
    Ezagent.Socialware.ConfigStore.write_and_point(%{
      layer: "workspace",
      workspace_uri: "workspace://#{tid}",
      subject_uri: "entity://system/cr",
      key: "cr:#{tid}:#{cr_id}",
      body: cr,
      actor_uri: "system://tenant-provisioner",
      source_turn_id: "bootstrap"
    })
  end

  defp copy_if_exists(src, dst) do
    if File.exists?(src) do
      dst |> Path.dirname() |> File.mkdir_p!()
      File.cp!(src, dst)
    end
  end

  defp copy_tree_if_exists(src, dst) do
    if File.exists?(src), do: {:ok, _} = File.cp_r(src, dst)
  end
end
